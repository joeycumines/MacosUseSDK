// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"math"
	"testing"
	"time"

	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/protobuf/proto"
)

func requireClipboardSnapshot(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
) *pb.ClipboardContent {
	t.Helper()
	clipboard, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil {
		t.Fatalf("snapshot clipboard: %v", err)
	}
	if clipboard.GetContent() == nil {
		return nil
	}
	return proto.Clone(clipboard.GetContent()).(*pb.ClipboardContent)
}

func restoreClipboardSnapshot(
	t *testing.T,
	client pb.ExactMacClient,
	content *pb.ClipboardContent,
) {
	t.Helper()
	restoreCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if content == nil {
		if _, err := client.ClearClipboard(restoreCtx, &pb.ClearClipboardRequest{}); err != nil {
			t.Errorf("restore empty clipboard: %v", err)
			return
		}
	} else {
		if _, err := client.WriteClipboard(restoreCtx, &pb.WriteClipboardRequest{
			Content: proto.Clone(content).(*pb.ClipboardContent),
		}); err != nil {
			t.Errorf("restore clipboard: %v", err)
			return
		}
	}
	restored, err := client.GetClipboard(restoreCtx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil || !proto.Equal(restored.GetContent(), content) {
		t.Errorf("clipboard restoration response=%+v error=%v want=%+v", restored, err, content)
	}
}

func requireCursorSnapshot(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
) (*pb.CaptureCursorPositionResponse, []*pb.Display) {
	t.Helper()
	displayList, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{PageSize: 1000})
	if err != nil || len(displayList.GetDisplays()) == 0 {
		t.Fatalf("snapshot displays response=%+v error=%v", displayList, err)
	}
	cursor, err := client.CaptureCursorPosition(ctx, &pb.CaptureCursorPositionRequest{})
	if err != nil || cursor.GetDisplay() == "" ||
		math.IsNaN(cursor.GetX()) || math.IsInf(cursor.GetX(), 0) ||
		math.IsNaN(cursor.GetY()) || math.IsInf(cursor.GetY(), 0) {
		t.Fatalf("snapshot cursor response=%+v error=%v", cursor, err)
	}
	return proto.Clone(cursor).(*pb.CaptureCursorPositionResponse), displayList.GetDisplays()
}

func restoreCursorSnapshot(
	t *testing.T,
	client pb.ExactMacClient,
	cursor *pb.CaptureCursorPositionResponse,
) {
	t.Helper()
	restoreCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	point := &typepb.Point{X: cursor.GetX(), Y: cursor.GetY()}
	request := newIntegrationInputRequest(
		t,
		"applications/-",
		&pb.InputTarget{
			Destination: &pb.InputTarget_Display{Display: cursor.GetDisplay()},
		},
		&pb.InputAction{
			InputType: &pb.InputAction_MouseMove{MouseMove: &pb.MouseMove{
				Position: point,
			}},
		},
	)
	createCompletedInput(t, restoreCtx, client, request, 1, "restore exact cursor")
	requireCursorAt(t, restoreCtx, client, point)
}

func requireCursorAt(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	want *typepb.Point,
) {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	var got *pb.CaptureCursorPositionResponse
	if err := PollUntilContext(waitCtx, 20*time.Millisecond, func() (bool, error) {
		var err error
		got, err = client.CaptureCursorPosition(waitCtx, &pb.CaptureCursorPositionRequest{})
		if err != nil {
			return false, nil
		}
		return math.Abs(got.GetX()-want.GetX()) <= 1 &&
			math.Abs(got.GetY()-want.GetY()) <= 1, nil
	}); err != nil {
		t.Fatalf("cursor did not converge to %+v; last=%+v: %v", want, got, err)
	}
	if got.GetDisplay() == "" {
		t.Fatalf("converged cursor response omitted its exact display identity: %+v", got)
	}
}
