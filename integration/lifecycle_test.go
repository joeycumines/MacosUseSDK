package integration

import (
	"context"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// TestCoreLifecycle tests the complete application lifecycle:
// OpenApplication -> GetApplication -> ListApplications -> CloseApplication
// This verifies Phase 4.3 requirements for Core Lifecycle integration tests.
func TestCoreLifecycle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Connect to server
	conn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// Ensure golden applications from any prior failed test are not running.
	killGoldenApplications()

	// Step 1: OpenApplication
	t.Log("Step 1: Opening Calculator...")
	app := OpenApplicationObserved(t, ctx, client, "com.apple.calculator")

	appName := app.Name
	appPID := app.Pid

	// Ensure cleanup happens at end
	defer CleanupApplication(t, ctx, client, app)

	// Step 2: GetApplication with PollUntil (max 2s)
	t.Log("Step 2: Getting Calculator via GetApplication...")
	var getResp *pb.Application
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.GetApplication(ctx, &pb.GetApplicationRequest{
			Name: appName,
		})
		if err != nil {
			return false, nil
		}
		getResp = resp
		return true, nil
	})
	if err != nil {
		t.Fatalf("GetApplication failed after polling: %v", err)
	}

	if getResp.Name != appName {
		t.Errorf("GetApplication: expected name %q, got %q", appName, getResp.Name)
	}
	if getResp.Pid != appPID {
		t.Errorf("GetApplication: expected pid %d, got %d", appPID, getResp.Pid)
	}
	if getResp.DisplayName == "" {
		t.Error("GetApplication: expected non-empty display_name")
	}

	// Step 3: ListApplications (verify Calculator appears)
	t.Log("Step 3: Listing applications...")
	listResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("ListApplications failed: %v", err)
	}

	found := false
	for _, app := range listResp.Applications {
		if app.Name == appName {
			found = true
			if app.Pid != appPID {
				t.Errorf("ListApplications: expected pid %d, got %d for %s", appPID, app.Pid, appName)
			}
			if app.DisplayName == "" {
				t.Error("ListApplications: expected non-empty display_name")
			}
			break
		}
	}
	if !found {
		t.Errorf("ListApplications: Calculator not found in list")
	}

	// Step 4: CloseApplication
	t.Log("Step 4: Closing Calculator...")
	closeResp, err := client.CloseApplication(ctx, &pb.CloseApplicationRequest{
		Name:  appName,
		Force: true,
	})
	if err != nil {
		t.Fatalf("CloseApplication failed: %v", err)
	}
	if closeResp.Application == nil || closeResp.Application.Name != appName || closeResp.Application.Pid != appPID {
		t.Fatalf("CloseApplication returned wrong application: %+v", closeResp.Application)
	}
	if closeResp.Disposition != pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_GRACEFUL &&
		closeResp.Disposition != pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_FORCED {
		t.Fatalf("CloseApplication disposition = %s, want graceful or forced", closeResp.Disposition)
	}

	// Step 5: Verify application is gone with PollUntil (max 2s)
	t.Log("Step 5: Verifying Calculator is closed and untracked...")
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		_, err := client.GetApplication(ctx, &pb.GetApplicationRequest{
			Name: appName,
		})
		// Application should NOT be found
		return err != nil, nil
	})
	if err != nil {
		t.Errorf("Application still exists after CloseApplication")
	}

	// Also verify via ListApplications
	listResp2, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("ListApplications failed after delete: %v", err)
	}

	for _, app := range listResp2.Applications {
		if app.Name == appName {
			t.Errorf("Application %s still appears in ListApplications after delete", appName)
		}
	}

	t.Log("Core lifecycle test completed successfully")
}

// TestMultipleApplications tests opening and managing multiple applications simultaneously.
func TestMultipleApplications(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// Pre-cleanup
	killGoldenApplications()

	// Open Calculator
	t.Log("Opening Calculator...")
	calcApp := OpenApplicationObserved(t, ctx, client, "com.apple.calculator")
	defer CleanupApplication(t, ctx, client, calcApp)

	// Open TextEdit
	t.Log("Opening TextEdit...")
	textEditApp := OpenApplicationObserved(t, ctx, client, "com.apple.TextEdit")
	defer CleanupApplication(t, ctx, client, textEditApp)

	// Verify both appear in ListApplications
	t.Log("Verifying both applications are listed...")
	listResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("ListApplications failed: %v", err)
	}

	foundCalc := false
	foundTextEdit := false
	for _, app := range listResp.Applications {
		if app.Name == calcApp.Name {
			foundCalc = true
		}
		if app.Name == textEditApp.Name {
			foundTextEdit = true
		}
	}

	if !foundCalc {
		t.Error("Calculator not found in ListApplications")
	}
	if !foundTextEdit {
		t.Error("TextEdit not found in ListApplications")
	}

	// Close Calculator
	t.Log("Closing Calculator...")
	closeResp, err := client.CloseApplication(ctx, &pb.CloseApplicationRequest{
		Name: calcApp.Name,
	})
	if err != nil {
		t.Fatalf("Failed to close Calculator: %v", err)
	}
	if closeResp.Application == nil || closeResp.Application.Name != calcApp.Name ||
		closeResp.Disposition != pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_GRACEFUL {
		t.Fatalf("CloseApplication returned incomplete Calculator result: %+v", closeResp)
	}

	// Verify only TextEdit remains
	t.Log("Verifying only TextEdit remains...")
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		listResp2, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
		if err != nil {
			return false, nil
		}

		foundCalc := false
		foundTextEdit := false
		for _, app := range listResp2.Applications {
			if app.Name == calcApp.Name {
				foundCalc = true
			}
			if app.Name == textEditApp.Name {
				foundTextEdit = true
			}
		}

		// Success condition: Calculator gone, TextEdit still present
		return !foundCalc && foundTextEdit, nil
	})
	if err != nil {
		t.Error("Calculator still present or TextEdit disappeared after CloseApplication")
	}

	t.Log("Multiple applications test completed successfully")
}
