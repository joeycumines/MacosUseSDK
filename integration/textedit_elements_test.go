package integration

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

func isTextEditTextArea(role string) bool {
	roleLower := strings.ToLower(role)
	return strings.Contains(roleLower, "textarea") ||
		strings.Contains(roleLower, "textview") ||
		strings.Contains(roleLower, "webarea") ||
		strings.Contains(roleLower, "text area") ||
		strings.Contains(roleLower, "web area") ||
		strings.Contains(roleLower, "html content")
}

func logTraversalDiagnostics(t *testing.T, resp *pb.TraverseAccessibilityResponse) {
	t.Helper()

	t.Logf("Traversal stats: count=%d, visible=%d, excluded=%d (non_interactable=%d, no_text=%d)",
		resp.Stats.Count,
		resp.Stats.VisibleElementsCount,
		resp.Stats.ExcludedCount,
		resp.Stats.ExcludedNonInteractable,
		resp.Stats.ExcludedNoText)

	roles := make([]string, 0, len(resp.Stats.RoleCounts))
	for role := range resp.Stats.RoleCounts {
		roles = append(roles, role)
	}
	sort.Strings(roles)
	for _, role := range roles {
		t.Logf("Traversal role %s: %d", role, resp.Stats.RoleCounts[role])
	}
}

type textEditElementFixture struct {
	application *pb.Application
	window      *pb.Window
	textArea    *pb.Element
	marker      string
}

// openOwnedTextEditElementFixture creates one non-empty fixture-owned file,
// resolves its exact titled window, focuses that resource, and binds the AX text
// area by unique content plus Global Display Coordinates inside the owned window.
func openOwnedTextEditElementFixture(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	opsClient longrunningpb.OperationsClient,
) *textEditElementFixture {
	t.Helper()

	fileName := fmt.Sprintf("element-integration-%d.txt", time.Now().UnixNano())
	marker := fmt.Sprintf("OWNED_TEXTEDIT_ELEMENT_%d", time.Now().UnixNano())
	filePath := filepath.Join(t.TempDir(), fileName)
	if err := os.WriteFile(filePath, []byte(marker), 0o600); err != nil {
		t.Fatalf("create owned TextEdit file: %v", err)
	}

	openCtx, cancelOpen := context.WithTimeout(ctx, 10*time.Second)
	defer cancelOpen()
	openCommand := exec.CommandContext(openCtx, "open", "-a", "TextEdit", filePath)
	if output, err := openCommand.CombinedOutput(); err != nil {
		t.Fatalf("open owned TextEdit file %q: %v output=%q", fileName, err, output)
	}

	attachCtx, cancelAttach := context.WithTimeout(ctx, 20*time.Second)
	defer cancelAttach()
	app := OpenApplicationObserved(t, attachCtx, client, "com.apple.TextEdit")

	windowCtx, cancelWindow := context.WithTimeout(ctx, 10*time.Second)
	defer cancelWindow()
	var targetWindow *pb.Window
	if err := PollUntilContext(windowCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.ListWindows(windowCtx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, nil
		}
		for _, window := range response.Windows {
			if window != nil && window.Bounds != nil &&
				strings.Contains(window.Title, fileName) &&
				window.Bounds.Width > 0 && window.Bounds.Height > 100 {
				targetWindow = window
				return true, nil
			}
		}
		return false, nil
	}); err != nil {
		t.Fatalf("owned TextEdit window %q never appeared: %v", fileName, err)
	}

	focusedWindow, err := client.FocusWindow(windowCtx, &pb.FocusWindowRequest{Name: targetWindow.Name})
	if err != nil {
		t.Fatalf("focus owned TextEdit window %q: %v", targetWindow.Name, err)
	}
	targetWindow = focusedWindow
	if err := PollUntilContext(windowCtx, 100*time.Millisecond, func() (bool, error) {
		state, err := client.GetWindowState(windowCtx, &pb.GetWindowStateRequest{
			Name: targetWindow.Name + "/state",
		})
		return err == nil && state.Focused, nil
	}); err != nil {
		t.Fatalf("owned TextEdit window %q never became focused: %v", targetWindow.Name, err)
	}

	traversalCtx, cancelTraversal := context.WithTimeout(ctx, 10*time.Second)
	defer cancelTraversal()
	var textArea *pb.Element
	var lastResponse *pb.TraverseAccessibilityResponse
	if err := PollUntilContext(traversalCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(traversalCtx, &pb.TraverseAccessibilityRequest{
			Name: app.Name, VisibleOnly: true,
		})
		if err != nil {
			return false, nil
		}
		lastResponse = response
		for _, element := range response.Elements {
			if !elementIsOwnedTextArea(element, targetWindow, nil) || !strings.Contains(element.GetText(), marker) {
				continue
			}
			textArea = element
			return true, nil
		}
		return false, nil
	}); err != nil {
		if lastResponse != nil {
			logTraversalDiagnostics(t, lastResponse)
		}
		t.Fatalf("owned TextEdit text area never exposed marker %q: %v", marker, err)
	}
	if textArea.ElementId == "" {
		t.Fatal("owned TextEdit traversal returned an empty element_id")
	}
	if len(textArea.Path) == 0 {
		t.Fatal("owned TextEdit traversal returned an empty hierarchy path")
	}

	return &textEditElementFixture{
		application: app,
		window:      targetWindow,
		textArea:    textArea,
		marker:      marker,
	}
}

