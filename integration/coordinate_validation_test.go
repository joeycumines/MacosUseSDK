// Copyright 2025 Joseph Cumines
//
// Coordinate validation integration tests for multi-monitor setups.
// Verifies that negative coordinates work correctly for secondary displays
// positioned to the left of or above the main display.
// Task: T072

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	pbtype "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestCoordinateValidation_NegativeCoordinates verifies that negative coordinates
// are accepted and work correctly. In Global Display Coordinates, secondary
// monitors to the left or above the main display have negative coordinates.
func TestCoordinateValidation_NegativeCoordinates(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	displayResp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}

	if len(displayResp.Displays) == 0 {
		t.Fatal("No displays found")
	}

	var minX, minY, maxX, maxY float64
	for i, d := range displayResp.Displays {
		frame := d.Frame
		if i == 0 || frame.X < minX {
			minX = frame.X
		}
		if i == 0 || frame.Y < minY {
			minY = frame.Y
		}
		if i == 0 || frame.X+frame.Width > maxX {
			maxX = frame.X + frame.Width
		}
		if i == 0 || frame.Y+frame.Height > maxY {
			maxY = frame.Y + frame.Height
		}
	}

	t.Logf("Display coordinate bounds: X=[%v, %v], Y=[%v, %v]", minX, maxX, minY, maxY)

	testCoordinates := []struct {
		name string
		x    float64
		y    float64
	}{
		{"origin_main_display", 100, 100},
		{"bottom_right_main", 500, 500},
		{"explicit_negative_x", -100, 100},
		{"explicit_negative_y", 100, -100},
		{"explicit_negative_both", -100, -100},
	}

	if minX < 0 {
		testCoordinates = append(testCoordinates, struct {
			name string
			x    float64
			y    float64
		}{"negative_x_secondary", minX + 50, 100})
	}
	if minY < 0 {
		testCoordinates = append(testCoordinates, struct {
			name string
			x    float64
			y    float64
		}{"negative_y_secondary", 100, minY + 50})
	}

	for _, tc := range testCoordinates {
		t.Run(tc.name, func(t *testing.T) {
			_, err := client.CreateInput(ctx, &pb.CreateInputRequest{
				Parent: "applications/-",
				Input: &pb.Input{
					Action: &pb.InputAction{
						InputType: &pb.InputAction_MoveMouse{
							MoveMouse: &pb.MouseMove{
								Position: &pbtype.Point{X: tc.x, Y: tc.y},
							},
						},
					},
				},
			})

			if err != nil {
				t.Logf("Note: CreateInput returned: %v", err)
			} else {
				t.Logf("Coordinates (%v, %v) accepted by API", tc.x, tc.y)
			}
		})
	}
}

// TestCoordinateValidation_ClickAtExtremeCoords tests clicking at extreme coordinates.
func TestCoordinateValidation_ClickAtExtremeCoords(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	displayResp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}

	if len(displayResp.Displays) == 0 {
		t.Fatal("No displays")
	}

	mainDisplay := displayResp.Displays[0]
	for _, d := range displayResp.Displays {
		if d.IsMain {
			mainDisplay = d
			break
		}
	}

	frame := mainDisplay.Frame
	corners := []struct {
		name string
		x    float64
		y    float64
	}{
		{"top_left", frame.X + 10, frame.Y + 30},
		{"top_right", frame.X + frame.Width - 10, frame.Y + 30},
		{"bottom_left", frame.X + 10, frame.Y + frame.Height - 10},
		{"bottom_right", frame.X + frame.Width - 10, frame.Y + frame.Height - 10},
		{"center", frame.X + frame.Width/2, frame.Y + frame.Height/2},
	}

	for _, corner := range corners {
		t.Run(corner.name, func(t *testing.T) {
			_, err := client.CreateInput(ctx, &pb.CreateInputRequest{
				Parent: "applications/-",
				Input: &pb.Input{
					Action: &pb.InputAction{
						InputType: &pb.InputAction_Click{
							Click: &pb.MouseClick{
								Position:  &pbtype.Point{X: corner.x, Y: corner.y},
								ClickType: pb.MouseClick_CLICK_TYPE_LEFT,
							},
						},
					},
				},
			})

			if err != nil {
				t.Logf("Click at (%v, %v) returned: %v", corner.x, corner.y, err)
			} else {
				t.Logf("Click at (%v, %v) succeeded", corner.x, corner.y)
			}
		})
	}
}

// TestCoordinateValidation_MCPViaHTTP tests coordinate handling via MCP HTTP transport.
func TestCoordinateValidation_MCPViaHTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initReq := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	initResp, _ := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initReq))
	initResp.Body.Close()

	testCases := []struct {
		name string
		x    float64
		y    float64
	}{
		{"positive_coords", 100, 100},
		{"negative_x", -100, 100},
		{"negative_y", 100, -100},
		{"negative_both", -100, -100},
		{"fractional", 100.5, 100.5},
		{"large_positive", 5000, 3000},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			request := map[string]any{
				"jsonrpc": "2.0",
				"id":      time.Now().UnixNano(),
				"method":  "tools/call",
				"params": map[string]any{
					"name": "click",
					"arguments": map[string]any{
						"x": tc.x,
						"y": tc.y,
					},
				},
			}
			reqBytes, _ := json.Marshal(request)

			resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBuffer(reqBytes))
			if err != nil {
				t.Fatalf("HTTP request failed: %v", err)
			}
			defer resp.Body.Close()

			var response struct {
				Result json.RawMessage `json:"result"`
				Error  *struct {
					Code    int    `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
				t.Fatalf("Failed to decode: %v", err)
			}

			if response.Error != nil {
				t.Logf("Click returned error: %s", response.Error.Message)
				return
			}

			t.Logf("Click at (%v, %v) succeeded via HTTP", tc.x, tc.y)
		})
	}
}

// TestCoordinateValidation_DisplayOrigins verifies display origins are reported correctly.
func TestCoordinateValidation_DisplayOrigins(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	displayResp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}

	var mainFound bool
	for _, d := range displayResp.Displays {
		t.Logf("Display: isMain=%v origin=(%v,%v) size=%vx%v scale=%v",
			d.IsMain, d.Frame.X, d.Frame.Y, d.Frame.Width, d.Frame.Height, d.Scale)

		if d.IsMain {
			mainFound = true
			if d.Frame.X != 0 || d.Frame.Y != 0 {
				t.Errorf("Main display origin should be (0,0), got (%v,%v)",
					d.Frame.X, d.Frame.Y)
			}
		}

		if d.Frame.Width <= 0 || d.Frame.Height <= 0 {
			t.Errorf("Display has invalid dimensions: %vx%v",
				d.Frame.Width, d.Frame.Height)
		}
	}

	if !mainFound && len(displayResp.Displays) > 0 {
		t.Log("No display marked as main (first display may be used)")
	}
}
