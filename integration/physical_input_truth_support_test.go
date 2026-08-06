// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type ownedTextEditScroll struct {
	path  []int32
	role  string
	value float64
}

func callPhysicalHTTP(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	session string,
	requestID int,
	name string,
	arguments map[string]any,
) productionMCPToolResult {
	t.Helper()
	response := callNonApplicationMatrixHTTP(
		t,
		ctx,
		client,
		baseURL,
		session,
		requestID,
		name,
		arguments,
	)
	if response.Error != nil || string(response.ID) != strconv.Itoa(requestID) {
		t.Fatalf("HTTP %s response=%+v", name, response)
	}
	return decodePhysicalToolResult(t, name, response.Result)
}

func cancelAdmittedPhysicalRequestOnce(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
	done <-chan sessionHTTPResult,
) sessionHTTPResult {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/cancelled",
		"params": map[string]any{
			"requestId": requestID,
			"reason":    "physical truth cancellation",
		},
	})
	if err != nil {
		t.Fatalf("marshal physical cancellation notification: %v", err)
	}
	cancelResult := sendSessionMCP(
		t,
		ctx,
		client,
		baseURL,
		http.MethodPost,
		sessionID,
		string(payload),
	)
	if cancelResult.Err != nil ||
		cancelResult.Status != http.StatusAccepted ||
		len(cancelResult.Body) != 0 {
		t.Fatalf(
			"physical cancellation notification status=%d body=%q error=%v, want 202 empty",
			cancelResult.Status,
			cancelResult.Body,
			cancelResult.Err,
		)
	}
	select {
	case result := <-done:
		if result.Err != nil {
			t.Fatalf("cancelled physical request returned transport error: %v", result.Err)
		}
		return result
	case <-ctx.Done():
		t.Fatalf("admitted physical request did not settle after one cancellation: %v", ctx.Err())
		return sessionHTTPResult{}
	}
}

func callPhysicalStdio(
	t *testing.T,
	ctx context.Context,
	stdin io.Writer,
	stdout *stdioResponsePump,
	requestID int,
	name string,
	arguments map[string]any,
) productionMCPToolResult {
	t.Helper()
	response, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
		"jsonrpc": "2.0",
		"id":      requestID,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      name,
			"arguments": arguments,
		},
	})
	if err != nil || response == nil || response.Error != nil ||
		string(response.ID) != strconv.Itoa(requestID) {
		t.Fatalf("stdio %s response=%+v error=%v", name, response, err)
	}
	return decodePhysicalToolResult(t, name, response.Result)
}

func decodePhysicalToolResult(
	t *testing.T,
	name string,
	raw json.RawMessage,
) productionMCPToolResult {
	t.Helper()
	var result productionMCPToolResult
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatalf("decode %s result: %v raw=%s", name, err, raw)
	}
	if result.IsError || len(result.Content) == 0 || result.Content[0].Text == "" {
		t.Fatalf("%s returned false or empty MCP success: %+v", name, result)
	}
	return result
}

func requireCompletedMCPInput(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	parent string,
	before map[string]*pb.Input,
	target *pb.InputTarget,
	action *pb.InputAction,
	expectedPosts int32,
	result productionMCPToolResult,
) *pb.Input {
	t.Helper()
	after := listInputSnapshot(t, ctx, client, parent)
	input := requireOneNewInput(t, before, after, target, action)
	requireInputTerminalEvidence(
		t,
		input,
		pb.Input_STATE_COMPLETED,
		pb.InputDeliveryResult_COMMITMENT_COMMITTED_AND_SETTLED,
		expectedPosts,
		expectedPosts,
	)
	if !strings.Contains(result.Content[0].Text, input.GetName()) {
		t.Fatalf("MCP result %q omits exact Input %q", result.Content[0].Text, input.GetName())
	}
	requireInputRoundTrip(t, ctx, client, parent, input)
	return input
}

