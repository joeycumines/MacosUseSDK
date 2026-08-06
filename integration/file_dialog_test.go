package integration

import (
	"context"
	"errors"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func requireFileDialogCode(t *testing.T, err error, want codes.Code) {
	t.Helper()
	if got := status.Code(err); got != want {
		t.Fatalf("RPC code = %s, want %s (error: %v)", got, want, err)
	}
}

// TestFileDialog_FailsClosed proves the application-bound file-dialog surface
// cannot claim success or mutate filesystem state until target-owned automation exists.
//
// The granular SelectFile/SelectDirectory/DragFiles RPCs were removed in favor of
// the consolidated AutomateOpenFileDialog/AutomateSaveFileDialog custom methods
// (AIP-136). This test exercises only the two live RPCs.
func TestFileDialog_FailsClosed(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	const application = "applications/424242"
	missingDirectory := filepath.Join(t.TempDir(), "must-not-be-created")

	calls := []struct {
		name string
		call func() error
	}{
		{
			name: "AutomateOpenFileDialog",
			call: func() error {
				_, err := client.AutomateOpenFileDialog(
					ctx,
					&pb.AutomateOpenFileDialogRequest{Application: application},
				)
				return err
			},
		},
		{
			name: "AutomateSaveFileDialog",
			call: func() error {
				_, err := client.AutomateSaveFileDialog(
					ctx,
					&pb.AutomateSaveFileDialogRequest{
						Application: application,
						FilePath:    filepath.Join(missingDirectory, "output.txt"),
					},
				)
				return err
			},
		},
	}

	for _, test := range calls {
		t.Run(test.name, func(t *testing.T) {
			requireFileDialogCode(t, test.call(), codes.Unimplemented)
		})
	}

	// The capability is unimplemented: it must not have created the save target's
	// parent directory or any file before reporting failure.
	if _, err := os.Stat(missingDirectory); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("AutomateSaveFileDialog mutated filesystem before failing closed: %v", err)
	}
}

// TestFileDialog_ValidatesMalformedRequestsBeforeCapabilityError proves malformed
// requests are rejected with InvalidArgument before the Unimplemented capability
// error is reached.
func TestFileDialog_ValidatesMalformedRequestsBeforeCapabilityError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	const application = "applications/424242"

	// Missing required application resource reference.
	_, err := client.AutomateOpenFileDialog(
		ctx,
		&pb.AutomateOpenFileDialogRequest{},
	)
	requireFileDialogCode(t, err, codes.InvalidArgument)

	// Missing required application resource reference.
	_, err = client.AutomateSaveFileDialog(
		ctx,
		&pb.AutomateSaveFileDialogRequest{FilePath: "/tmp/output.txt"},
	)
	requireFileDialogCode(t, err, codes.InvalidArgument)

	// NaN timeout is not a finite, usable duration and must be rejected.
	_, err = client.AutomateSaveFileDialog(
		ctx,
		&pb.AutomateSaveFileDialogRequest{
			Application: application,
			FilePath:    "/tmp/output.txt",
			Timeout:     math.NaN(),
		},
	)
	requireFileDialogCode(t, err, codes.InvalidArgument)
}
