package integration

import (
	"context"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// TestCoreLifecycle tests the complete application lifecycle:
// OpenApplication -> GetApplication -> ListApplications -> DeleteApplication
// This verifies Phase 4.3 requirements for Core Lifecycle integration tests.
func TestCoreLifecycle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer serverCmd.Process.Kill()

	// Connect to server
	conn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Ensure Calculator is not already running
	CleanupApplication(t, ctx, client, "/Applications/Calculator.app")

	// Step 1: OpenApplication
	t.Log("Step 1: Opening Calculator...")
	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.calculator")

	appName := app.Name
	appPID := app.Pid

	// Ensure cleanup happens at end
	defer CleanupApplication(t, ctx, client, appName)

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

	// Step 4: DeleteApplication
	t.Log("Step 4: Deleting Calculator...")
	_, err = client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{
		Name: appName,
	})
	if err != nil {
		t.Fatalf("DeleteApplication failed: %v", err)
	}

	// Step 5: Verify application is gone with PollUntil (max 2s)
	t.Log("Step 5: Verifying Calculator is deleted...")
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		_, err := client.GetApplication(ctx, &pb.GetApplicationRequest{
			Name: appName,
		})
		// Application should NOT be found
		return err != nil, nil
	})
	if err != nil {
		t.Errorf("Application still exists after DeleteApplication")
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
	defer serverCmd.Process.Kill()

	conn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Pre-cleanup
	CleanupApplication(t, ctx, client, "/Applications/Calculator.app")
	CleanupApplication(t, ctx, client, "/Applications/TextEdit.app")

	// Open Calculator
	t.Log("Opening Calculator...")
	calcApp := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.calculator")
	defer CleanupApplication(t, ctx, client, calcApp.Name)

	// Open TextEdit
	t.Log("Opening TextEdit...")
	textEditApp := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.TextEdit")
	defer CleanupApplication(t, ctx, client, textEditApp.Name)

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

	// Delete Calculator
	t.Log("Deleting Calculator...")
	_, err = client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{
		Name: calcApp.Name,
	})
	if err != nil {
		t.Fatalf("Failed to delete Calculator: %v", err)
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
		t.Error("Calculator still present or TextEdit disappeared after DeleteApplication")
	}

	t.Log("Multiple applications test completed successfully")
}