func waitForMCPInputExecution(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	parent string,
	before map[string]*pb.Input,
	target *pb.InputTarget,
	action *pb.InputAction,
) {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := PollUntilContext(waitCtx, 20*time.Millisecond, func() (bool, error) {
		after := listInputSnapshot(t, waitCtx, client, parent)
		if len(after) != len(before)+1 {
			return false, nil
		}
		input := requireOneNewInput(t, before, after, target, action)
		return input.GetState() == pb.Input_STATE_EXECUTING, nil
	}); err != nil {
		t.Fatalf("MCP Input did not enter EXECUTING: %v", err)
	}
}

func requireCancelledMCPInput(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	parent string,
	before map[string]*pb.Input,
	target *pb.InputTarget,
	action *pb.InputAction,
	maximumPosts int32,
) *pb.Input {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	var terminal *pb.Input
	if err := PollUntilContext(waitCtx, 20*time.Millisecond, func() (bool, error) {
		after := listInputSnapshot(t, waitCtx, client, parent)
		if len(after) != len(before)+1 {
			return false, nil
		}
		input := requireOneNewInput(t, before, after, target, action)
		if input.GetState() != pb.Input_STATE_CANCELLED {
			return false, nil
		}
		terminal = input
		return true, nil
	}); err != nil {
		t.Fatalf("MCP Input did not settle CANCELLED: %v", err)
	}
	requireInputTerminalEvidence(
		t,
		terminal,
		pb.Input_STATE_CANCELLED,
		pb.InputDeliveryResult_COMMITMENT_POSSIBLY_COMMITTED,
		1,
		maximumPosts,
	)
	requireInputRoundTrip(t, ctx, client, parent, terminal)
	return terminal
}

func requireOwnedApplicationWindow(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	application *pb.Application,
) *pb.Window {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var window *pb.Window
	var lastCandidates []string
	var lastFocused []string
	if err := PollUntilContext(waitCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.ListWindows(waitCtx, &pb.ListWindowsRequest{
			Parent: application.GetName(),
		})
		if err != nil {
			return false, nil
		}
		var candidates []*pb.Window
		for _, candidate := range response.GetWindows() {
			if candidate != nil && candidate.GetVisible() &&
				candidate.GetBounds() != nil &&
				candidate.GetBounds().GetWidth() > 0 &&
				candidate.GetBounds().GetHeight() > 0 {
				candidates = append(candidates, candidate)
			}
		}
		lastCandidates = lastCandidates[:0]
		lastFocused = lastFocused[:0]
		for _, candidate := range candidates {
			lastCandidates = append(lastCandidates, candidate.GetName())
			state, stateErr := client.GetWindowState(waitCtx, &pb.GetWindowStateRequest{
				Name: candidate.GetName() + "/state",
			})
			if stateErr == nil && state.GetFocused() {
				lastFocused = append(lastFocused, candidate.GetName())
			}
		}
		var selected *pb.Window
		switch {
		case len(lastFocused) == 1:
			for _, candidate := range candidates {
				if candidate.GetName() == lastFocused[0] {
					selected = candidate
					break
				}
			}
		case len(candidates) == 1:
			selected = candidates[0]
		default:
			return false, nil
		}
		focused, focusErr := client.FocusWindow(waitCtx, &pb.FocusWindowRequest{
			Name: selected.GetName(),
		})
		if focusErr != nil || focused.GetName() != selected.GetName() {
			return false, nil
		}
		state, stateErr := client.GetWindowState(waitCtx, &pb.GetWindowStateRequest{
			Name: focused.GetName() + "/state",
		})
		if stateErr != nil || !state.GetFocused() {
			return false, nil
		}
		window = focused
		return true, nil
	}); err != nil {
		t.Fatalf(
			"owned application did not expose one exact focused window candidates=%v focused=%v: %v",
			lastCandidates,
			lastFocused,
			err,
		)
	}
	return window
}

