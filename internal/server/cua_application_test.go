// Copyright 2025 Joseph Cumines

package server

import (
	"context"
	"encoding/json"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	testBundleName      = "applicationBundles/bundle-calculator"
	testApplicationName = "applications/process-calculator-42"
)

func TestHandleOpenAppOpensExactBundleForEveryMode(t *testing.T) {
	tests := []struct {
		name            string
		arguments       string
		wantMode        pb.ApplicationOpenMode
		wantBackground  bool
		disposition     pb.ApplicationOpenDisposition
		wantDisposition string
	}{
		{
			name:            "default launch or activate",
			arguments:       `{"app":"applicationBundles/bundle-calculator"}`,
			wantMode:        pb.ApplicationOpenMode_APPLICATION_OPEN_MODE_LAUNCH_OR_ACTIVATE,
			disposition:     pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_LAUNCHED_NEW,
			wantDisposition: "launched new",
		},
		{
			name:            "launch or activate in background",
			arguments:       `{"app":"applicationBundles/bundle-calculator","mode":"launch_or_activate","bring_to_front":false}`,
			wantMode:        pb.ApplicationOpenMode_APPLICATION_OPEN_MODE_LAUNCH_OR_ACTIVATE,
			wantBackground:  true,
			disposition:     pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_REUSED_EXISTING,
			wantDisposition: "reused existing",
		},
		{
			name:            "force new instance",
			arguments:       `{"app":"applicationBundles/bundle-calculator","mode":"force_new_instance"}`,
			wantMode:        pb.ApplicationOpenMode_APPLICATION_OPEN_MODE_FORCE_NEW_INSTANCE,
			disposition:     pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_LAUNCHED_NEW,
			wantDisposition: "launched new",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			calls := 0
			var request *pb.OpenApplicationRequest
			server := newTestServer()
			server.client = &mockExactMacClient{
				openApplicationFunc: func(_ context.Context, got *pb.OpenApplicationRequest) (*pb.OpenApplicationResponse, error) {
					calls++
					request = got
					return &pb.OpenApplicationResponse{
						Application: &pb.Application{
							Name:              testApplicationName,
							Pid:               42,
							DisplayName:       "Calculator",
							ApplicationBundle: testBundleName,
						},
						Disposition: test.disposition,
					}, nil
				},
			}

			result, err := server.handleOpenApp(&ToolCall{Name: "open_app", Arguments: json.RawMessage(test.arguments)})
			if err != nil {
				t.Fatalf("handleOpenApp() error = %v", err)
			}
			if resultIsError(result) {
				t.Fatalf("handleOpenApp() result = %q, want success", resultText(result))
			}
			if calls != 1 || request == nil {
				t.Fatalf("OpenApplication calls = %d request=%v, want exactly one", calls, request)
			}
			if request.Name != testBundleName || request.Mode != test.wantMode || request.Background != test.wantBackground {
				t.Fatalf("OpenApplication request = %+v", request)
			}
			if !resultContains(result, "Bundle: "+testBundleName) || !resultContains(result, "Disposition: "+test.wantDisposition) {
				t.Fatalf("handleOpenApp() result = %q", resultText(result))
			}
		})
	}
}

func TestHandleOpenAppActivatesExactRunningApplication(t *testing.T) {
	tests := []struct {
		name            string
		disposition     pb.ApplicationActivationDisposition
		wantDisposition string
	}{
		{"activated", pb.ApplicationActivationDisposition_APPLICATION_ACTIVATION_DISPOSITION_ACTIVATED, "activated"},
		{"already active", pb.ApplicationActivationDisposition_APPLICATION_ACTIVATION_DISPOSITION_ALREADY_ACTIVE, "already active"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var request *pb.ActivateApplicationRequest
			server := newTestServer()
			server.client = &mockExactMacClient{
				activateApplicationFunc: func(_ context.Context, got *pb.ActivateApplicationRequest) (*pb.ActivateApplicationResponse, error) {
					request = got
					return &pb.ActivateApplicationResponse{
						Application: &pb.Application{Name: testApplicationName, Pid: 42, DisplayName: "Calculator"},
						Disposition: test.disposition,
					}, nil
				},
			}
			result, err := server.handleOpenApp(&ToolCall{
				Name: "open_app", Arguments: json.RawMessage(`{"app":"applications/process-calculator-42"}`),
			})
			if err != nil || resultIsError(result) {
				t.Fatalf("handleOpenApp() error=%v result=%q", err, resultText(result))
			}
			if request == nil || request.Name != testApplicationName {
				t.Fatalf("ActivateApplication request = %+v", request)
			}
			if !resultContains(result, "Application activation observed") || !resultContains(result, "Disposition: "+test.wantDisposition) {
				t.Fatalf("handleOpenApp() result = %q", resultText(result))
			}
		})
	}
}

