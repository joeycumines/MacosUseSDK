package integration

import (
	"context"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

// TestHealthCheck_Serving verifies the health service returns SERVING status
// when the gRPC server is healthy and accepting requests.
// This tests the overall server health (empty service name).
func TestHealthCheck_Serving(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	if serverCmd != nil {
		defer cleanupServer(t, serverCmd, serverAddr)
	}

	// Connect to server
	conn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	client := healthpb.NewHealthClient(conn)

	// Check overall server health (empty service name)
	resp, err := client.Check(ctx, &healthpb.HealthCheckRequest{
		Service: "",
	})
	if err != nil {
		t.Fatalf("Health check failed: %v", err)
	}

	if resp.Status != healthpb.HealthCheckResponse_SERVING {
		t.Errorf("Expected SERVING status, got %v", resp.Status)
	}

	t.Logf("Health check returned status: %v", resp.Status)
}

// TestHealthCheck_MacosUseService verifies the health check for the specific
// MacosUse service returns SERVING status.
func TestHealthCheck_MacosUseService(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	if serverCmd != nil {
		defer cleanupServer(t, serverCmd, serverAddr)
	}

	// Connect to server
	conn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	client := healthpb.NewHealthClient(conn)

	// Check MacosUse service health
	resp, err := client.Check(ctx, &healthpb.HealthCheckRequest{
		Service: "macosusesdk.v1.MacosUse",
	})
	if err != nil {
		t.Fatalf("Health check failed: %v", err)
	}

	if resp.Status != healthpb.HealthCheckResponse_SERVING {
		t.Errorf("Expected SERVING status, got %v", resp.Status)
	}

	t.Logf("Health check for macosusesdk.v1.MacosUse returned status: %v", resp.Status)
}

// TestHealthCheck_UnknownService verifies the health check for an unknown
// service returns an appropriate error (NOT_FOUND).
// Per gRPC health protocol spec, unknown services should return NOT_FOUND status code.
func TestHealthCheck_UnknownService(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	if serverCmd != nil {
		defer cleanupServer(t, serverCmd, serverAddr)
	}

	// Connect to server
	conn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	client := healthpb.NewHealthClient(conn)

	// Check unknown service - should fail or return unknown status
	resp, err := client.Check(ctx, &healthpb.HealthCheckRequest{
		Service: "unknown.service.NotRegistered",
	})

	// The gRPC health spec says unknown services should return NOT_FOUND error
	// or SERVICE_UNKNOWN status depending on implementation
	if err != nil {
		// Expected - unknown service returns error
		t.Logf("Unknown service correctly returned error: %v", err)
		return
	}

	// If no error, status should indicate unknown
	if resp.Status == healthpb.HealthCheckResponse_SERVING {
		t.Errorf("Unknown service should not return SERVING status")
	}
	t.Logf("Unknown service returned status: %v", resp.Status)
}