func requireCalculatorButtonElement(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	application *pb.Application,
	window *pb.Window,
	displays []*pb.Display,
	label string,
) *pb.Element {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var button *pb.Element
	if err := PollUntilContext(waitCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(waitCtx, &pb.TraverseAccessibilityRequest{
			Name:        application.GetName(),
			VisibleOnly: true,
		})
		if err != nil {
			return false, nil
		}
		var matches []*pb.Element
		for _, element := range response.GetElements() {
			if element == nil ||
				!strings.Contains(strings.ToLower(element.GetRole()), "button") ||
				strings.TrimSpace(element.GetText()) != label ||
				element.X == nil || element.Y == nil ||
				element.Width == nil || element.Height == nil ||
				element.GetWidth() <= 0 || element.GetHeight() <= 0 {
				continue
			}
			center := elementCenter(element)
			if !pointInWindow(center.GetX(), center.GetY(), window.GetBounds()) {
				continue
			}
			displayOwners := 0
			for _, display := range displays {
				if pointInRegion(center.GetX(), center.GetY(), display.GetVisibleFrame()) {
					displayOwners++
				}
			}
			if displayOwners == 1 {
				matches = append(matches, element)
			}
		}
		if len(matches) != 1 {
			return false, nil
		}
		button = matches[0]
		return true, nil
	}); err != nil {
		t.Fatalf("Calculator button %q did not resolve exactly: %v", label, err)
	}
	return button
}

func clearCalculatorWithGeneratedInput(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	application *pb.Application,
	window *pb.Window,
) {
	t.Helper()
	for range 2 {
		createCompletedInput(
			t,
			ctx,
			client,
			newIntegrationInputRequest(
				t,
				application.GetName(),
				windowInputTarget(window.GetName()),
				&pb.InputAction{
					InputType: &pb.InputAction_PressKey{
						PressKey: &pb.KeyPress{Key: "c"},
					},
				},
			),
			2,
			"clear owned Calculator window",
		)
	}
}

func switchCalculatorToBasicWithGeneratedInput(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	application *pb.Application,
	window *pb.Window,
) {
	t.Helper()
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			application.GetName(),
			windowInputTarget(window.GetName()),
			&pb.InputAction{
				InputType: &pb.InputAction_PressKey{
					PressKey: &pb.KeyPress{
						Key:       "1",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		),
		2,
		"switch owned Calculator to Basic mode",
	)
}

func requireCalculatorPhysicalValue(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	application *pb.Application,
	display *ownedCalculatorDisplay,
	want string,
) *ownedCalculatorDisplay {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var got string
	var candidates []string
	resolved := display
	if err := PollUntilContext(waitCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(waitCtx, &pb.TraverseAccessibilityRequest{
			Name: application.GetName(),
		})
		if err != nil {
			return false, nil
		}
		got = ""
		candidates = candidates[:0]
		var match *pb.Element
		for _, element := range response.GetElements() {
			if element == nil {
				continue
			}
			role := strings.ToLower(element.GetRole())
			if !strings.Contains(role, "statictext") {
				continue
			}
			if resolved != nil &&
				(element.GetRole() != resolved.role ||
					!elementPathEqual(element.GetPath(), resolved.path)) {
				continue
			}
			normalized := normalizeCalculatorDisplayValue(element.GetAttributes()["AXValue"])
			if normalized == "" || !isNumeric(normalized) {
				continue
			}
			candidates = append(
				candidates,
				fmt.Sprintf(
					"role=%q path=%v name=%q value=%q",
					element.GetRole(),
					element.GetPath(),
					element.GetName(),
					normalized,
				),
			)
			got = normalized
			if match != nil {
				return false, nil
			}
			match = element
		}
		if match == nil || len(candidates) != 1 || got != want {
			return false, nil
		}
		if resolved == nil {
			resolved = &ownedCalculatorDisplay{
				path: append([]int32(nil), match.GetPath()...),
				role: match.GetRole(),
			}
		}
		return true, nil
	}); err != nil {
		t.Fatalf(
			"Calculator value did not converge to %q; last=%q candidates=%v: %v",
			want,
			got,
			candidates,
			err,
		)
	}
	return resolved
}

