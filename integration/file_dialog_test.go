package integration

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestFileDialog_SelectFile verifies SelectFile operation with valid and invalid paths.
// Uses Finder as the application context per golden app rules.
func TestFileDialog_SelectFile(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Open Finder
	t.Log("Opening Finder...")
	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.finder")
	defer CleanupApplication(t, ctx, client, app.Name)

	// Wait for Finder to be ready
	t.Log("Waiting for Finder to be ready...")
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, nil
		}
		return len(resp.Windows) >= 0, nil // Finder is ready when we can query windows
	})
	if err != nil {
		t.Fatalf("Finder did not become ready: %v", err)
	}

	// Create a temporary file for testing
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "test_select_file.txt")
	if err := os.WriteFile(tmpFile, []byte("test content"), 0600); err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	t.Logf("Created temp file: %s", tmpFile)

	// Test 1: SelectFile with valid path
	t.Log("Test 1: SelectFile with valid path...")
	selectResp, err := client.SelectFile(ctx, &pb.SelectFileRequest{
		Application:  app.Name,
		FilePath:     tmpFile,
		RevealFinder: false,
	})
	if err != nil {
		t.Errorf("SelectFile failed for valid path: %v", err)
	} else {
		t.Logf("SelectFile response: success=%v, path=%s", selectResp.Success, selectResp.SelectedPath)
		if !selectResp.Success {
			t.Errorf("SelectFile should succeed for valid path, got error: %s", selectResp.Error)
		}
	}

	// Test 2: SelectFile with non-existent path (should fail gracefully)
	t.Log("Test 2: SelectFile with non-existent path...")
	nonExistentPath := filepath.Join(tmpDir, "does_not_exist_12345.txt")
	selectResp2, err := client.SelectFile(ctx, &pb.SelectFileRequest{
		Application:  app.Name,
		FilePath:     nonExistentPath,
		RevealFinder: false,
	})
	if err != nil {
		t.Logf("SelectFile returned RPC error for non-existent path (expected): %v", err)
		// RPC error is acceptable for non-existent file
	} else if selectResp2.Success {
		t.Errorf("SelectFile should NOT succeed for non-existent path")
	} else {
		t.Logf("SelectFile correctly reported failure: %s", selectResp2.Error)
	}

	// Test 3: SelectFile with empty path (should fail)
	t.Log("Test 3: SelectFile with empty path...")
	selectResp3, err := client.SelectFile(ctx, &pb.SelectFileRequest{
		Application:  app.Name,
		FilePath:     "",
		RevealFinder: false,
	})
	if err != nil {
		t.Logf("SelectFile returned RPC error for empty path (expected): %v", err)
		// RPC error is expected for validation failure
	} else if selectResp3.Success {
		t.Errorf("SelectFile should NOT succeed for empty path")
	} else {
		t.Logf("SelectFile correctly reported failure for empty path: %s", selectResp3.Error)
	}

	t.Log("SelectFile tests completed ✓")
}

// TestFileDialog_SelectDirectory verifies SelectDirectory operation.
func TestFileDialog_SelectDirectory(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Open Finder
	t.Log("Opening Finder...")
	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.finder")
	defer CleanupApplication(t, ctx, client, app.Name)

	// Wait for Finder to be ready
	t.Log("Waiting for Finder to be ready...")
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, nil
		}
		return len(resp.Windows) >= 0, nil
	})
	if err != nil {
		t.Fatalf("Finder did not become ready: %v", err)
	}

	// Create a temporary directory for testing
	tmpDir := t.TempDir()
	testDir := filepath.Join(tmpDir, "test_select_dir")
	if err := os.Mkdir(testDir, 0755); err != nil {
		t.Fatalf("Failed to create test directory: %v", err)
	}
	t.Logf("Created test directory: %s", testDir)

	// Test 1: SelectDirectory with valid path
	t.Log("Test 1: SelectDirectory with valid directory...")
	selectResp, err := client.SelectDirectory(ctx, &pb.SelectDirectoryRequest{
		Application:   app.Name,
		DirectoryPath: testDir,
		CreateMissing: false,
	})
	if err != nil {
		t.Errorf("SelectDirectory failed for valid directory: %v", err)
	} else {
		t.Logf("SelectDirectory response: success=%v, path=%s", selectResp.Success, selectResp.SelectedPath)
		if !selectResp.Success {
			t.Errorf("SelectDirectory should succeed for valid directory, got error: %s", selectResp.Error)
		}
	}

	// Test 2: SelectDirectory with non-existent path (without CreateMissing)
	t.Log("Test 2: SelectDirectory with non-existent path (no CreateMissing)...")
	nonExistentDir := filepath.Join(tmpDir, "does_not_exist_dir_12345")
	selectResp2, err := client.SelectDirectory(ctx, &pb.SelectDirectoryRequest{
		Application:   app.Name,
		DirectoryPath: nonExistentDir,
		CreateMissing: false,
	})
	if err != nil {
		t.Logf("SelectDirectory returned RPC error for non-existent path (expected): %v", err)
		// RPC error is acceptable for non-existent directory
	} else if selectResp2.Success {
		t.Errorf("SelectDirectory should NOT succeed for non-existent path without CreateMissing")
	} else {
		t.Logf("SelectDirectory correctly reported failure: %s", selectResp2.Error)
	}

	// Test 3: SelectDirectory with empty path (should fail)
	t.Log("Test 3: SelectDirectory with empty path...")
	selectResp3, err := client.SelectDirectory(ctx, &pb.SelectDirectoryRequest{
		Application:   app.Name,
		DirectoryPath: "",
		CreateMissing: false,
	})
	if err != nil {
		t.Logf("SelectDirectory returned RPC error for empty path (expected): %v", err)
		// RPC error is expected for validation failure
	} else if selectResp3.Success {
		t.Errorf("SelectDirectory should NOT succeed for empty path")
	} else {
		t.Logf("SelectDirectory correctly reported failure for empty path: %s", selectResp3.Error)
	}

	// Test 4: SelectDirectory pointing to a file (should fail)
	t.Log("Test 4: SelectDirectory with file path instead of directory...")
	tmpFile := filepath.Join(tmpDir, "not_a_dir.txt")
	if err := os.WriteFile(tmpFile, []byte("test"), 0600); err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	selectResp4, err := client.SelectDirectory(ctx, &pb.SelectDirectoryRequest{
		Application:   app.Name,
		DirectoryPath: tmpFile,
		CreateMissing: false,
	})
	if err != nil {
		t.Logf("SelectDirectory returned RPC error for file path (expected): %v", err)
	} else if selectResp4.Success {
		t.Errorf("SelectDirectory should NOT succeed when given a file path")
	} else {
		t.Logf("SelectDirectory correctly reported failure for file path: %s", selectResp4.Error)
	}

	t.Log("SelectDirectory tests completed ✓")
}
