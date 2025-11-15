package main

import (
	"log"
	// TODO: Uncomment once proto stubs are generated
	// pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	// "google.golang.org/grpc"
	// "google.golang.org/grpc/credentials/insecure"
)

// Example Go client demonstrating all major features of the MacosUseSDK gRPC API
func main() {
	// TODO: Uncomment and complete once proto stubs are generated
	log.Println("This example will be functional once proto stubs are generated")
	log.Println("Run 'make proto' to generate the stubs")

	/*
		// Connect to the server
		conn, err := grpc.NewClient(
			"localhost:8080",
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		if err != nil {
			log.Fatalf("Failed to connect: %v", err)
		}
		defer conn.Close()

		desktopClient := pb.NewDesktopServiceClient(conn)
		targetsClient := pb.NewTargetApplicationsServiceClient(conn)

		ctx := context.Background()

		// Example 1: Open Calculator
		fmt.Println("=== Example 1: Opening Calculator ===")
		target, err := desktopClient.OpenApplication(ctx, &pb.OpenApplicationRequest{
			Identifier: "Calculator",
		})
		if err != nil {
			log.Fatalf("Failed to open Calculator: %v", err)
		}
		fmt.Printf("Opened Calculator: %s (PID: %d)\n", target.AppName, target.Pid)

		// Example 2: List all tracked applications
		fmt.Println("\n=== Example 2: Listing Tracked Applications ===")
		listResp, err := targetsClient.ListTargetApplications(ctx, &pb.ListTargetApplicationsRequest{})
		if err != nil {
			log.Fatalf("Failed to list targets: %v", err)
		}
		for _, app := range listResp.TargetApplications {
			fmt.Printf("- %s (PID: %d)\n", app.AppName, app.Pid)
		}

		// Example 3: Perform an action (type into Calculator)
		fmt.Println("\n=== Example 3: Typing into Calculator ===")
		actionResp, err := targetsClient.PerformAction(ctx, &pb.PerformActionRequest{
			Name: target.Name,
			Action: &pb.PrimaryAction{
				ActionType: &pb.PrimaryAction_Input{
					Input: &pb.InputAction{
						ActionType: &pb.InputAction_TypeText{
							TypeText: "123+456=",
						},
					},
				},
			},
			Options: &pb.ActionOptions{
				ShowAnimation:      true,
				AnimationDuration:  0.5,
				TraverseBefore:     true,
				TraverseAfter:      true,
				ShowDiff:           true,
				DelayAfterAction:   0.3,
			},
		})
		if err != nil {
			log.Fatalf("Failed to perform action: %v", err)
		}

		if actionResp.TraversalDiff != nil {
			fmt.Printf("Diff - Added: %d, Removed: %d, Modified: %d\n",
				len(actionResp.TraversalDiff.Added),
				len(actionResp.TraversalDiff.Removed),
				len(actionResp.TraversalDiff.Modified))
		}

		// Example 4: Watch for changes (streaming)
		fmt.Println("\n=== Example 4: Watching for UI changes ===")
		watchCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()

		stream, err := targetsClient.Watch(watchCtx, &pb.WatchRequest{
			Name:                 target.Name,
			PollIntervalSeconds: 1.0,
		})
		if err != nil {
			log.Fatalf("Failed to start watch: %v", err)
		}

		// Read watch events for a bit
		fmt.Println("Watching for changes (press Ctrl+C to stop)...")
		for {
			resp, err := stream.Recv()
			if err == io.EOF {
				break
			}
			if err != nil {
				log.Printf("Watch error: %v", err)
				break
			}

			if resp.Diff != nil {
				fmt.Printf("Change detected - Added: %d, Removed: %d, Modified: %d\n",
					len(resp.Diff.Added),
					len(resp.Diff.Removed),
					len(resp.Diff.Modified))
			}
		}

		// Example 5: Execute global input (click anywhere)
		fmt.Println("\n=== Example 5: Global Mouse Click ===")
		_, err = desktopClient.ExecuteGlobalInput(ctx, &pb.ExecuteGlobalInputRequest{
			Input: &pb.InputAction{
				ActionType: &pb.InputAction_Click{
					Click: &pb.Point{X: 500, Y: 500},
				},
			},
			ShowAnimation:     true,
			AnimationDuration: 0.8,
		})
		if err != nil {
			log.Fatalf("Failed to execute global input: %v", err)
		}
		fmt.Println("Clicked at (500, 500)")

		// Example 6: Clean up - remove target from tracking
		fmt.Println("\n=== Example 6: Cleanup ===")
		_, err = targetsClient.DeleteTargetApplication(ctx, &pb.DeleteTargetApplicationRequest{
			Name: target.Name,
		})
		if err != nil {
			log.Fatalf("Failed to delete target: %v", err)
		}
		fmt.Printf("Removed %s from tracking\n", target.Name)

		fmt.Println("\n=== All examples completed successfully ===")
	*/
}