func normalizeCalculatorDisplayValue(value string) string {
	return strings.Map(func(character rune) rune {
		switch {
		case unicode.Is(unicode.Cf, character), unicode.IsSpace(character), character == ',':
			return -1
		case character == '−':
			return '-'
		default:
			return character
		}
	}, strings.TrimSpace(value))
}

func requireTextEditVerticalScroll(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
) *ownedTextEditScroll {
	t.Helper()
	geometry := requireCurrentOwnedTextEditGeometry(t, ctx, client, fixture)
	response, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
		Name:        fixture.application.GetName(),
		VisibleOnly: true,
	})
	if err != nil {
		t.Fatalf("read TextEdit scroll value: %v", err)
	}
	var candidates []*ownedTextEditScroll
	maximumSharedPath := -1
	for _, element := range response.GetElements() {
		if element == nil ||
			!strings.Contains(strings.ToLower(element.GetRole()), "scrollbar") ||
			element.X == nil || element.Y == nil ||
			element.Width == nil || element.Height == nil ||
			element.GetHeight() <= element.GetWidth() {
			continue
		}
		center := elementCenter(element)
		if !pointInWindow(center.GetX(), center.GetY(), geometry.window.GetBounds()) {
			continue
		}
		value, parseErr := strconv.ParseFloat(element.GetAttributes()["AXValue"], 64)
		if parseErr == nil && !math.IsNaN(value) && !math.IsInf(value, 0) {
			sharedPath := sharedElementPathPrefix(
				element.GetPath(),
				fixture.elementPath,
			)
			candidate := &ownedTextEditScroll{
				path:  append([]int32(nil), element.GetPath()...),
				role:  element.GetRole(),
				value: value,
			}
			switch {
			case sharedPath > maximumSharedPath:
				maximumSharedPath = sharedPath
				candidates = []*ownedTextEditScroll{candidate}
			case sharedPath == maximumSharedPath:
				candidates = append(candidates, candidate)
			}
		}
	}
	if len(candidates) != 1 {
		t.Fatalf(
			"TextEdit exact vertical scrollbar candidates=%v at shared path depth %d, want one",
			candidates,
			maximumSharedPath,
		)
	}
	return candidates[0]
}

func requireTextEditScrollDelta(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
	before *ownedTextEditScroll,
) {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var after float64
	if err := PollUntilContext(waitCtx, 50*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(
			waitCtx,
			&pb.TraverseAccessibilityRequest{
				Name:        fixture.application.GetName(),
				VisibleOnly: true,
			},
		)
		if err != nil {
			return false, nil
		}
		found := false
		for _, element := range response.GetElements() {
			if element == nil ||
				element.GetRole() != before.role ||
				!elementPathEqual(element.GetPath(), before.path) {
				continue
			}
			value, parseErr := strconv.ParseFloat(element.GetAttributes()["AXValue"], 64)
			if parseErr != nil || math.IsNaN(value) || math.IsInf(value, 0) {
				return false, nil
			}
			if found {
				return false, nil
			}
			found = true
			after = value
		}
		return found && after > before.value, nil
	}); err != nil {
		t.Fatalf(
			"TextEdit exact scroll value did not increase from %v; last=%v path=%v: %v",
			before.value,
			after,
			before.path,
			err,
		)
	}
}

func sharedElementPathPrefix(lhs, rhs []int32) int {
	limit := min(len(lhs), len(rhs))
	index := 0
	for index < limit && lhs[index] == rhs[index] {
		index++
	}
	return index
}

func moveCaretToDocumentStart(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
) {
	t.Helper()
	sendWindowKey(t, ctx, client, fixture, "up", pb.KeyPress_MODIFIER_COMMAND)
}

func moveCaretToDocumentEnd(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
) {
	t.Helper()
	sendWindowKey(t, ctx, client, fixture, "down", pb.KeyPress_MODIFIER_COMMAND)
}

func sendWindowKey(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
	key string,
	modifier pb.KeyPress_Modifier,
) {
	t.Helper()
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			fixture.application.GetName(),
			windowInputTarget(fixture.window.GetName()),
			&pb.InputAction{
				InputType: &pb.InputAction_PressKey{PressKey: &pb.KeyPress{
					Key:       key,
					Modifiers: []pb.KeyPress_Modifier{modifier},
				}},
			},
		),
		2,
		"TextEdit key "+key,
	)
}

