// Copyright 2025 Joseph Cumines
//
// Application tool handlers — open_app, list_apps, close_app
//
// Enhanced with "Open Application Confusion Mitigation" — research-backed
// mitigations for the #1 source of AI model errors when using desktop automation.
// See scratch/mcp-redesign.md "Addendum: Open Application Confusion Mitigation".

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/server/tools"
	"google.golang.org/protobuf/types/known/durationpb"
)

// handleOpenApp handles the open_app tool with explicit mode control.
// Mode behaviors:
//   - launch_or_activate (default): Launch new or activate existing
//   - force_new_instance: Always launch a new process
//   - activate_only: Error if not running, otherwise activate
func (s *MCPServer) handleOpenApp(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		ID           string `json:"id"`
		Mode         string `json:"mode"`
		BringToFront *bool  `json:"bring_to_front"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.ID == "" {
		return errorResult("id parameter is required"), nil
	}

	if errResult := validateInputLen(params.ID, maxPathLen, "id"); errResult != nil {
		return errResult, nil
	}

	// Default mode
	if params.Mode == "" {
		params.Mode = "launch_or_activate"
	}

	// Default bring_to_front: true when not explicitly set
	bringToFront := true
	if params.BringToFront != nil {
		bringToFront = *params.BringToFront
	}

	switch params.Mode {
	case "launch_or_activate":
		return s.openAppLaunchOrActivate(ctx, params.ID, bringToFront)
	case "force_new_instance":
		return s.openAppForceNewInstance(ctx, params.ID, bringToFront)
	case "activate_only":
		return s.openAppActivateOnly(ctx, params.ID, bringToFront)
	default:
		return errorResultf("Unknown mode: %s. Valid: launch_or_activate, force_new_instance, activate_only", params.Mode), nil
	}
}

// getExistingPIDs returns PIDs of running apps matching the given identifier.
// Used to infer whether OpenApplication launched a new process or activated an existing one.
func (s *MCPServer) getExistingPIDs(ctx context.Context, id string) []int32 {
	if s.client == nil {
		return nil
	}
	resp, err := s.client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		return nil
	}
	var pids []int32
	for _, app := range resp.Applications {
		if strings.EqualFold(app.DisplayName, id) ||
			strings.EqualFold(app.Name, id) {
			pids = append(pids, app.Pid)
		}
	}
	return pids
}

// pollForWindows polls ListWindows until windows appear or timeout.
// AX windows populate asynchronously after launch (macOS26/Agent insight).
func (s *MCPServer) pollForWindows(ctx context.Context, appName string) []*pb.Window {
	for range 10 {
		winResp, err := s.client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent:   appName,
			PageSize: 20,
		})
		if err == nil && len(winResp.Windows) > 0 {
			return winResp.Windows
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(200 * time.Millisecond):
		}
	}
	return nil
}

// detectBareBinary checks if a process is a bare binary (no bundle identity).
// Uses AppleScript/System Events to look up the bundle identifier by PID.
// Processes without a bundle identifier (e.g. command-line tools) are flagged as bare.
func (s *MCPServer) detectBareBinary(ctx context.Context, pid int32) (bool, string) {
	script := fmt.Sprintf(`tell application "System Events" to return bundle identifier of first application process whose unix id is %d`, pid)
	shellResp, err := s.client.ExecuteShellCommand(ctx, &pb.ExecuteShellCommandRequest{
		Command: "/usr/bin/osascript",
		Args:    []string{"-e", script},
		Timeout: durationpb.New(5 * time.Second),
	})
	// Safe: %d only accepts integers, preventing shell injection via pid
	if err != nil || shellResp.ExitCode != 0 {
		// Can't determine — assume not bare binary
		return false, ""
	}
	bundleID := strings.TrimSpace(shellResp.Stdout)
	if bundleID == "" || bundleID == "-" || strings.EqualFold(bundleID, "missing value") {
		return true, "\n  WARNING: This app is a bare binary process (no bundle identity).\n    - It may not appear in the Dock\n    - Its windows may not respond to standard activation\n    - Use find_elements to discover interactive elements"
	}
	return false, ""
}

// formatEnrichedAppResponse formats the enriched open_app response with window info,
// action taken, bare binary detection, and readiness status.
func formatEnrichedAppResponse(displayName string, actionTaken string, newProcessCreated bool, app *pb.Application, windows []*pb.Window, bareBinaryWarning string) string {
	var b strings.Builder

	fmt.Fprintf(&b, "App opened: %s", displayName)
	fmt.Fprintf(&b, "\n  Status: %s", actionTaken)
	if newProcessCreated {
		b.WriteString(" (new process created)")
	}
	fmt.Fprintf(&b, "\n  PID: %d", app.Pid)
	fmt.Fprintf(&b, "\n  Resource: %s", app.Name)

	if bareBinaryWarning != "" {
		b.WriteString(bareBinaryWarning)
	}

	if len(windows) > 0 {
		fmt.Fprintf(&b, "\n  Windows (%d):", len(windows))
		for i, win := range windows {
			focused := ""
			// Heuristic: first visible window with lowest z_index is likely focused
			if i == 0 && win.Visible {
				focused = " [focused]"
			}
			bounds := win.GetBounds()
			if bounds != nil {
				fmt.Fprintf(&b, "\n    %d. %q (%s)%s @ (%.0f,%.0f,%.0f,%.0f)",
					i+1, win.Title, win.Name, focused,
					bounds.GetX(), bounds.GetY(), bounds.GetWidth(), bounds.GetHeight())
			} else {
				fmt.Fprintf(&b, "\n    %d. %q (%s)%s",
					i+1, win.Title, win.Name, focused)
			}
		}
		if bareBinaryWarning != "" {
			b.WriteString("\n  Ready for interaction: unknown (bare binary)")
		} else {
			b.WriteString("\n  Ready for interaction: yes")
		}
	} else {
		if bareBinaryWarning != "" {
			b.WriteString("\n  Windows (0): none yet (may take longer for bare binary processes)")
			b.WriteString("\n  Ready for interaction: unknown (bare binary)")
		} else {
			b.WriteString("\n  Windows: none found (may take longer to initialize)")
			b.WriteString("\n  Ready for interaction: waiting for windows...")
		}
	}

	return b.String()
}

// openAppLaunchOrActivate implements launch_or_activate mode.
// Enhanced with action-taken inference, window enrichment, and bare binary detection.
func (s *MCPServer) openAppLaunchOrActivate(ctx context.Context, id string, bringToFront bool) (*ToolResult, error) {
	// Enhancement 1: Record existing PIDs before calling OpenApplication
	// to infer whether a new process was launched or an existing one was activated.
	existingPIDs := s.getExistingPIDs(ctx, id)

	op, err := s.client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Id:         id,
		Background: !bringToFront,
	})
	if err != nil {
		return errorResultf("Failed to open application: %v", err), nil
	}

	resp, err := s.pollOpenAppOperation(ctx, op)
	if err != nil {
		return errorResultf("Failed waiting for application: %v", err), nil
	}

	app := resp.GetApplication()
	if app == nil {
		return textResultf("Application opened: %s", id), nil
	}

	// Enhancement 1: Determine what actually happened by comparing PIDs
	actionTaken := "launched_new"
	newProcessCreated := true
	if slices.Contains(existingPIDs, app.Pid) {
		actionTaken = "activated_existing"
		newProcessCreated = false
	}

	// Enhancement 2: Poll for windows after open (AX windows populate asynchronously)
	windows := s.pollForWindows(ctx, app.Name)

	// Enhancement 3: Detect bare binary process
	isBareBinary, bareBinaryWarning := s.detectBareBinary(ctx, app.Pid)
	_ = isBareBinary // used implicitly via bareBinaryWarning

	return textResult(formatEnrichedAppResponse(app.DisplayName, actionTaken, newProcessCreated, app, windows, bareBinaryWarning)), nil
}

// openAppForceNewInstance implements force_new_instance mode using shell command.
// Enhanced with window enrichment and bare binary detection.
func (s *MCPServer) openAppForceNewInstance(ctx context.Context, id string, bringToFront bool) (*ToolResult, error) {
	// Use shell command `open -n -a "AppName"` to force a new instance
	shellResp, err := s.client.ExecuteShellCommand(ctx, &pb.ExecuteShellCommandRequest{
		Command: "open",
		Args:    []string{"-n", "-a", id},
		Timeout: nil,
	})
	if err != nil {
		return errorResultf("Failed to force new instance: %v", err), nil
	}

	if shellResp.ExitCode != 0 {
		return errorResultf("Failed to force new instance: %s", shellResp.Stderr), nil
	}

	// Give macOS a moment to register the new process before tracking.
	// The `open -n -a` command returns before the app is fully launched,
	// and OpenApplication may fail to find the PID if called too soon.
	for range 3 {
		select {
		case <-ctx.Done():
			return textResultf("Application launched (new instance): %s\n  Action: force_new_instance", id), nil
		case <-time.After(200 * time.Millisecond):
		}
	}

	// Now track the application via OpenApplication
	op, err := s.client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Id:         id,
		Background: !bringToFront,
	})
	if err != nil {
		// The app was launched but tracking failed — still report success
		return textResultf("Application launched (new instance): %s\n  Action: force_new_instance\n  Warning: tracking may be incomplete", id), nil
	}

	resp, err := s.pollOpenAppOperation(ctx, op)
	if err != nil {
		return textResultf("Application launched (new instance): %s\n  Action: force_new_instance", id), nil
	}

	app := resp.GetApplication()
	if app == nil {
		return textResultf("Application launched (new instance): %s\n  Action: force_new_instance", id), nil
	}

	// Enhancement 2: Poll for windows after open
	windows := s.pollForWindows(ctx, app.Name)

	// Enhancement 3: Detect bare binary process
	_, bareBinaryWarning := s.detectBareBinary(ctx, app.Pid)

	return textResult(formatEnrichedAppResponse(app.DisplayName, "force_new_instance", true, app, windows, bareBinaryWarning)), nil
}

// openAppActivateOnly implements activate_only mode.
// Enhanced with window enrichment.
func (s *MCPServer) openAppActivateOnly(ctx context.Context, id string, bringToFront bool) (*ToolResult, error) {
	// Check if the app is already running by listing applications
	listResp, err := s.client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		return errorResultf("Failed to check running applications: %v", err), nil
	}

	// Look for the app by name or bundle ID
	var foundApp *pb.Application
	for _, app := range listResp.Applications {
		if strings.EqualFold(app.DisplayName, id) ||
			strings.EqualFold(app.Name, id) {
			foundApp = app
			break
		}
	}

	if foundApp == nil {
		return errorResultf("Application %s is not running. activate_only mode requires the app to already be running. Use mode='launch_or_activate' to launch it.", id), nil
	}

	// Activate the existing application
	if bringToFront {
		// Use OpenApplication with background=false to activate
		op, err := s.client.OpenApplication(ctx, &pb.OpenApplicationRequest{
			Id:         id,
			Background: false,
		})
		if err != nil {
			return errorResultf("Failed to activate application: %v", err), nil
		}

		resp, err := s.pollOpenAppOperation(ctx, op)
		if err != nil {
			return errorResultf("Failed waiting for activation: %v", err), nil
		}

		app := resp.GetApplication()
		if app != nil {
			// Enhancement 2: Poll for windows after activation
			windows := s.pollForWindows(ctx, app.Name)

			return textResult(formatEnrichedAppResponse(app.DisplayName, "activated_existing", false, app, windows, "")), nil
		}
	}

	// Enhancement 2: Poll for windows even when not bringing to front
	windows := s.pollForWindows(ctx, foundApp.Name)

	return textResult(formatEnrichedAppResponse(foundApp.DisplayName, "already_active", false, foundApp, windows, "")), nil
}

// pollOpenAppOperation polls an OpenApplication LRO until completion.
func (s *MCPServer) pollOpenAppOperation(ctx context.Context, op *longrunningpb.Operation) (*pb.OpenApplicationResponse, error) {
	if !op.Done {
		opsClient := &tools.OperationClient{Client: s.opsClient}
		if err := tools.PollUntilComplete(ctx, opsClient, op.Name, 100*time.Millisecond); err != nil {
			return nil, fmt.Errorf("polling failed: %w", err)
		}

		latestOp, err := s.opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{Name: op.Name})
		if err != nil {
			return nil, fmt.Errorf("get operation failed: %w", err)
		}
		op = latestOp
	}

	if opErr := op.GetError(); opErr != nil {
		return nil, fmt.Errorf("operation error: %s", opErr.Message)
	}

	var response pb.OpenApplicationResponse
	if result := op.GetResponse(); result != nil {
		if err := result.UnmarshalTo(&response); err != nil {
			return nil, fmt.Errorf("unmarshal failed: %w", err)
		}
	}

	return &response, nil
}

// handleListApps handles the list_apps tool — enriched listing of tracked apps
// with per-app window counts and focused window info.
func (s *MCPServer) handleListApps(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	resp, err := s.client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		return grpcErrorResult(err, "list_apps"), nil
	}

	if len(resp.Applications) == 0 {
		return textResult("No applications currently tracked"), nil
	}

	// Enhancement 4: Enrich with per-app window counts and focused window info
	var lines []string
	for _, app := range resp.Applications {
		// Get window count for this app
		winResp, err := s.client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent:   app.Name,
			PageSize: 50,
		})

		windowInfo := ""
		if err == nil && len(winResp.Windows) > 0 {
			// Find frontmost window (lowest z_index, visible)
			var focusedWin *pb.Window
			for _, w := range winResp.Windows {
				if w.Visible && (focusedWin == nil || w.ZIndex < focusedWin.ZIndex) {
					focusedWin = w
				}
			}

			windowInfo = fmt.Sprintf(" — %d window(s)", len(winResp.Windows))
			if focusedWin != nil {
				windowInfo += fmt.Sprintf(": %q [focused]", focusedWin.Title)
			}
		} else if err == nil {
			windowInfo = " — 0 windows"
		}

		lines = append(lines, fmt.Sprintf("- %s (%s, PID: %d)%s", app.DisplayName, app.Name, app.Pid, windowInfo))
	}

	return textResultf("Tracked applications (%d):\n%s", len(resp.Applications), strings.Join(lines, "\n")), nil
}

// quitApplicationAppleScriptArgs returns osascript arguments that use argv to
// receive the application display name. argv avoids interpolating user-supplied
// text into AppleScript source, eliminating quoting/escaping bugs.
func quitApplicationAppleScriptArgs(displayName string) []string {
	return []string{
		"-e", "on run argv",
		"-e", "tell application (item 1 of argv) to quit",
		"-e", "end run",
		"--", displayName,
	}
}

// handleCloseApp handles the close_app tool — actually terminates the application.
// Unlike the old delete_application which only untracked, this quits the process.
// Enhanced with post-close verification.
func (s *MCPServer) handleCloseApp(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		App   string `json:"app"`
		Force bool   `json:"force"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.App == "" {
		return errorResult("app parameter is required"), nil
	}

	if errResult := validateInputLen(params.App, maxPathLen, "app"); errResult != nil {
		return errResult, nil
	}

	// Resolve the app resource name — could be "applications/1234" or a bundle ID
	appName := params.App

	// If it's not already a resource name, try to find it
	if !strings.HasPrefix(appName, "applications/") {
		listResp, err := s.client.ListApplications(ctx, &pb.ListApplicationsRequest{})
		if err != nil {
			return grpcErrorResult(err, "close_app"), nil
		}

		for _, app := range listResp.Applications {
			if strings.EqualFold(app.DisplayName, appName) ||
				strings.EqualFold(app.Name, appName) {
				appName = app.Name
				break
			}
		}

		if !strings.HasPrefix(appName, "applications/") {
			return errorResultf("Application %s not found in tracked applications. Call open_app first to register it.", params.App), nil
		}
	}

	// Get the application details to find PID and display name
	appResp, err := s.client.GetApplication(ctx, &pb.GetApplicationRequest{Name: appName})
	if err != nil {
		return grpcErrorResult(err, "close_app"), nil
	}

	pid := appResp.Pid
	displayName := appResp.DisplayName

	// Terminate the process
	if params.Force {
		// Force quit via kill
		_, shellErr := s.client.ExecuteShellCommand(ctx, &pb.ExecuteShellCommandRequest{
			Command: "kill",
			Args:    []string{"-9", fmt.Sprintf("%d", pid)},
			Timeout: nil,
		})
		if shellErr != nil {
			return errorResultf("Failed to force quit %s (PID %d): %v", displayName, pid, shellErr), nil
		}
	} else {
		// Graceful quit via osascript, passing displayName as argv instead of
		// interpolating it into the script. This avoids AppleScript string escaping
		// bugs for names with quotes, backslashes, and other special characters.
		_, shellErr := s.client.ExecuteShellCommand(ctx, &pb.ExecuteShellCommandRequest{
			Command: "osascript",
			Args:    quitApplicationAppleScriptArgs(displayName),
			Timeout: nil,
		})
		if shellErr != nil {
			// Fall back to SIGTERM
			_, shellErr2 := s.client.ExecuteShellCommand(ctx, &pb.ExecuteShellCommandRequest{
				Command: "kill",
				Args:    []string{fmt.Sprintf("%d", pid)},
				Timeout: nil,
			})
			if shellErr2 != nil {
				return errorResultf("Failed to quit %s (PID %d): %v", displayName, pid, shellErr2), nil
			}
		}
	}

	// Untrack the application
	_, delErr := s.client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{Name: appName})
	if delErr != nil {
		// Process was terminated but untracking failed — still report success
		return textResultf("Application %s (PID %d) terminated (untracking failed: %v)", displayName, pid, delErr), nil
	}

	forceWord := ""
	if params.Force {
		forceWord = " (force quit)"
	}

	// Enhancement 5: Verify process is actually gone
	verifyResp, verifyErr := s.client.ExecuteShellCommand(ctx, &pb.ExecuteShellCommandRequest{
		Command: "ps",
		Args:    []string{"-p", fmt.Sprintf("%d", pid)},
		Timeout: nil,
	})
	terminated := verifyErr != nil || verifyResp.ExitCode != 0

	return textResultf("App closed: %s (PID: %d)%s\n  Process terminated: %v",
		displayName, pid, forceWord, terminated), nil
}
