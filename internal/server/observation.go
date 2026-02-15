// Copyright 2025 Joseph Cumines
//
// Observation tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/protobuf/encoding/protojson"
)

// handleCreateObservation handles the create_observation tool
func (s *MCPServer) handleCreateObservation(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent       string   `json:"parent"`
		Type         string   `json:"type"`
		Roles        []string `json:"roles"`
		Attributes   []string `json:"attributes"`
		PollInterval float64  `json:"poll_interval"`
		VisibleOnly  bool     `json:"visible_only"`
		Activate     bool     `json:"activate"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Parent == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "parent parameter is required (e.g., applications/{id})"}},
		}, nil
	}

	// Map observation type string to enum
	obsType := pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES
	switch params.Type {
	case "element_changes", "element":
		obsType = pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES
	case "window_changes", "window":
		obsType = pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES
	case "application_changes", "application":
		obsType = pb.ObservationType_OBSERVATION_TYPE_APPLICATION_CHANGES
	case "attribute_changes", "attribute":
		obsType = pb.ObservationType_OBSERVATION_TYPE_ATTRIBUTE_CHANGES
	case "tree_changes", "tree":
		obsType = pb.ObservationType_OBSERVATION_TYPE_TREE_CHANGES
	}

	observation := &pb.Observation{
		Type: obsType,
	}

	// Add filter if specified
	if params.VisibleOnly || params.PollInterval > 0 || len(params.Roles) > 0 || len(params.Attributes) > 0 {
		observation.Filter = &pb.ObservationFilter{
			PollInterval: params.PollInterval,
			VisibleOnly:  params.VisibleOnly,
			Roles:        params.Roles,
			Attributes:   params.Attributes,
		}
	}

	observation.Activate = params.Activate

	op, err := s.client.CreateObservation(ctx, &pb.CreateObservationRequest{
		Parent:      params.Parent,
		Observation: observation,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to create observation: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Created observation operation: %s\nDone: %v", op.Name, op.Done),
		}},
	}, nil
}

// handleGetObservation handles the get_observation tool
func (s *MCPServer) handleGetObservation(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string `json:"name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	obs, err := s.client.GetObservation(ctx, &pb.GetObservationRequest{
		Name: params.Name,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get observation: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf(`Observation: %s
  Type: %s
  State: %s
  Created: %v`,
				obs.Name, obs.Type.String(), obs.State.String(), obs.CreateTime),
		}},
	}, nil
}

// handleListObservations handles the list_observations tool
func (s *MCPServer) handleListObservations(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent string `json:"parent"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	resp, err := s.client.ListObservations(ctx, &pb.ListObservationsRequest{
		Parent: params.Parent,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to list observations: %v", err)}},
		}, nil
	}

	if len(resp.Observations) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No observations found"}},
		}, nil
	}

	var lines []string
	for _, obs := range resp.Observations {
		lines = append(lines, fmt.Sprintf("- %s (%s, %s)", obs.Name, obs.Type.String(), obs.State.String()))
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Found %d observations:\n%s", len(resp.Observations), strings.Join(lines, "\n")),
		}},
	}, nil
}

// handleCancelObservation handles the cancel_observation tool
func (s *MCPServer) handleCancelObservation(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string `json:"name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	obs, err := s.client.CancelObservation(ctx, &pb.CancelObservationRequest{
		Name: params.Name,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to cancel observation: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Cancelled observation: %s (state: %s)", obs.Name, obs.State.String()),
		}},
	}, nil
}