func currentTextEditRawContent(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
) (string, bool) {
	t.Helper()
	response, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
		Name:        fixture.application.GetName(),
		VisibleOnly: true,
	})
	if err != nil {
		return "", false
	}
	if element := resolveOwnedTextEditTextArea(response.GetElements(), fixture); element != nil {
		return element.GetText(), true
	}
	return "", false
}

// resolveOwnedTextEditTextArea identifies the fixture's text area across one
// traversal result. It prefers the exact frozen element path captured at
// fixture creation. The path's first segment encodes the owning window index as
// a negative number (-(windowIndex+1)); when stale TextEdit state from a prior
// test injects an extra window, the target document shifts to a different
// window index and the frozen path no longer matches even though the owned,
// focused text area is present and correct. The fallback re-resolves the
// focused text area within the owned window each call (mirroring fixture
// creation) so reads stay environment-independent and never report a false
// content loss or geometry change.
func resolveOwnedTextEditTextArea(
	elements []*pb.Element,
	fixture *keyboardTextEditFixture,
) *pb.Element {
	var focusedFallback *pb.Element
	for _, element := range elements {
		if element == nil || !isTextEditTextArea(element.GetRole()) {
			continue
		}
		if elementPathEqual(element.GetPath(), fixture.elementPath) {
			return element
		}
		if element.GetFocused() && ownedTextAreaIntersectsWindow(element, fixture.window.GetBounds()) {
			focusedFallback = element
		}
	}
	return focusedFallback
}

// ownedTextAreaIntersectsWindow reports whether a text-area element's frame
// overlaps the owned fixture window bounds, the same ownership test the fixture
// uses when it first resolves the text area.
func ownedTextAreaIntersectsWindow(element *pb.Element, bounds *pb.Bounds) bool {
	if bounds == nil || element == nil {
		return false
	}
	x := element.GetX()
	y := element.GetY()
	w := element.GetWidth()
	h := element.GetHeight()
	if w <= 0 || h <= 0 {
		return false
	}
	return x < bounds.GetX()+bounds.GetWidth() &&
		x+w > bounds.GetX() &&
		y < bounds.GetY()+bounds.GetHeight() &&
		y+h > bounds.GetY()
}

func requireCurrentTextEditRawContent(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
) string {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var content string
	if err := PollUntilContext(waitCtx, 50*time.Millisecond, func() (bool, error) {
		var found bool
		content, found = currentTextEditRawContent(t, waitCtx, client, fixture)
		return found, nil
	}); err != nil {
		t.Fatalf(
			"TextEdit exact-path content was unavailable; candidates=%v: %v",
			describeTextEditContentCandidates(t, ctx, client, fixture),
			err,
		)
	}
	return content
}

func requireTextEditRawContent(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
	want string,
) {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var got string
	if err := PollUntilContext(waitCtx, 50*time.Millisecond, func() (bool, error) {
		var found bool
		got, found = currentTextEditRawContent(t, waitCtx, client, fixture)
		return found && got == want, nil
	}); err != nil {
		t.Fatalf(
			"TextEdit exact content mismatch got_bytes=%d want_bytes=%d got_prefix=%q got_suffix=%q want_prefix=%q want_suffix=%q candidates=%v: %v",
			len(got),
			len(want),
			previewDiagnosticText(got, true),
			previewDiagnosticText(got, false),
			previewDiagnosticText(want, true),
			previewDiagnosticText(want, false),
			describeTextEditContentCandidates(t, ctx, client, fixture),
			err,
		)
	}
}

