package integration

import (
	"context"
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

	// Try to quit the application first using DeleteApplication (graceful)
	_, err := client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{
		Name: app.Name,
	})
	if err != nil {
		t.Logf("Warning: Failed to delete application: %v", err)
	}

	// Poll to verify application is removed
	timeoutCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	err = PollUntilContext(timeoutCtx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
		if err != nil {
			return false, err
		}
		// Application is gone when it's no longer in the list
		for _, a := range resp.Applications {
			if a.Name == app.Name {
				return false, nil
			}
		}
		return true, nil
	})
	if err != nil {
		t.Logf("Warning: Application may not have been fully cleaned up: %v", err)
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

	// Poll until input is completed (state-delta check)
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		inputStatus, err := client.GetInput(ctx, &pb.GetInputRequest{
			Name: input.Name,
		})
		if err != nil {
			return false, err
		}
		// Input is complete when state is COMPLETED or FAILED
		return inputStatus.State == pb.Input_STATE_COMPLETED ||
			inputStatus.State == pb.Input_STATE_FAILED, nil
	})
	if err != nil {
		t.Logf("Warning: Failed to wait for input completion: %v", err)
		// Don't fail the test, but log the issue
	}
}
