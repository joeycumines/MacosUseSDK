// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

type ownedTextEditScroll struct {
	path  []int32
	role  string
	value float64
}

func requireTextEditVerticalScroll(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
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
				element.GetPathIndices(),
				fixture.elementPath,
			)
			candidate := &ownedTextEditScroll{
				path:  append([]int32(nil), element.GetPathIndices()...),
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
	client pb.ExactMacClient,
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
				!elementPathEqual(element.GetPathIndices(), before.path) {
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
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
) {
	t.Helper()
	sendWindowKey(t, ctx, client, fixture, "up", pb.KeyPress_MODIFIER_COMMAND)
}

func moveCaretToDocumentEnd(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
) {
	t.Helper()
	sendWindowKey(t, ctx, client, fixture, "down", pb.KeyPress_MODIFIER_COMMAND)
}

func sendWindowKey(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
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
				InputType: &pb.InputAction_KeyPress{KeyPress: &pb.KeyPress{
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
	client pb.ExactMacClient,
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
		if elementPathEqual(element.GetPathIndices(), fixture.elementPath) {
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
	client pb.ExactMacClient,
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
	client pb.ExactMacClient,
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
	client pb.ExactMacClient,
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
			element.GetPathIndices(),
			elementPathEqual(element.GetPathIndices(), fixture.elementPath),
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
	client pb.ExactMacClient,
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
	client pb.ExactMacClient,
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
	client pb.ExactMacClient,
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
				InputType: &pb.InputAction_TextInput{TextInput: &pb.TextInput{
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
	client pb.ExactMacClient,
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
	client pb.ExactMacClient,
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
