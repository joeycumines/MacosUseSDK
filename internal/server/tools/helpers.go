// Copyright 2025 Joseph Cumines
//
// Tools helper package for MCP server

package tools

import (
	"context"
	"fmt"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	_type "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// OperationClient is a client for the Operations API
type OperationClient struct {
	Client longrunningpb.OperationsClient
}

// PollUntilComplete polls an operation until it completes
func PollUntilComplete(ctx context.Context, client *OperationClient, opName string, interval time.Duration) error {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			op, err := client.Client.GetOperation(ctx, &longrunningpb.GetOperationRequest{Name: opName})
			if err != nil {
				return fmt.Errorf("failed to get operation: %w", err)
			}

			if op.Done {
				if err := op.GetError(); err != nil {
					return fmt.Errorf("operation failed: %s", err.Message)
				}
				return nil
			}
		}
	}
}

// PollUntilContext polls a condition function until it returns true or the context times out
func PollUntilContext(ctx context.Context, interval time.Duration, condition func() (bool, error)) error {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			done, err := condition()
			if err != nil {
				return err
			}
			if done {
				return nil
			}
		}
	}
}

// WaitForElement waits for an element to appear
func WaitForElement(ctx context.Context, client pb.MacosUseClient, parent string, selector interface{}, timeout time.Duration) (*pb.FindElementsResponse, error) {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	deadline, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	for {
		select {
		case <-deadline.Done():
			return nil, fmt.Errorf("timeout waiting for element")
		case <-ticker.C:
			selBytes, _ := selector.([]byte)
			var sel *_type.ElementSelector
			if selBytes != nil {
				_ = selBytes // Could parse if needed
			}

			resp, err := client.FindElements(deadline, &pb.FindElementsRequest{
				Parent:   parent,
				Selector: sel,
			})
			if err != nil {
				continue
			}

			if len(resp.Elements) > 0 {
				return resp, nil
			}
		}
	}
}
