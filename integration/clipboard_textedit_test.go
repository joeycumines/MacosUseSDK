package integration

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	pbtype "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/protobuf/types/known/durationpb"
)

// TestClipboardPasteIntoTextEdit verifies the end-to-end paste flow:
// 1. Write text to the clipboard via the API
// 2. Open a temporary text file in TextEdit
// 3. Focus the document and paste (Cmd+V) using the input API
// 4. Save the document (Cmd+S)
// 5. Read the file and assert the pasted text is present
func TestClipboardPasteIntoTextEdit(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Robustly kill TextEdit, clear saved state, and disable modal dialogs
	killTextEdit(t)

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// Ensure TextEdit isn't already tracked from previous runs
	killGoldenApplications()

	// Create a temporary file that TextEdit will open
	// IMPORTANT: Pre-populate with placeholder text so TextEdit opens THIS file,
	// not a new "Untitled" document. Empty files cause TextEdit to create a new doc,
	// and Cmd+S would then open a Save dialog instead of saving to our path.
	dir := t.TempDir()
	fname := fmt.Sprintf("paste-integration-%d.txt", time.Now().UnixNano())
	filePath := filepath.Join(dir, fname)

	const placeholderText = "PLACEHOLDER_TEXT_FOR_TEXTEDIT"
	if err := os.WriteFile(filePath, []byte(placeholderText), 0600); err != nil {
		t.Fatalf("failed to create temp file: %v", err)
	}

	// Prepare clipboard data via API
	pasteText := fmt.Sprintf("integration-clipboard-%d", time.Now().UnixNano())
	_, err := client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
		Content: &pb.ClipboardContent{
			Type:    pb.ContentType_CONTENT_TYPE_TEXT.Enum(),
			Content: &pb.ClipboardContent_Text{Text: pasteText},
		},
	})
	if err != nil {
		t.Fatalf("WriteClipboard failed: %v", err)
	}

	// Open the file with the default app (TextEdit)
	cmd := exec.Command("open", filePath)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("failed to open file %s: %v - %s", filePath, err, string(out))
	}

	// Ensure the server knows about TextEdit and that it is tracked
	t.Log("Attaching to TextEdit via OpenApplication...")
	app := OpenApplicationObserved(t, ctx, client, "com.apple.TextEdit")
	defer cleanupApplication(t, ctx, client, app)

	// Resolve the exact document by its unique fixture filename, not by a
	// generic size heuristic that can select an Open Recent or unrelated window.
	windowCtx, windowCancel := context.WithTimeout(ctx, 5*time.Second)
	defer windowCancel()

	var targetWindow *pb.Window
	err = PollUntilContext(windowCtx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(windowCtx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, nil
		}
		for _, w := range resp.Windows {
			if w == nil || w.Bounds == nil {
				continue
			}
			if strings.Contains(w.Title, fname) && w.Bounds.Width > 0 && w.Bounds.Height > 100 {
				targetWindow = w
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Owned TextEdit window %q never appeared: %v", fname, err)
	}

	// TextEdit may create an Untitled window while the file-open event is still
	// converging. Focus the exact resource returned for the unique fixture file;
	// app-level activation alone does not choose the intended document window.
	targetWindow, err = client.FocusWindow(ctx, &pb.FocusWindowRequest{Name: targetWindow.Name})
	if err != nil {
		t.Fatalf("FocusWindow for owned TextEdit document failed: %v", err)
	}
	windowFocusCtx, cancelWindowFocus := context.WithTimeout(ctx, 5*time.Second)
	defer cancelWindowFocus()
	err = PollUntilContext(windowFocusCtx, 100*time.Millisecond, func() (bool, error) {
		state, err := client.GetWindowState(windowFocusCtx, &pb.GetWindowStateRequest{
			Name: targetWindow.Name + "/state",
		})
		if err != nil {
			return false, nil
		}
		return state.Focused, nil
	})
	if err != nil {
		t.Fatalf("Owned TextEdit document window did not become focused: %v", err)
	}

	canonicalFilePath, err := filepath.EvalSymlinks(filePath)
	if err != nil {
		t.Fatalf("resolve owned TextEdit file path: %v", err)
	}
	requireTextEditDocumentState(t, ctx, client, fname, canonicalFilePath, false, "before input")

	displayResp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays before TextEdit input failed: %v", err)
	}
	for _, display := range displayResp.Displays {
		t.Logf(
			"Display %s main=%t frame=(%.1f,%.1f %.1fx%.1f) visible=(%.1f,%.1f %.1fx%.1f)",
			display.Name,
			display.Main,
			display.GetFrame().GetX(),
			display.GetFrame().GetY(),
			display.GetFrame().GetWidth(),
			display.GetFrame().GetHeight(),
			display.GetVisibleFrame().GetX(),
			display.GetVisibleFrame().GetY(),
			display.GetVisibleFrame().GetWidth(),
			display.GetVisibleFrame().GetHeight(),
		)
	}

	// Resolve the actual AX text-area geometry and current placeholder state.
	// This proves the intended document is visible before any physical input.
	var textArea *pb.Element
	traversalCtx, cancelTraversal := context.WithTimeout(ctx, 5*time.Second)
	defer cancelTraversal()
	err = PollUntilContext(traversalCtx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.TraverseAccessibility(
			traversalCtx,
			&pb.TraverseAccessibilityRequest{Name: app.Name, VisibleOnly: true},
		)
		if err != nil {
			return false, nil
		}
		for _, element := range resp.Elements {
			if element == nil || !isTextEditTextArea(element.Role) {
				continue
			}
			if element.X == nil || element.Y == nil || element.Width == nil || element.Height == nil {
				continue
			}
			if element.GetWidth() <= 0 || element.GetHeight() <= 0 {
				continue
			}
			if strings.Contains(element.GetText(), placeholderText) {
				textArea = element
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Owned TextEdit text area never exposed placeholder state: %v", err)
	}

	centerX := textArea.GetX() + (textArea.GetWidth() / 2.0)
	textAreaY := textArea.GetY() + (textArea.GetHeight() / 2.0)
	textAreaPath := append([]int32(nil), textArea.PathIndices...)
	if !pointInWindow(centerX, textAreaY, targetWindow.Bounds) {
		t.Fatalf(
			"Owned TextEdit text area center (%.1f,%.1f) is outside window bounds (%.1f,%.1f %.1fx%.1f)",
			centerX,
			textAreaY,
			targetWindow.Bounds.X,
			targetWindow.Bounds.Y,
			targetWindow.Bounds.Width,
			targetWindow.Bounds.Height,
		)
	}
	pointIsVisible := false
	for _, display := range displayResp.Displays {
		if pointInRegion(centerX, textAreaY, display.GetVisibleFrame()) {
			pointIsVisible = true
			break
		}
	}
	if !pointIsVisible {
		t.Fatalf("Owned TextEdit text area center (%.1f,%.1f) is outside every active visible display frame", centerX, textAreaY)
	}
	t.Logf(
		"Owned window %s bounds=(%.1f,%.1f %.1fx%.1f); text area center=(%.1f,%.1f)",
		targetWindow.Name,
		targetWindow.Bounds.X,
		targetWindow.Bounds.Y,
		targetWindow.Bounds.Width,
		targetWindow.Bounds.Height,
		centerX,
		textAreaY,
	)

	// Click to focus editing area
	clickCount := int32(1)
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			app.GetName(),
			windowInputTarget(targetWindow.GetName()),
			&pb.InputAction{
				InputType: &pb.InputAction_MouseClick{
					MouseClick: &pb.MouseClick{
						Position:   &pbtype.Point{X: centerX, Y: textAreaY},
						ClickCount: &clickCount,
					},
				},
			},
		),
		2,
		"click owned TextEdit text area",
	)

	// A completed click means the event was posted, not necessarily that the
	// intended control received it. Require the AX focus delta before typing.
	focusCtx, cancelFocus := context.WithTimeout(ctx, 5*time.Second)
	defer cancelFocus()
	err = PollUntilContext(focusCtx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.TraverseAccessibility(
			focusCtx,
			&pb.TraverseAccessibilityRequest{Name: app.Name, VisibleOnly: true},
		)
		if err != nil {
			return false, nil
		}
		for _, element := range resp.Elements {
			if element != nil &&
				isTextEditTextArea(element.Role) &&
				element.GetFocused() &&
				elementPathEqual(element.PathIndices, textAreaPath) &&
				strings.Contains(element.GetText(), placeholderText) {
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Owned TextEdit text area did not acquire AX focus: %v", err)
	}

	// Press Cmd+A to select all (selects the placeholder text so paste will replace it)
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			app.GetName(),
			applicationInputTarget(app.GetName()),
			&pb.InputAction{
				InputType: &pb.InputAction_KeyPress{
					KeyPress: &pb.KeyPress{
						Key:       "a",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		),
		2,
		"select all TextEdit content",
	)

	// Press Cmd+V to paste (replaces selected placeholder text)
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			app.GetName(),
			applicationInputTarget(app.GetName()),
			&pb.InputAction{
				InputType: &pb.InputAction_KeyPress{
					KeyPress: &pb.KeyPress{
						Key:       "v",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		),
		2,
		"paste clipboard into TextEdit",
	)

	// Wait for the actual AX document state before saving. This prevents the
	// server from claiming success merely because CGEvents were posted.
	pasteCtx, cancelPaste := context.WithTimeout(ctx, 5*time.Second)
	defer cancelPaste()
	var observedText string
	err = PollUntilContext(pasteCtx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.TraverseAccessibility(
			pasteCtx,
			&pb.TraverseAccessibilityRequest{Name: app.Name, VisibleOnly: true},
		)
		if err != nil {
			return false, nil
		}
		for _, element := range resp.Elements {
			if element == nil ||
				!isTextEditTextArea(element.Role) ||
				!elementPathEqual(element.PathIndices, textAreaPath) {
				continue
			}
			observedText = element.GetText()
			if strings.Contains(observedText, pasteText) &&
				!strings.Contains(observedText, placeholderText) {
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf(
			"Paste never changed the owned TextEdit AX value: observed=%q error=%v",
			observedText,
			err,
		)
	}
	requireTextEditDocumentChangedOrPersisted(
		t,
		ctx,
		client,
		fname,
		canonicalFilePath,
		pasteText,
	)

	// CMD+S to save
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			app.GetName(),
			applicationInputTarget(app.GetName()),
			&pb.InputAction{
				InputType: &pb.InputAction_KeyPress{
					KeyPress: &pb.KeyPress{
						Key:       "s",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		),
		2,
		"save owned TextEdit document",
	)
	requireTextEditDocumentState(t, ctx, client, fname, canonicalFilePath, false, "after save input")

	// Verify clipboard still contains our text
	clipCheck, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil {
		t.Fatalf("Failed to verify clipboard: %v", err)
	}
	t.Logf("Clipboard after paste contains: %q (type=%v)", clipCheck.Content.GetText(), clipCheck.Content.Type)
	if clipCheck.Content.GetText() != pasteText {
		t.Fatalf("Clipboard changed unexpectedly: got %q, want %q", clipCheck.Content.GetText(), pasteText)
	}

	// Poll the filesystem for the expected content (avoid time.Sleep)
	verifyCtx, cancelVerify := context.WithTimeout(ctx, 10*time.Second)
	defer cancelVerify()

	err = PollUntilContext(verifyCtx, 100*time.Millisecond, func() (bool, error) {
		b, readErr := os.ReadFile(filePath)
		if readErr != nil {
			// File may not be fully flushed yet, continue polling
			return false, nil
		}
		if string(b) == pasteText {
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		// Read final contents for debug
		b, readErr := os.ReadFile(filePath)
		t.Fatalf("expected file contents %q, got %q (readErr=%v, pollErr=%v)", pasteText, string(b), readErr, err)
	}
}

func requireTextEditDocumentState(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	targetName string,
	expectedPath string,
	wantModified bool,
	phase string,
) {
	t.Helper()

	stateCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	var lastState textEditDocumentState
	var lastOutput string
	var lastErr error
	err := PollUntilContext(stateCtx, 100*time.Millisecond, func() (bool, error) {
		state, output, err := getTextEditDocumentState(stateCtx, client, targetName)
		lastState = state
		lastOutput = output
		lastErr = err
		if err != nil {
			return false, nil
		}
		return state.found &&
			state.path == expectedPath &&
			state.modified == wantModified &&
			state.otherModifiedCount == 0, nil
	})
	if err != nil {
		t.Fatalf(
			"TextEdit document state %s did not converge: state=%+v output=%q error=%v poll=%v",
			phase,
			lastState,
			lastOutput,
			lastErr,
			err,
		)
	}
}

func requireTextEditDocumentChangedOrPersisted(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	targetName string,
	expectedPath string,
	expectedContent string,
) {
	t.Helper()

	stateCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	var lastState textEditDocumentState
	var lastOutput string
	var lastErr error
	var persisted bool
	err := PollUntilContext(stateCtx, 100*time.Millisecond, func() (bool, error) {
		state, output, err := getTextEditDocumentState(stateCtx, client, targetName)
		lastState = state
		lastOutput = output
		lastErr = err
		if err != nil || !state.found || state.path != expectedPath || state.otherModifiedCount != 0 {
			return false, nil
		}
		if state.modified {
			return true, nil
		}
		contents, err := os.ReadFile(expectedPath)
		if err != nil {
			lastErr = err
			return false, nil
		}
		persisted = string(contents) == expectedContent
		return persisted, nil
	})
	if err != nil {
		t.Fatalf(
			"TextEdit document never became dirty or persisted the exact paste: state=%+v persisted=%t output=%q error=%v poll=%v",
			lastState,
			persisted,
			lastOutput,
			lastErr,
			err,
		)
	}
}

type textEditDocumentState struct {
	path               string
	otherModifiedCount int
	found              bool
	modified           bool
}

func getTextEditDocumentState(
	ctx context.Context,
	client pb.ExactMacClient,
	targetName string,
) (textEditDocumentState, string, error) {
	// Bound the server-side osascript child strictly below the caller's gRPC
	// context. Without an explicit timeout the server defaults to 30s while the
	// inter-app `tell application "TextEdit"` round-trip can block behind stale
	// window-server state from prior tests; the gRPC context then expires first,
	// orphaning work and yielding a DeadlineExceeded with no parsed state. A 2s
	// server timeout lets the server reap the child cleanly and return a real
	// result (or a precise error) within the verifier's budget. See DIRECTIVE L100
	// (repair every stale/environment-dependent test).
	resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: fmt.Sprintf(`tell application "TextEdit"
			set targetName to %q
			set foundTarget to false
			set targetPath to ""
			set targetModified to false
			set otherModifiedCount to 0
			repeat with documentItem in documents
				if (name of documentItem as text) is targetName then
					set foundTarget to true
					set targetPath to path of documentItem as text
					set targetModified to modified of documentItem
				else if modified of documentItem then
					set otherModifiedCount to otherModifiedCount + 1
				end if
			end repeat
			return (foundTarget as text) & "|" & targetPath & "|" & (targetModified as text) & "|" & (otherModifiedCount as text)
		end tell`, targetName),
		Timeout: durationpb.New(2 * time.Second),
	})
	if err != nil {
		return textEditDocumentState{}, "", err
	}
	output := strings.TrimSpace(resp.GetOutput())
	fields := strings.Split(output, "|")
	if len(fields) != 4 {
		return textEditDocumentState{}, output, fmt.Errorf("unexpected TextEdit state field count: %d", len(fields))
	}
	found, err := strconv.ParseBool(fields[0])
	if err != nil {
		return textEditDocumentState{}, output, fmt.Errorf("parse TextEdit found state: %w", err)
	}
	modified, err := strconv.ParseBool(fields[2])
	if err != nil {
		return textEditDocumentState{}, output, fmt.Errorf("parse TextEdit modified state: %w", err)
	}
	otherModifiedCount, err := strconv.Atoi(fields[3])
	if err != nil {
		return textEditDocumentState{}, output, fmt.Errorf("parse TextEdit unrelated modified count: %w", err)
	}
	return textEditDocumentState{
		path:               fields[1],
		found:              found,
		modified:           modified,
		otherModifiedCount: otherModifiedCount,
	}, output, nil
}

func pointInWindow(x, y float64, bounds *pb.Bounds) bool {
	return bounds != nil &&
		x >= bounds.X && x < bounds.X+bounds.Width &&
		y >= bounds.Y && y < bounds.Y+bounds.Height
}

func pointInRegion(x, y float64, region *pbtype.Region) bool {
	return region != nil &&
		x >= region.X && x < region.X+region.Width &&
		y >= region.Y && y < region.Y+region.Height
}

func elementPathEqual(left, right []int32) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
