package integration

import (
	"context"
	"os/exec"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// cleanupApplication removes the application from tracking and quits the app
func cleanupApplication(t *testing.T, ctx context.Context, client pb.MacosUseClient, app *pb.Application) {
	if app == nil {
		return
	}

	t.Logf("Cleaning up application: %s", app.Name)

	// Try to quit the application first
	quitScript := `tell application "System Events" to quit application "Calculator"`
	exec.Command("osascript", "-e", quitScript).Run()
	time.Sleep(500 * time.Millisecond)

	_, err := client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{
		Name: app.Name,
	})
	if err != nil {
		t.Logf("Warning: Failed to delete application: %v", err)
	}
}

// performInput creates and executes an input action
func performInput(t *testing.T, ctx context.Context, client pb.MacosUseClient, app *pb.Application, text string) {
	input, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: app.Name,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_TypeText{
					TypeText: &pb.TextInput{
						Text: text,
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Failed to create input '%s': %v", text, err)
	}

	t.Logf("Input created and executed: %s", input.Name)

	// Wait for input to be fully processed by Calculator
	// TODO: this would be better with PollUntilContext
	time.Sleep(500 * time.Millisecond)
}
