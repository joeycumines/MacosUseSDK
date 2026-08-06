// Copyright 2025 Joseph Cumines
//
// Application tool handlers — exact installed-bundle discovery and exact
// running-process lifecycle operations.

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleOpenApp opens one exact installed bundle or activates one exact running
// process. The resource must come from list_apps; this adapter never guesses
// from a display name, bundle ID, path, or PID.
func (s *MCPServer) handleOpenApp(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		App          string `json:"app"`
		Mode         string `json:"mode"`
		BringToFront *bool  `json:"bring_to_front"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	params.App = strings.TrimSpace(params.App)
	if params.App == "" {
		return errorResult("app parameter is required"), nil
	}
	if errResult := validateInputLen(params.App, maxPathLen, "app"); errResult != nil {
		return errResult, nil
	}

	bringToFront := true
	if params.BringToFront != nil {
		bringToFront = *params.BringToFront
	}

	switch {
	case isExactResourceName(params.App, "applicationBundles"):
		mode := pb.ApplicationOpenMode_APPLICATION_OPEN_MODE_LAUNCH_OR_ACTIVATE
		modeLabel := "launch_or_activate"
		switch params.Mode {
		case "", "launch_or_activate":
		case "force_new_instance":
			mode = pb.ApplicationOpenMode_APPLICATION_OPEN_MODE_FORCE_NEW_INSTANCE
			modeLabel = params.Mode
		default:
			return errorResultf("Unknown mode: %s. Valid: launch_or_activate, force_new_instance", params.Mode), nil
		}

		resp, err := s.client.OpenApplication(ctx, &pb.OpenApplicationRequest{
			Name:       params.App,
			Background: !bringToFront,
			Mode:       mode,
		})
		if err != nil {
			return grpcErrorResult(err, "open_app"), nil
		}
		if resp == nil || resp.Application == nil {
			return errorResult("open_app returned no application result"), nil
		}
		if !completeApplication(resp.Application) || resp.Application.ApplicationBundle != params.App {
			return errorResult("open_app returned an incomplete or mismatched application result"), nil
		}

		disposition := ""
		switch resp.Disposition {
		case pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_LAUNCHED_NEW:
			disposition = "launched new"
		case pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_ACTIVATED_EXISTING:
			disposition = "activated existing"
		case pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_ALREADY_ACTIVE:
			disposition = "already active"
		case pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_REUSED_EXISTING:
			disposition = "reused existing"
		default:
			return errorResultf("open_app returned invalid disposition %q", resp.Disposition.String()), nil
		}

		return textResultf(
			"Application open observed: %s (%s, PID: %d)\n  Bundle: %s\n  Mode: %s\n  Disposition: %s",
			applicationDisplayName(resp.Application),
			resp.Application.Name,
			resp.Application.Pid,
			resp.Application.ApplicationBundle,
			modeLabel,
			disposition,
		), nil

	case isExactResourceName(params.App, "applications"):
		if params.Mode != "" {
			return errorResult("mode applies only to applicationBundles/* resources"), nil
		}
		if !bringToFront {
			return errorResult("an exact running application can only be activated with bring_to_front=true"), nil
		}

		resp, err := s.client.ActivateApplication(ctx, &pb.ActivateApplicationRequest{Name: params.App})
		if err != nil {
			return grpcErrorResult(err, "open_app"), nil
		}
		if resp == nil || resp.Application == nil {
			return errorResult("open_app returned no application result"), nil
		}
		if !completeApplication(resp.Application) || resp.Application.Name != params.App {
			return errorResult("open_app returned an incomplete or mismatched application result"), nil
		}

		disposition := ""
		switch resp.Disposition {
		case pb.ApplicationActivationDisposition_APPLICATION_ACTIVATION_DISPOSITION_ACTIVATED:
			disposition = "activated"
		case pb.ApplicationActivationDisposition_APPLICATION_ACTIVATION_DISPOSITION_ALREADY_ACTIVE:
			disposition = "already active"
		default:
			return errorResultf("open_app returned invalid activation disposition %q", resp.Disposition.String()), nil
		}

		return textResultf(
			"Application activation observed: %s (%s, PID: %d)\n  Disposition: %s",
			applicationDisplayName(resp.Application),
			resp.Application.Name,
			resp.Application.Pid,
			disposition,
		), nil

	default:
		return errorResult("app must be an exact applicationBundles/* or applications/* resource returned by list_apps"), nil
	}
}

// handleListApps browses one unambiguous resource collection per call.
func (s *MCPServer) handleListApps(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Kind      string `json:"kind"`
		PageSize  int32  `json:"page_size"`
		PageToken string `json:"page_token"`
		Filter    string `json:"filter"`
		OrderBy   string `json:"order_by"`
		Full      bool   `json:"full"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.PageSize < 0 {
		return errorResult("page_size must not be negative"), nil
	}
	for field, value := range map[string]string{
		"page_token": params.PageToken,
		"filter":     params.Filter,
		"order_by":   params.OrderBy,
	} {
		if errResult := validateInputLen(value, maxPathLen, field); errResult != nil {
			return errResult, nil
		}
	}

	view := pb.ApplicationView_APPLICATION_VIEW_BASIC
	if params.Full {
		view = pb.ApplicationView_APPLICATION_VIEW_FULL
	}

	switch params.Kind {
	case "", "installed":
		resp, err := s.client.ListApplicationBundles(ctx, &pb.ListApplicationBundlesRequest{
			PageSize:  params.PageSize,
			PageToken: params.PageToken,
			Filter:    params.Filter,
			OrderBy:   params.OrderBy,
			View:      view,
		})
		if err != nil {
			return grpcErrorResult(err, "list_apps"), nil
		}
		if resp == nil {
			return errorResult("list_apps returned no installed application result"), nil
		}
		if len(resp.ApplicationBundles) == 0 {
			return textResult("No installed application bundles matched"), nil
		}

		lines := make([]string, 0, len(resp.ApplicationBundles)+1)
		for _, bundle := range resp.ApplicationBundles {
			if bundle == nil || !isExactResourceName(bundle.Name, "applicationBundles") {
				return errorResult("list_apps returned an incomplete application bundle"), nil
			}
			displayName := bundle.DisplayName
			if displayName == "" {
				displayName = bundle.Name
			}
			line := fmt.Sprintf("- %s (%s", displayName, bundle.Name)
			if bundle.BundleId != "" {
				line += fmt.Sprintf(", bundle ID: %s", bundle.BundleId)
			}
			line += ")"
			if bundle.BundleUrl != "" {
				line += fmt.Sprintf(" — %s", bundle.BundleUrl)
			}
			lines = append(lines, line)
		}
		if resp.NextPageToken != "" {
			lines = append(lines, "Next page token: "+resp.NextPageToken)
		}
		return textResultf("Installed application bundles (%d):\n%s", len(resp.ApplicationBundles), strings.Join(lines, "\n")), nil

	case "running":
		resp, err := s.client.ListApplications(ctx, &pb.ListApplicationsRequest{
			PageSize:  params.PageSize,
			PageToken: params.PageToken,
			Filter:    params.Filter,
			OrderBy:   params.OrderBy,
			View:      view,
		})
		if err != nil {
			return grpcErrorResult(err, "list_apps"), nil
		}
		if resp == nil {
			return errorResult("list_apps returned no running application result"), nil
		}
		if len(resp.Applications) == 0 {
			return textResult("No running applications matched"), nil
		}

		lines := make([]string, 0, len(resp.Applications)+1)
		for _, app := range resp.Applications {
			if !completeApplication(app) {
				return errorResult("list_apps returned an incomplete running application"), nil
			}
			winResp, err := s.client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: app.Name, PageSize: 50})
			windowInfo := ""
			if err == nil && len(winResp.GetWindows()) > 0 {
				windowInfo = fmt.Sprintf(" — %d window(s)", len(winResp.Windows))
			} else if err == nil {
				windowInfo = " — 0 windows"
			}
			lines = append(lines, fmt.Sprintf(
				"- %s (%s, PID: %d, active: %t)%s",
				applicationDisplayName(app), app.Name, app.Pid, app.Active, windowInfo,
			))
		}
		if resp.NextPageToken != "" {
			lines = append(lines, "Next page token: "+resp.NextPageToken)
		}
		return textResultf("Running applications (%d):\n%s", len(resp.Applications), strings.Join(lines, "\n")), nil

	default:
		return errorResult("kind must be installed or running"), nil
	}
}

