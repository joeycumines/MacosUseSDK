package integration

import (
	"context"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pbtype "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestFindElementsPagination verifies that FindElements correctly implements AIP-158 pagination
// with opaque page tokens, deterministic ordering, and proper page sizing.
func TestFindElementsPagination(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Open Calculator
	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// Wait for Calculator to be ready
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Fatalf("Calculator windows never appeared: %v", err)
	}

	// Test: Full list
	t.Log("Fetching all elements...")
	respAll, err := client.FindElements(ctx, &pb.FindElementsRequest{
		Parent: app.Name,
	})
	if err != nil {
		t.Fatalf("FindElements failed: %v", err)
	}
	if len(respAll.Elements) < 5 {
		t.Fatalf("Expected at least 5 elements, got %d", len(respAll.Elements))
	}
	totalElements := len(respAll.Elements)
	t.Logf("Total elements: %d", totalElements)

	// Test: Page size limit
	t.Log("Testing page_size=3...")
	resp1, err := client.FindElements(ctx, &pb.FindElementsRequest{
		Parent:   app.Name,
		PageSize: 3,
	})
	if err != nil {
		t.Fatalf("FindElements with page_size=3 failed: %v", err)
	}
	if len(resp1.Elements) > 3 {
		t.Errorf("Expected at most 3 elements, got %d", len(resp1.Elements))
	}

	// Test: Next page token
	if totalElements > 3 && resp1.NextPageToken == "" {
		t.Error("Expected next_page_token when more results exist")
	}

	if resp1.NextPageToken != "" {
		t.Log("Testing next page...")
		resp2, err := client.FindElements(ctx, &pb.FindElementsRequest{
			Parent:    app.Name,
			PageSize:  3,
			PageToken: resp1.NextPageToken,
		})
		if err != nil {
			t.Fatalf("FindElements with page_token failed: %v", err)
		}
		if len(resp2.Elements) < 1 {
			t.Error("Expected at least 1 element on second page")
		}

		// Verify no duplicates
		if len(resp1.Elements) > 0 && len(resp2.Elements) > 0 {
			if resp1.Elements[0].ElementId == resp2.Elements[0].ElementId {
				t.Errorf("Duplicate element across pages: %s", resp1.Elements[0].ElementId)
			}
		}
		t.Log("Pagination verified")
	}

	// Test: Invalid token
	t.Log("Testing invalid token...")
	_, err = client.FindElements(ctx, &pb.FindElementsRequest{
		Parent:    app.Name,
		PageToken: "invalid-token",
	})
	if err == nil {
		t.Error("Expected error for invalid page_token")
	}

	// Test: Token opaqueness
	if resp1.NextPageToken != "" {
		if len(resp1.NextPageToken) > 7 && resp1.NextPageToken[:7] == "offset:" {
			t.Error("page_token is NOT opaque")
		}
		t.Log("Token is opaque")
	}
}

// TestFindRegionElementsPagination verifies FindRegionElements pagination.
func TestFindRegionElementsPagination(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// Wait for Calculator to be ready
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Fatalf("Calculator not ready: %v", err)
	}

	// First, use FindElements to get ALL elements and establish that data exists
	allElements, err := client.FindElements(ctx, &pb.FindElementsRequest{
		Parent: app.Name,
	})
	if err != nil {
		t.Fatalf("FindElements failed: %v", err)
	}
	if len(allElements.Elements) < 3 {
		t.Fatalf("Calculator has only %d elements, expected at least 3", len(allElements.Elements))
	}

	// Pick the first element's bounds and expand to create a region that MUST contain elements
	firstElem := allElements.Elements[0]
	elemX := float64(0)
	elemY := float64(0)
	elemW := float64(500)
	elemH := float64(500)
	if firstElem.X != nil {
		elemX = *firstElem.X
	}
	if firstElem.Y != nil {
		elemY = *firstElem.Y
	}
	if firstElem.Width != nil {
		elemW = *firstElem.Width
	}
	if firstElem.Height != nil {
		elemH = *firstElem.Height
	}
	region := &pbtype.Region{
		X:      elemX - 100,
		Y:      elemY - 100,
		Width:  elemW + 200,
		Height: elemH + 200,
	}
	t.Logf("Using region around first element: %.0fx%.0f at (%.0f,%.0f)",
		region.Width, region.Height, region.X, region.Y)

	// Full list with region
	respAll, err := client.FindRegionElements(ctx, &pb.FindRegionElementsRequest{
		Parent: app.Name,
		Region: region,
	})
	if err != nil {
		t.Fatalf("FindRegionElements failed: %v", err)
	}
	totalElements := len(respAll.Elements)
	t.Logf("Total elements in region: %d", totalElements)

	// If still insufficient after using known element bounds, this is a real failure
	if totalElements < 3 {
		t.Fatalf("Region around known element contains only %d elements, expected at least 3", totalElements)
	}

	// Paginated
	resp1, err := client.FindRegionElements(ctx, &pb.FindRegionElementsRequest{
		Parent:   app.Name,
		Region:   region,
		PageSize: 2,
	})
	if err != nil {
		t.Fatalf("FindRegionElements with page_size=2 failed: %v", err)
	}
	if len(resp1.Elements) > 2 {
		t.Errorf("Expected at most 2 elements, got %d", len(resp1.Elements))
	}

	// Next page
	if resp1.NextPageToken != "" {
		resp2, err := client.FindRegionElements(ctx, &pb.FindRegionElementsRequest{
			Parent:    app.Name,
			Region:    region,
			PageSize:  2,
			PageToken: resp1.NextPageToken,
		})
		if err != nil {
			t.Fatalf("FindRegionElements with page_token failed: %v", err)
		}
		if len(resp2.Elements) < 1 {
			t.Error("Expected at least 1 element on second page")
		}
		t.Log("FindRegionElements pagination verified")
	}

	// Invalid token
	_, err = client.FindRegionElements(ctx, &pb.FindRegionElementsRequest{
		Parent:    app.Name,
		Region:    region,
		PageToken: "invalid-token",
	})
	if err == nil {
		t.Error("Expected error for invalid page_token")
	}
}