func TestHandleOpenAppRejectsGuessingAndContradictoryRunningOptions(t *testing.T) {
	tests := []struct {
		name      string
		arguments string
		want      string
	}{
		{"display name", `{"app":"Calculator"}`, "exact applicationBundles/* or applications/*"},
		{"bundle ID", `{"app":"com.apple.calculator"}`, "exact applicationBundles/* or applications/*"},
		{"path", `{"app":"/System/Applications/Calculator.app"}`, "exact applicationBundles/* or applications/*"},
		{"nested fake bundle", `{"app":"applicationBundles/a/extra"}`, "exact applicationBundles/* or applications/*"},
		{"removed activate-only mode", `{"app":"applicationBundles/bundle-calculator","mode":"activate_only"}`, "Unknown mode"},
		{"mode on process", `{"app":"applications/process-calculator-42","mode":"force_new_instance"}`, "mode applies only"},
		{"background process", `{"app":"applications/process-calculator-42","bring_to_front":false}`, "bring_to_front=true"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := newTestServer()
			server.client = &mockExactMacClient{}
			result, err := server.handleOpenApp(&ToolCall{Name: "open_app", Arguments: json.RawMessage(test.arguments)})
			if err != nil {
				t.Fatalf("handleOpenApp() error = %v", err)
			}
			if !resultIsError(result) || !resultContains(result, test.want) {
				t.Fatalf("handleOpenApp() result = %q, want %q", resultText(result), test.want)
			}
		})
	}
}

func TestHandleOpenAppRejectsMismatchedBackendIdentity(t *testing.T) {
	server := newTestServer()
	server.client = &mockExactMacClient{
		openApplicationFunc: func(context.Context, *pb.OpenApplicationRequest) (*pb.OpenApplicationResponse, error) {
			return &pb.OpenApplicationResponse{
				Application: &pb.Application{
					Name:              testApplicationName,
					Pid:               42,
					ApplicationBundle: "applicationBundles/different",
				},
				Disposition: pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_LAUNCHED_NEW,
			}, nil
		},
	}
	result, err := server.handleOpenApp(&ToolCall{
		Name: "open_app", Arguments: json.RawMessage(`{"app":"applicationBundles/bundle-calculator"}`),
	})
	if err != nil || !resultIsError(result) || !resultContains(result, "mismatched") {
		t.Fatalf("handleOpenApp() error=%v result=%q", err, resultText(result))
	}
}

func TestHandleOpenAppReturnsBackendFailure(t *testing.T) {
	server := newTestServer()
	server.client = &mockExactMacClient{
		activateApplicationFunc: func(context.Context, *pb.ActivateApplicationRequest) (*pb.ActivateApplicationResponse, error) {
			return nil, status.Error(codes.NotFound, "application instance is stale")
		},
	}
	result, err := server.handleOpenApp(&ToolCall{
		Name: "open_app", Arguments: json.RawMessage(`{"app":"applications/process-calculator-42"}`),
	})
	if err != nil || !resultIsError(result) || !resultContains(result, "NotFound") || !resultContains(result, "stale") {
		t.Fatalf("handleOpenApp() error=%v result=%q", err, resultText(result))
	}
}

func TestHandleListAppsInstalledForwardsExactQuery(t *testing.T) {
	var request *pb.ListApplicationBundlesRequest
	server := newTestServer()
	server.client = &mockExactMacClient{
		listApplicationBundlesFunc: func(_ context.Context, got *pb.ListApplicationBundlesRequest) (*pb.ListApplicationBundlesResponse, error) {
			request = got
			return &pb.ListApplicationBundlesResponse{
				ApplicationBundles: []*pb.ApplicationBundle{{
					Name: "applicationBundles/a", DisplayName: "Calculator", BundleId: "com.apple.calculator",
					BundleUrl: "file:///System/Applications/Calculator.app",
				}},
				NextPageToken: "opaque-next",
			}, nil
		},
	}
	result, err := server.handleListApps(&ToolCall{
		Name:      "list_apps",
		Arguments: json.RawMessage(`{"kind":"installed","page_size":7,"page_token":"opaque","filter":"bundle_id = \"com.apple.calculator\"","order_by":"display_name desc","full":true}`),
	})
	if err != nil || resultIsError(result) {
		t.Fatalf("handleListApps() error=%v result=%q", err, resultText(result))
	}
	if request == nil || request.PageSize != 7 || request.PageToken != "opaque" || request.OrderBy != "display_name desc" || request.View != pb.ApplicationView_APPLICATION_VIEW_FULL {
		t.Fatalf("ListApplicationBundles request = %+v", request)
	}
	if !resultContains(result, "applicationBundles/a") || !resultContains(result, "Next page token: opaque-next") {
		t.Fatalf("handleListApps() result = %q", resultText(result))
	}
}

