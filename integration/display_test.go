package integration

import (
	"context"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

func TestListDisplays(t *testing.T) {
	ctx := context.Background()
	cmd, addr := startServer(t, ctx)
	defer cleanupServer(t, cmd)

	conn := connectToServer(t, ctx, addr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	// Make the call
	resp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays RPC failed: %v", err)
	}

	if len(resp.Displays) == 0 {
		t.Fatalf("expected at least one display, got 0")
	}

	// Validate fields look sane
	for _, d := range resp.Displays {
		if d.GetDisplayId() == 0 {
			t.Fatalf("display had zero id")
		}
		if d.GetFrame() == nil {
			t.Fatalf("display frame is nil for display %d", d.GetDisplayId())
		}
		if d.GetFrame().GetWidth() <= 0 || d.GetFrame().GetHeight() <= 0 {
			t.Fatalf("display %d has non-positive frame dimensions: %vx%v", d.GetDisplayId(), d.GetFrame().GetWidth(), d.GetFrame().GetHeight())
		}
		if d.GetScale() <= 0 {
			t.Fatalf("display %d has non-positive scale %v", d.GetDisplayId(), d.GetScale())
		}
		if d.GetVisibleFrame() != nil {
			vf := d.GetVisibleFrame()
			if vf.GetWidth() > d.GetFrame().GetWidth() || vf.GetHeight() > d.GetFrame().GetHeight() {
				t.Fatalf("display %d visible frame larger than frame", d.GetDisplayId())
			}
		}
	}

	// Sanity wait so we don't race with server teardown
	tctx, cancel := context.WithTimeout(ctx, 1*time.Second)
	defer cancel()
	_ = tctx
}






















		}			}				t.Fatalf("display %d visible frame larger than frame", d.GetDisplayId())			if vf.GetWidth() > d.GetFrame().GetWidth() || vf.GetHeight() > d.GetFrame().GetHeight() {			vf := d.GetVisibleFrame()		if d.GetVisibleFrame() != nil {		// visible frame should fit within the frame		}			t.Fatalf("display %d has non-positive scale %v", d.GetDisplayId(), d.GetScale())		if d.GetScale() <= 0 {		}			t.Fatalf("display %d has non-positive frame dimensions: %vx%v", d.GetDisplayId(), d.GetFrame().GetWidth(), d.GetFrame().GetHeight())		if d.GetFrame().GetWidth() <= 0 || d.GetFrame().GetHeight() <= 0 {		}			t.Fatalf("display frame is nil for display %d", d.GetDisplayId())		if d.GetFrame() == nil {		}			t.Fatalf("display had zero id")		if d.GetDisplayId() == 0 {	for _, d := range resp.Displays {	// Validate fields look sane	}		t.Fatalf("expected at least one display, got 0")	if len(resp.Displays) == 0 {	}		t.Fatalf("ListDisplays RPC failed: %v", err)	if err != nil {	resp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})	// Make the call	client := pb.NewMacosUseClient(conn)