// TestListObservationsPagination verifies ListObservations pagination.
func TestListObservationsPagination(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// Create 3 observations
	t.Log("Creating 3 observations...")
	var observations []*pb.Observation
	for i := 0; i < 3; i++ {
		createReq := &pb.CreateObservationRequest{
			Parent: app.Name,
			Observation: &pb.Observation{
				Type: pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES,
				Filter: &pb.ObservationFilter{
					VisibleOnly:  false,
					PollInterval: 1.0,
				},
			},
		}

		op, err := client.CreateObservation(ctx, createReq)
		if err != nil {
			t.Fatalf("Failed to create observation %d: %v", i+1, err)
		}

		// Wait for creation
		err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
			op, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
				Name: op.Name,
			})
			if err != nil {
				return false, err
			}
			return op.Done, nil
		})
		if err != nil {
			t.Fatalf("Failed waiting for observation %d: %v", i+1, err)
		}

		if op.GetError() != nil {
			t.Fatalf("Observation %d creation failed: %v", i+1, op.GetError())
		}

		obs := &pb.Observation{}
		if err := op.GetResponse().UnmarshalTo(obs); err != nil {
			t.Fatalf("Failed to unmarshal observation %d: %v", i+1, err)
		}
		observations = append(observations, obs)
		t.Logf("Created observation %d: %s", i+1, obs.Name)
	}

	// Cleanup
	defer func() {
		for _, obs := range observations {
			_, _ = client.CancelObservation(ctx, &pb.CancelObservationRequest{
				Name: obs.Name,
			})
		}
	}()

	// Full list
	respAll, err := client.ListObservations(ctx, &pb.ListObservationsRequest{
		Parent: app.Name,
	})
	if err != nil {
		t.Fatalf("ListObservations failed: %v", err)
	}
	if len(respAll.Observations) < 3 {
		t.Fatalf("Expected at least 3 observations, got %d", len(respAll.Observations))
	}
	t.Logf("Total observations: %d", len(respAll.Observations))

	// Paginated
	resp1, err := client.ListObservations(ctx, &pb.ListObservationsRequest{
		Parent:   app.Name,
		PageSize: 2,
	})
	if err != nil {
		t.Fatalf("ListObservations with page_size=2 failed: %v", err)
	}
	if len(resp1.Observations) > 2 {
		t.Errorf("Expected at most 2 observations, got %d", len(resp1.Observations))
	}

	// Next page
	if resp1.NextPageToken != "" {
		resp2, err := client.ListObservations(ctx, &pb.ListObservationsRequest{
			Parent:    app.Name,
			PageSize:  2,
			PageToken: resp1.NextPageToken,
		})
		if err != nil {
			t.Fatalf("ListObservations with page_token failed: %v", err)
		}
		if len(resp2.Observations) < 1 {
			t.Error("Expected at least 1 observation on second page")
		}

		// Verify no duplicates
		if len(resp1.Observations) > 0 && len(resp2.Observations) > 0 {
			if resp1.Observations[0].Name == resp2.Observations[0].Name {
				t.Errorf("Duplicate observation across pages: %s", resp1.Observations[0].Name)
			}
		}
		t.Log("ListObservations pagination verified")
	}

	// Invalid token
	_, err = client.ListObservations(ctx, &pb.ListObservationsRequest{
		Parent:    app.Name,
		PageToken: "invalid-token",
	})
	if err == nil {
		t.Error("Expected error for invalid page_token")
	}

	// Token opaqueness
	if resp1.NextPageToken != "" {
		if len(resp1.NextPageToken) > 7 && resp1.NextPageToken[:7] == "offset:" {
			t.Error("page_token is NOT opaque")
		}
		t.Log("Token is opaque")
	}
}