func describeTextEditContentCandidates(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
) []string {
	t.Helper()
	response, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
		Name:        fixture.application.GetName(),
		VisibleOnly: true,
	})
	if err != nil {
		return []string{fmt.Sprintf("traversal_error=%v", err)}
	}
	var candidates []string
	for _, element := range response.GetElements() {
		if element == nil || !isTextEditTextArea(element.GetRole()) {
			continue
		}
		candidates = append(candidates, fmt.Sprintf(
			"name=%q path=%v exact_path=%t bytes=%d prefix=%q suffix=%q focused=%t",
			element.GetName(),
			element.GetPath(),
			elementPathEqual(element.GetPath(), fixture.elementPath),
			len(element.GetText()),
			previewDiagnosticText(element.GetText(), true),
			previewDiagnosticText(element.GetText(), false),
			element.GetFocused(),
		))
	}
	return candidates
}

func requireTextEditChanged(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
	before string,
) {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := PollUntilContext(waitCtx, 20*time.Millisecond, func() (bool, error) {
		return getTextEditContent(t, waitCtx, client, fixture) != before, nil
	}); err != nil {
		t.Fatalf("TextEdit did not observe held-key physical effect: %v", err)
	}
}

func requireTextEditStableAfterRecovery(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
	recovery string,
) {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	var last string
	var stableSince time.Time
	if err := PollUntilContext(waitCtx, 20*time.Millisecond, func() (bool, error) {
		current := getTextEditContent(t, waitCtx, client, fixture)
		if !strings.Contains(current, recovery) {
			last = current
			stableSince = time.Time{}
			return false, nil
		}
		if current != last {
			last = current
			stableSince = time.Now()
			return false, nil
		}
		return !stableSince.IsZero() && time.Since(stableSince) >= 250*time.Millisecond, nil
	}); err != nil {
		t.Fatalf("TextEdit recovery did not become stable after key cleanup: %v", err)
	}
}

func replaceTextEditSelectionWithGeneratedInput(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
	replacement string,
) {
	t.Helper()
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			fixture.application.GetName(),
			windowInputTarget(fixture.window.GetName()),
			&pb.InputAction{
				InputType: &pb.InputAction_TypeText{TypeText: &pb.TextInput{
					Text: replacement,
				}},
			},
		),
		2,
		"replace exact TextEdit selection",
	)
}

func requireWholeDocumentSelectionAndUndo(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
	document string,
) {
	t.Helper()
	const replacement = "§"
	if document == "" || strings.Contains(document, replacement) {
		t.Fatalf("whole-document selection oracle requires nonempty marker-free content")
	}
	requireTextEditRawContent(t, ctx, client, fixture, document)
	replaceTextEditSelectionWithGeneratedInput(t, ctx, client, fixture, replacement)
	requireTextEditRawContent(t, ctx, client, fixture, replacement)
	sendWindowKey(t, ctx, client, fixture, "z", pb.KeyPress_MODIFIER_COMMAND)
	requireTextEditRawContent(t, ctx, client, fixture, document)
}

func requirePartialDocumentSelectionAndUndo(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
	document string,
) {
	t.Helper()
	const replacement = "¶"
	if document == "" || strings.Contains(document, replacement) {
		t.Fatalf("partial-selection oracle requires nonempty marker-free content")
	}
	requireTextEditRawContent(t, ctx, client, fixture, document)
	replaceTextEditSelectionWithGeneratedInput(t, ctx, client, fixture, replacement)

	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var got string
	if err := PollUntilContext(waitCtx, 50*time.Millisecond, func() (bool, error) {
		var found bool
		got, found = currentTextEditRawContent(t, waitCtx, client, fixture)
		if !found || strings.Count(got, replacement) != 1 {
			return false, nil
		}
		before, after, _ := strings.Cut(got, replacement)
		prefix := before
		suffix := after
		if len(prefix)+len(suffix) >= len(document) {
			return false, nil
		}
		return strings.HasPrefix(document, prefix) &&
			strings.HasSuffix(document, suffix), nil
	}); err != nil {
		t.Fatalf(
			"owned TextEdit drag did not replace a nonempty exact substring; got_prefix=%q got_suffix=%q: %v",
			previewDiagnosticText(got, true),
			previewDiagnosticText(got, false),
			err,
		)
	}
	sendWindowKey(t, ctx, client, fixture, "z", pb.KeyPress_MODIFIER_COMMAND)
	requireTextEditRawContent(t, ctx, client, fixture, document)
}

