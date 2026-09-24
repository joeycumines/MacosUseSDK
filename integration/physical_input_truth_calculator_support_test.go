// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func requireOwnedApplicationWindow(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
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
	client pb.ExactMacClient,
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
	client pb.ExactMacClient,
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
					InputType: &pb.InputAction_KeyPress{
						KeyPress: &pb.KeyPress{Key: "c"},
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
	client pb.ExactMacClient,
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
				InputType: &pb.InputAction_KeyPress{
					KeyPress: &pb.KeyPress{
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
	client pb.ExactMacClient,
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
					!elementPathEqual(element.GetPathIndices(), resolved.path)) {
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
					element.GetPathIndices(),
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
				path: append([]int32(nil), match.GetPathIndices()...),
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

func requireWindowGone(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
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
