package integration

import (
	"context"
	"testing"

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
		if vf := d.GetVisibleFrame(); vf != nil {
			if vf.GetWidth() <= 0 || vf.GetHeight() <= 0 {
				t.Fatalf("display %d has non-positive visible frame dimensions: %vx%v", d.GetDisplayId(), vf.GetWidth(), vf.GetHeight())
			}
			if vf.GetWidth() > d.GetFrame().GetWidth() || vf.GetHeight() > d.GetFrame().GetHeight() {
				t.Fatalf("display %d visible frame larger than frame", d.GetDisplayId())
			}
			// Validate positional constraints in Global Display Coordinates
			if vf.GetX() < d.GetFrame().GetX() || vf.GetY() < d.GetFrame().GetY() {
				t.Fatalf("display %d visible frame position outside frame bounds: visible=(%v,%v) frame=(%v,%v)",
					d.GetDisplayId(), vf.GetX(), vf.GetY(), d.GetFrame().GetX(), d.GetFrame().GetY())
			}
			// Validate bottom-right corner is within frame bounds
			vfRight := vf.GetX() + vf.GetWidth()
			vfBottom := vf.GetY() + vf.GetHeight()
			frameRight := d.GetFrame().GetX() + d.GetFrame().GetWidth()
			frameBottom := d.GetFrame().GetY() + d.GetFrame().GetHeight()
			if vfRight > frameRight || vfBottom > frameBottom {
				t.Fatalf("display %d visible frame extends beyond frame: visible bottom-right=(%v,%v) frame bottom-right=(%v,%v)",
					d.GetDisplayId(), vfRight, vfBottom, frameRight, frameBottom)
			}
		}
	}
}