// handleStreamObservations handles the stream_observations tool
// For HTTP/SSE transport: Starts background streaming and broadcasts events via SSE.
// For stdio transport: Returns current state with polling instructions.
// Reconnection hints are included in error responses to help clients recover.
func (s *MCPServer) handleStreamObservations(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name    string  `json:"name"`
		Timeout float64 `json:"timeout"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v\nReconnection hint: Verify JSON schema and retry.", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required\nReconnection hint: Provide the observation resource name (e.g., observations/{id})."}},
		}, nil
	}

	// Get observation to verify it exists and is active
	obs, err := s.client.GetObservation(ctx, &pb.GetObservationRequest{
		Name: params.Name,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get observation: %v\nReconnection hint: Check observation name with list_observations, then retry.", err)}},
		}, nil
	}

	// Check if observation is in a terminal state
	if obs.State == pb.Observation_STATE_COMPLETED || obs.State == pb.Observation_STATE_CANCELLED || obs.State == pb.Observation_STATE_FAILED {
		return &ToolResult{
			Content: []Content{{
				Type: "text",
				Text: fmt.Sprintf("Observation %s is already %s - no events to stream.\nReconnection hint: Create a new observation with create_observation to continue monitoring.",
					obs.Name, obs.State.String()),
			}},
		}, nil
	}

	// Check if HTTP transport is available for true SSE streaming
	s.mu.RLock()
	httpTransport := s.httpTransport
	s.mu.RUnlock()

	if httpTransport != nil {
		// HTTP transport available - start background streaming
		return s.startObservationStream(params.Name, obs, httpTransport)
	}

	// For stdio transport, we can't do true streaming
	// Return a message explaining the limitation and current state
	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf(`Streaming observation %s:
  Type: %s
  State: %s
  Note: True streaming requires SSE over HTTP transport.
  Over stdio, use list_observations and get_observation to poll for changes.
  Reconnection hint: Connect to GET /events with Last-Event-ID header for SSE streaming with reconnection support.`,
				obs.Name, obs.Type.String(), obs.State.String()),
		}},
	}, nil
}

// startObservationStream starts background streaming for an observation over SSE.
// It spawns a goroutine that calls the gRPC StreamObservations RPC and broadcasts
// events to SSE clients. The goroutine exits on: observation completion, cancellation,
// gRPC error, or transport shutdown.
func (s *MCPServer) startObservationStream(name string, obs *pb.Observation, httpTransport interface {
	BroadcastEvent(eventType string, data string)
	ShutdownChan() <-chan struct{}
	IsClosed() bool
}) (*ToolResult, error) {
	// Start background streaming goroutine
	go func() {
		// Create a fresh context for the stream (not the request context)
		streamCtx, streamCancel := context.WithCancel(s.ctx)
		defer streamCancel()

		stream, err := s.client.StreamObservations(streamCtx, &pb.StreamObservationsRequest{
			Name: name,
		})
		if err != nil {
			log.Printf("Failed to start observation stream for %s: %v", name, err)
			// Broadcast error event with reconnection hint
			errorData := fmt.Sprintf(`{"observation":"%s","error":"%s","reconnection_hint":"Retry stream_observations after verifying observation state"}`, name, err.Error())
			httpTransport.BroadcastEvent("observation_error", errorData)
			return
		}

		log.Printf("Started observation stream for %s", name)

		// Use channels to properly detect shutdown while Recv() is blocking.
		// The receiver goroutine sends results to recvCh/errCh, allowing the main
		// loop to select on shutdown signals without being blocked in Recv().
		type recvResult struct {
			resp *pb.StreamObservationsResponse
			err  error
		}
		recvCh := make(chan recvResult)

		// Receiver goroutine - reads from stream and sends to channel
		go func() {
			for {
				resp, err := stream.Recv()
				select {
				case recvCh <- recvResult{resp, err}:
					if err != nil {
						return // Exit receiver on error
					}
				case <-streamCtx.Done():
					return // Context cancelled, exit receiver
				}
			}
		}()

		// Stream events until done
		for {
			select {
			case <-httpTransport.ShutdownChan():
				log.Printf("Shutting down observation stream for %s (transport shutdown)", name)
				streamCancel() // Cancel stream context to stop receiver goroutine
				// Broadcast shutdown event with reconnection hint
				shutdownData := fmt.Sprintf(`{"observation":"%s","reason":"server_shutdown","reconnection_hint":"Reconnect to /events with Last-Event-ID after server restart"}`, name)
				httpTransport.BroadcastEvent("observation_shutdown", shutdownData)
				return
			case <-streamCtx.Done():
				log.Printf("Observation stream context cancelled for %s", name)
				return
			case result := <-recvCh:
				if result.err != nil {
					// Stream ended (EOF) or error
					log.Printf("Observation stream ended for %s: %v", name, result.err)
					// Broadcast stream end event
					endData := fmt.Sprintf(`{"observation":"%s","reason":"stream_ended","error":"%v","reconnection_hint":"Check observation state with get_observation and restart if needed"}`, name, result.err)
					httpTransport.BroadcastEvent("observation_stream_end", endData)
					return
				}

				// Marshal event to JSON for SSE broadcast
				if result.resp != nil && result.resp.Event != nil {
					eventJSON, err := protojson.Marshal(result.resp.Event)
					if err != nil {
						log.Printf("Failed to marshal observation event: %v", err)
						continue
					}
					// Broadcast the observation event
					httpTransport.BroadcastEvent("observation", string(eventJSON))
				}
			}
		}
	}()

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf(`Started streaming observation %s:
  Type: %s
  State: %s
  SSE Event Types:
    - "observation": Observation events (JSON ObservationEvent)
    - "observation_error": Stream errors with reconnection hints
    - "observation_shutdown": Server shutdown notification
    - "observation_stream_end": Stream completion
  Reconnection: Connect to GET /events with Last-Event-ID header to resume after disconnect.
  Note: Heartbeats are sent every 15 seconds to keep the connection alive.`,
				obs.Name, obs.Type.String(), obs.State.String()),
		}},
	}, nil
}
