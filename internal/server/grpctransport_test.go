// Copyright 2025 Joseph Cumines

package server

import (
	"bytes"
	"context"
	"net"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/joeycumines/ExactMac/internal/config"
	"google.golang.org/grpc"
)

const grpcLibraryDefaultReceiveBytes = 4 << 20

type largeScreenshotService struct {
	pb.UnimplementedExactMacServer
	imageData []byte
}

func (s *largeScreenshotService) CaptureScreenshot(
	context.Context,
	*pb.CaptureScreenshotRequest,
) (*pb.CaptureScreenshotResponse, error) {
	return &pb.CaptureScreenshotResponse{ImageData: s.imageData}, nil
}

func TestMCPGRPCTransportAcceptsPublicResponseAboveLibraryDefault(t *testing.T) {
	t.Parallel()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	imageData := bytes.Repeat([]byte{0xa5}, grpcLibraryDefaultReceiveBytes+1)
	grpcServer := grpc.NewServer()
	pb.RegisterExactMacServer(grpcServer, &largeScreenshotService{imageData: imageData})
	serveErr := make(chan error, 1)
	go func() {
		serveErr <- grpcServer.Serve(listener)
	}()
	t.Cleanup(func() {
		grpcServer.Stop()
		if err := <-serveErr; err != nil {
			t.Errorf("serve: %v", err)
		}
	})

	opts, err := grpcClientDialOptions(&config.Config{})
	if err != nil {
		t.Fatalf("production dial options: %v", err)
	}
	conn, err := grpc.NewClient(listener.Addr().String(), opts...)
	if err != nil {
		t.Fatalf("create client: %v", err)
	}
	t.Cleanup(func() {
		if err := conn.Close(); err != nil {
			t.Errorf("close client: %v", err)
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	response, err := pb.NewExactMacClient(conn).CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{})
	if err != nil {
		t.Fatalf("capture response larger than gRPC library default: %v", err)
	}
	if !bytes.Equal(response.GetImageData(), imageData) {
		t.Fatalf("image data mismatch: got %d bytes, want %d", len(response.GetImageData()), len(imageData))
	}
}