func requireClipboardSnapshot(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
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
	client pb.MacosUseClient,
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
	client pb.MacosUseClient,
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
	client pb.MacosUseClient,
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
			InputType: &pb.InputAction_MoveMouse{MoveMouse: &pb.MouseMove{
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
	client pb.MacosUseClient,
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

func requireWindowGone(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	name string,
) {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := PollUntilContext(waitCtx, 50*time.Millisecond, func() (bool, error) {
		_, err := client.GetWindow(waitCtx, &pb.GetWindowRequest{Name: name})
		return status.Code(err) == codes.NotFound, nil
	}); err != nil {
		t.Fatalf("owned window %q remained available: %v", name, err)
	}
}

func physicalTruthDocument() string {
	var builder strings.Builder
	for index := range 180 {
		_, _ = fmt.Fprintf(
			&builder,
			"owned line %03d alpha beta gamma delta epsilon zeta eta theta iota kappa\n",
			index,
		)
	}
	builder.WriteString("OWNED-END")
	return builder.String()
}

func visibleTextDragPath(geometry ownedTextEditGeometry) []ownedDragPoint {
	visible := geometry.visibleTextArea
	y := visible.y + min(28, visible.height*0.15)
	return []ownedDragPoint{
		{x: visible.x + visible.width*0.20, y: y},
		{x: visible.x + visible.width*0.70, y: y},
	}
}

func cancellableTextDragPath(geometry ownedTextEditGeometry) []ownedDragPoint {
	visible := geometry.visibleTextArea
	path := make([]ownedDragPoint, 0, 25)
	left := visible.x + visible.width*0.25
	right := visible.x + visible.width*0.65
	top := visible.y + min(35, visible.height*0.20)
	for index := range 25 {
		fraction := float64(index) / 24
		path = append(path, ownedDragPoint{
			x: left + (right-left)*fraction,
			y: top + math.Sin(fraction*math.Pi)*min(12, visible.height*0.05),
		})
	}
	return path
}

func pointInElement(x float64, y float64, element *pb.Element) bool {
	return element != nil &&
		x >= element.GetX() &&
		x <= element.GetX()+element.GetWidth() &&
		y >= element.GetY() &&
		y <= element.GetY()+element.GetHeight()
}

func elementCenter(element *pb.Element) *typepb.Point {
	return &typepb.Point{
		X: element.GetX() + element.GetWidth()/2,
		Y: element.GetY() + element.GetHeight()/2,
	}
}

func pointMessage(point ownedDragPoint) *typepb.Point {
	return &typepb.Point{X: point.x, Y: point.y}
}

func safeDisplayPoint(frame *typepb.Region, xFraction float64, yFraction float64) *typepb.Point {
	return &typepb.Point{
		X: frame.GetX() + frame.GetWidth()*xFraction,
		Y: frame.GetY() + frame.GetHeight()*yFraction,
	}
}

func requireUniqueDisplayPoint(
	t *testing.T,
	target *pb.Display,
	displays []*pb.Display,
	preferredX float64,
	preferredY float64,
) *typepb.Point {
	t.Helper()
	fractions := [][2]float64{
		{preferredX, preferredY},
		{0.5, 0.5},
		{0.25, 0.25},
		{0.75, 0.25},
		{0.25, 0.75},
		{0.75, 0.75},
		{0.125, 0.5},
		{0.875, 0.5},
	}
	for _, fraction := range fractions {
		point := safeDisplayPoint(target.GetFrame(), fraction[0], fraction[1])
		var owners []*pb.Display
		for _, display := range displays {
			if pointInRegion(point.GetX(), point.GetY(), display.GetFrame()) {
				owners = append(owners, display)
			}
		}
		if len(owners) == 1 && owners[0].GetName() == target.GetName() {
			return point
		}
	}
	t.Fatalf(
		"display %q exposes no uniquely owned candidate point against %d active frames",
		target.GetName(),
		len(displays),
	)
	return nil
}