// handleCloseApp closes one exact running application resource. The backend
// owns identity revalidation, termination, convergence, and state cleanup.
func (s *MCPServer) handleCloseApp(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		App   string `json:"app"`
		Force bool   `json:"force"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	params.App = strings.TrimSpace(params.App)
	if params.App == "" {
		return errorResult("app parameter is required"), nil
	}
	if errResult := validateInputLen(params.App, maxPathLen, "app"); errResult != nil {
		return errResult, nil
	}
	if !isExactResourceName(params.App, "applications") {
		return errorResult("app must be an exact applications/* resource returned by list_apps or open_app"), nil
	}

	resp, err := s.client.CloseApplication(ctx, &pb.CloseApplicationRequest{Name: params.App, Force: params.Force})
	if err != nil {
		return grpcErrorResult(err, "close_app"), nil
	}
	if resp == nil || resp.Application == nil {
		return errorResult("close_app returned no application result"), nil
	}
	if !completeApplication(resp.Application) || resp.Application.Name != params.App {
		return errorResult("close_app returned an incomplete or mismatched application result"), nil
	}

	disposition := ""
	switch resp.Disposition {
	case pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_ALREADY_EXITED:
		disposition = "already exited"
	case pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_GRACEFUL:
		disposition = "graceful"
	case pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_FORCED:
		disposition = "forced"
	default:
		return errorResultf("close_app returned invalid disposition %q", resp.Disposition.String()), nil
	}

	return textResultf(
		"Application close observed: %s (%s, PID: %d)\n  Disposition: %s",
		applicationDisplayName(resp.Application),
		resp.Application.Name,
		resp.Application.Pid,
		disposition,
	), nil
}

func isExactResourceName(name, collection string) bool {
	prefix := collection + "/"
	return strings.HasPrefix(name, prefix) && len(name) > len(prefix) && !strings.Contains(name[len(prefix):], "/")
}

func completeApplication(application *pb.Application) bool {
	return application != nil && isExactResourceName(application.Name, "applications") && application.Pid > 0
}

func applicationDisplayName(application *pb.Application) string {
	if application.DisplayName != "" {
		return application.DisplayName
	}
	return application.Name
}