func cleanupOwnedTextEditElementFixture(
	t *testing.T,
	client pb.ExactMacClient,
	fixture *textEditElementFixture,
) {
	t.Helper()
	cleanupCtx, cancelCleanup := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancelCleanup()
	cleanupApplication(t, cleanupCtx, client, fixture.application)
	killTextEdit(t)
}

func elementIsOwnedTextArea(element *pb.Element, window *pb.Window, expectedPath []int32) bool {
	if element == nil || !isTextEditTextArea(element.Role) ||
		element.X == nil || element.Y == nil || element.Width == nil || element.Height == nil ||
		element.GetWidth() <= 0 || element.GetHeight() <= 0 {
		return false
	}
	if expectedPath != nil && !elementPathEqual(element.Path, expectedPath) {
		return false
	}
	centerX := element.GetX() + element.GetWidth()/2
	centerY := element.GetY() + element.GetHeight()/2
	return pointInWindow(centerX, centerY, window.Bounds)
}

func ownedTextAreaSelector(fixture *textEditElementFixture) *typepb.ElementSelector {
	return &typepb.ElementSelector{
		Criteria: &typepb.ElementSelector_Compound{Compound: &typepb.CompoundSelector{
			Operator: typepb.CompoundSelector_OPERATOR_AND,
			Selectors: []*typepb.ElementSelector{
				{Criteria: &typepb.ElementSelector_Role{Role: fixture.textArea.Role}},
				{Criteria: &typepb.ElementSelector_Text{Text: fixture.marker}},
			},
		}},
	}
}

func pollOwnedTextAreaValue(
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *textEditElementFixture,
	want string,
) (string, error) {
	var observed string
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
			Name: fixture.application.Name, VisibleOnly: true,
		})
		if err != nil {
			return false, nil
		}
		for _, element := range response.Elements {
			if !elementIsOwnedTextArea(element, fixture.window, fixture.textArea.Path) {
				continue
			}
			observed = element.GetText()
			return observed == want, nil
		}
		return false, nil
	})
	return observed, err
}

func newTextEditElementTest(
	t *testing.T,
) (context.Context, pb.ExactMacClient, *textEditElementFixture) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	killTextEdit(t)

	serverCmd, serverAddr := startServer(t, ctx)
	conn := connectToServer(t, ctx, serverAddr)
	client := pb.NewExactMacClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)
	var fixture *textEditElementFixture
	t.Cleanup(func() {
		if fixture != nil {
			cleanupOwnedTextEditElementFixture(t, client, fixture)
		} else {
			killTextEdit(t)
		}
		_ = conn.Close()
		cleanupServer(t, serverCmd, serverAddr)
		cancel()
	})
	fixture = openOwnedTextEditElementFixture(t, ctx, client, opsClient)
	return ctx, client, fixture
}