func TestHandleListAppsRunningForwardsExactQueryAndEnrichesWindows(t *testing.T) {
	var request *pb.ListApplicationsRequest
	server := newTestServer()
	server.client = &mockExactMacClient{
		listApplicationsFunc: func(_ context.Context, got *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error) {
			request = got
			return &pb.ListApplicationsResponse{Applications: []*pb.Application{{
				Name: testApplicationName, Pid: 42, DisplayName: "Calculator", Active: true,
			}}}, nil
		},
		listWindowsFunc: func(_ context.Context, got *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			if got.Parent != testApplicationName {
				t.Fatalf("ListWindows parent = %q", got.Parent)
			}
			return &pb.ListWindowsResponse{Windows: []*pb.Window{{Title: "Calculator", Visible: true, Layer: 0}}}, nil
		},
	}
	result, err := server.handleListApps(&ToolCall{
		Name: "list_apps", Arguments: json.RawMessage(`{"kind":"running","page_size":2,"full":false}`),
	})
	if err != nil || resultIsError(result) {
		t.Fatalf("handleListApps() error=%v result=%q", err, resultText(result))
	}
	if request == nil || request.PageSize != 2 || request.View != pb.ApplicationView_APPLICATION_VIEW_BASIC {
		t.Fatalf("ListApplications request = %+v", request)
	}
	if !resultContains(result, "active: true") || !resultContains(result, "1 window(s)") {
		t.Fatalf("handleListApps() result = %q", resultText(result))
	}
}

func TestHandleListAppsRejectsInvalidLocalParametersBeforeRPC(t *testing.T) {
	for _, arguments := range []string{`{"kind":"other"}`, `{"page_size":-1}`} {
		server := newTestServer()
		server.client = &mockExactMacClient{}
		result, err := server.handleListApps(&ToolCall{Name: "list_apps", Arguments: json.RawMessage(arguments)})
		if err != nil || !resultIsError(result) {
			t.Fatalf("handleListApps(%s) error=%v result=%q", arguments, err, resultText(result))
		}
	}
}

func TestHandleCloseAppCallsOnlyExactCloseApplication(t *testing.T) {
	var request *pb.CloseApplicationRequest
	server := newTestServer()
	server.client = &mockExactMacClient{
		closeApplicationFunc: func(_ context.Context, got *pb.CloseApplicationRequest) (*pb.CloseApplicationResponse, error) {
			request = got
			return &pb.CloseApplicationResponse{
				Application: &pb.Application{Name: testApplicationName, Pid: 42, DisplayName: "Calculator"},
				Disposition: pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_FORCED,
			}, nil
		},
	}
	result, err := server.handleCloseApp(&ToolCall{
		Name: "close_app", Arguments: json.RawMessage(`{"app":"applications/process-calculator-42","force":true}`),
	})
	if err != nil || resultIsError(result) {
		t.Fatalf("handleCloseApp() error=%v result=%q", err, resultText(result))
	}
	if request == nil || request.Name != testApplicationName || !request.Force {
		t.Fatalf("CloseApplication request = %+v", request)
	}
	if !resultContains(result, "Disposition: forced") {
		t.Fatalf("handleCloseApp() result = %q", resultText(result))
	}
}

func TestHandleCloseAppRejectsGuessesBeforeRPC(t *testing.T) {
	for _, app := range []string{"Calculator", "com.apple.calculator", testBundleName, "applications/a/extra"} {
		server := newTestServer()
		server.client = &mockExactMacClient{}
		arguments, err := json.Marshal(map[string]any{"app": app})
		if err != nil {
			t.Fatal(err)
		}
		result, err := server.handleCloseApp(&ToolCall{Name: "close_app", Arguments: arguments})
		if err != nil || !resultIsError(result) || !resultContains(result, "exact applications/*") {
			t.Fatalf("handleCloseApp(%q) error=%v result=%q", app, err, resultText(result))
		}
	}
}

func TestHandleCloseAppRejectsMismatchedBackendIdentity(t *testing.T) {
	server := newTestServer()
	server.client = &mockExactMacClient{
		closeApplicationFunc: func(context.Context, *pb.CloseApplicationRequest) (*pb.CloseApplicationResponse, error) {
			return &pb.CloseApplicationResponse{
				Application: &pb.Application{Name: "applications/different", Pid: 42},
				Disposition: pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_ALREADY_EXITED,
			}, nil
		},
	}
	result, err := server.handleCloseApp(&ToolCall{
		Name: "close_app", Arguments: json.RawMessage(`{"app":"applications/process-calculator-42"}`),
	})
	if err != nil || !resultIsError(result) || !resultContains(result, "mismatched") {
		t.Fatalf("handleCloseApp() error=%v result=%q", err, resultText(result))
	}
}

func TestHandleCloseAppReturnsBackendFailure(t *testing.T) {
	server := newTestServer()
	server.client = &mockExactMacClient{
		closeApplicationFunc: func(context.Context, *pb.CloseApplicationRequest) (*pb.CloseApplicationResponse, error) {
			return nil, status.Error(codes.FailedPrecondition, "ownership is not proven")
		},
	}
	result, err := server.handleCloseApp(&ToolCall{
		Name: "close_app", Arguments: json.RawMessage(`{"app":"applications/process-calculator-42"}`),
	})
	if err != nil || !resultIsError(result) || !resultContains(result, "FailedPrecondition") {
		t.Fatalf("handleCloseApp() error=%v result=%q", err, resultText(result))
	}
}