func TestTextEditElements_TraverseAndFindTextArea(t *testing.T) {
	ctx, client, fixture := newTextEditElementTest(t)

	queryCtx, cancelQuery := context.WithTimeout(ctx, 10*time.Second)
	defer cancelQuery()
	var found *pb.Element
	if err := PollUntilContext(queryCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(queryCtx, &pb.TraverseAccessibilityRequest{
			Name: fixture.application.Name, VisibleOnly: true,
		})
		if err != nil {
			return false, nil
		}
		for _, element := range response.Elements {
			if elementIsOwnedTextArea(element, fixture.window, fixture.textArea.Path) &&
				element.GetText() == fixture.marker {
				found = element
				return true, nil
			}
		}
		return false, nil
	}); err != nil {
		t.Fatalf("repeated traversal did not return the owned text area: %v", err)
	}
	if found.ElementId == "" || found.Role == "" {
		t.Fatalf("owned text area identity incomplete: id=%q role=%q", found.ElementId, found.Role)
	}
}

func TestTextEditElements_WriteAndReadValue(t *testing.T) {
	ctx, client, fixture := newTextEditElementTest(t)

	testValue := fmt.Sprintf("OWNED_WRITE_%d", time.Now().UnixNano())
	actionCtx, cancelAction := context.WithTimeout(ctx, 10*time.Second)
	writeResponse, err := client.WriteElementValue(actionCtx, &pb.WriteElementValueRequest{
		Parent: fixture.application.Name,
		Target: &pb.WriteElementValueRequest_ElementId{
			ElementId: fixture.textArea.ElementId,
		},
		Value: &testValue,
	})
	cancelAction()
	if err != nil {
		t.Fatalf("WriteElementValue for owned element_id failed: %v", err)
	}
	if !writeResponse.Success {
		t.Fatal("WriteElementValue returned success=false without an RPC error")
	}
	if writeResponse.Element.ElementId != fixture.textArea.ElementId {
		t.Fatalf("WriteElementValue returned wrong element: got %q want %q", writeResponse.Element.ElementId, fixture.textArea.ElementId)
	}

	verifyCtx, cancelVerify := context.WithTimeout(ctx, 10*time.Second)
	defer cancelVerify()
	observed, err := pollOwnedTextAreaValue(verifyCtx, client, fixture, testValue)
	if err != nil {
		t.Fatalf("owned TextEdit AX value did not change from %q to %q: observed=%q error=%v", fixture.marker, testValue, observed, err)
	}
}

func TestTextEditElements_FindElementsBySelector(t *testing.T) {
	ctx, client, fixture := newTextEditElementTest(t)

	queryCtx, cancelQuery := context.WithTimeout(ctx, 10*time.Second)
	defer cancelQuery()
	response, err := client.FindElements(queryCtx, &pb.FindElementsRequest{
		Parent:      fixture.application.Name,
		Selector:    ownedTextAreaSelector(fixture),
		VisibleOnly: true,
	})
	if err != nil {
		t.Fatalf("FindElements for owned compound selector failed: %v", err)
	}
	if len(response.Elements) != 1 {
		t.Fatalf("owned compound selector returned %d elements, want exactly 1", len(response.Elements))
	}
	found := response.Elements[0]
	if !elementIsOwnedTextArea(found, fixture.window, fixture.textArea.Path) || found.GetText() != fixture.marker {
		t.Fatalf("selector returned wrong element: role=%q text=%q path=%v", found.Role, found.GetText(), found.Path)
	}
}

func TestTextEditElements_WriteValueBySelector(t *testing.T) {
	ctx, client, fixture := newTextEditElementTest(t)

	testValue := fmt.Sprintf("OWNED_SELECTOR_WRITE_%d", time.Now().UnixNano())
	actionCtx, cancelAction := context.WithTimeout(ctx, 10*time.Second)
	response, err := client.WriteElementValue(actionCtx, &pb.WriteElementValueRequest{
		Parent: fixture.application.Name,
		Target: &pb.WriteElementValueRequest_Selector{
			Selector: ownedTextAreaSelector(fixture),
		},
		Value: &testValue,
	})
	cancelAction()
	if err != nil {
		t.Fatalf("WriteElementValue for owned compound selector failed: %v", err)
	}
	if !response.Success {
		t.Fatal("selector WriteElementValue returned success=false without an RPC error")
	}

	verifyCtx, cancelVerify := context.WithTimeout(ctx, 10*time.Second)
	defer cancelVerify()
	observed, err := pollOwnedTextAreaValue(verifyCtx, client, fixture, testValue)
	if err != nil {
		t.Fatalf("selector write did not mutate the owned TextEdit AX value: observed=%q want=%q error=%v", observed, testValue, err)
	}
}
