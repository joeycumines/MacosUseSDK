// Copyright 2025 Joseph Cumines
//
// Keyboard modifier combination integration test using TextEdit.
// Tests various keyboard modifier combinations (Cmd+A, Cmd+C, Cmd+Shift+Arrow, etc.)
// and verifies the expected text state via AppleScript text retrieval.
// Task: T076

package integration

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pbtype "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// keyboardTextEditFixture owns one uniquely named TextEdit file, window, and
// AX text area. Physical input is admitted only after exact-window focus and
// exact-element AX focus have both converged.
type keyboardTextEditFixture struct {
	application *pb.Application
	window      *pb.Window
	textArea    *pb.Element
	display     *pb.Display
	filePath    string
	elementPath []int32
}

// setupTextEditWithDocument opens a uniquely named file instead of relying on
// TextEdit's global front document or AppleScript document creation.
func setupTextEditWithDocument(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	opsClient longrunningpb.OperationsClient,
	text string,
) *keyboardTextEditFixture {
	t.Helper()

	killTextEdit(t)
	fileName := fmt.Sprintf("keyboard-modifier-%d.txt", time.Now().UnixNano())
	filePath := filepath.Join(t.TempDir(), fileName)
	if err := os.WriteFile(filePath, []byte(text), 0o600); err != nil {
		t.Fatalf("create owned TextEdit file: %v", err)
	}
	openCommand := exec.Command("open", "-a", "TextEdit", filePath)
	if output, err := openCommand.CombinedOutput(); err != nil {
		t.Fatalf("open owned TextEdit file: %v output=%q", err, output)
	}

	app := OpenApplicationObserved(t, ctx, client, "com.apple.TextEdit")
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

	focusedWindow, err := client.FocusWindow(ctx, &pb.FocusWindowRequest{Name: targetWindow.Name})
	if err != nil {
		t.Fatalf("focus owned TextEdit window: %v", err)
	}
	targetWindow = focusedWindow
	focusWindowCtx, cancelFocusWindow := context.WithTimeout(ctx, 5*time.Second)
	defer cancelFocusWindow()
	if err := PollUntilContext(focusWindowCtx, 100*time.Millisecond, func() (bool, error) {
		state, err := client.GetWindowState(focusWindowCtx, &pb.GetWindowStateRequest{Name: targetWindow.Name + "/state"})
		return err == nil && state.Focused, nil
	}); err != nil {
		t.Fatalf("owned TextEdit window never became focused: %v", err)
	}

	traversalCtx, cancelTraversal := context.WithTimeout(ctx, 10*time.Second)
	defer cancelTraversal()
	var textArea *pb.Element
	var lastTextAreaCandidates []string
	if err := PollUntilContext(traversalCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(traversalCtx, &pb.TraverseAccessibilityRequest{
			Name: app.Name, VisibleOnly: true,
		})
		if err != nil {
			return false, nil
		}
		lastTextAreaCandidates = lastTextAreaCandidates[:0]
		for _, element := range response.Elements {
			if element == nil || !isTextEditTextArea(element.Role) {
				continue
			}
			_, intersectsOwnedWindow := visibleElementPointInWindow(element, targetWindow.GetBounds())
			lastTextAreaCandidates = append(lastTextAreaCandidates, fmt.Sprintf(
				"role=%q path=%v bytes=%d prefix=%q suffix=%q geometry=(%.1f,%.1f %.1fx%.1f) intersects_window=%t",
				element.GetRole(),
				element.GetPath(),
				len(element.GetText()),
				previewDiagnosticText(element.GetText(), true),
				previewDiagnosticText(element.GetText(), false),
				element.GetX(),
				element.GetY(),
				element.GetWidth(),
				element.GetHeight(),
				intersectsOwnedWindow,
			))
			if element.X == nil || element.Y == nil || element.Width == nil || element.Height == nil ||
				element.GetWidth() <= 0 || element.GetHeight() <= 0 ||
				!strings.Contains(element.GetText(), text) {
				continue
			}
			if intersectsOwnedWindow {
				textArea = element
				return true, nil
			}
		}
		return false, nil
	}); err != nil {
		t.Fatalf(
			"owned TextEdit text area never exposed bytes=%d prefix=%q suffix=%q; candidates=%v: %v",
			len(text),
			previewDiagnosticText(text, true),
			previewDiagnosticText(text, false),
			lastTextAreaCandidates,
			err,
		)
	}

	visiblePoint, ok := visibleElementPointInWindow(textArea, targetWindow.GetBounds())
	if !ok {
		t.Fatalf(
			"owned TextEdit text area no longer intersects window text_area=%+v window=%+v",
			textArea,
			targetWindow.GetBounds(),
		)
	}
	displays, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("list displays before owned TextEdit click: %v", err)
	}
	var targetDisplay *pb.Display
	for _, display := range displays.Displays {
		if pointInRegion(visiblePoint.GetX(), visiblePoint.GetY(), display.GetVisibleFrame()) {
			if targetDisplay != nil {
				t.Fatalf(
					"owned TextEdit text area center (%.1f,%.1f) belongs to multiple visible displays",
					visiblePoint.GetX(),
					visiblePoint.GetY(),
				)
			}
			targetDisplay = display
		}
	}
	if targetDisplay == nil {
		t.Fatalf(
			"owned TextEdit text area visible point (%.1f,%.1f) is outside every visible display",
			visiblePoint.GetX(),
			visiblePoint.GetY(),
		)
	}

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
				InputType: &pb.InputAction_Click{
					Click: &pb.MouseClick{
						Position:   visiblePoint,
						ClickCount: &clickCount,
					},
				},
			},
		),
		2,
		"focus owned TextEdit text area",
	)

	path := append([]int32(nil), textArea.Path...)
	focusElementCtx, cancelFocusElement := context.WithTimeout(ctx, 5*time.Second)
	defer cancelFocusElement()
	if err := PollUntilContext(focusElementCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(focusElementCtx, &pb.TraverseAccessibilityRequest{
			Name: app.Name, VisibleOnly: true,
		})
		if err != nil {
			return false, nil
		}
		for _, element := range response.Elements {
			if element != nil && isTextEditTextArea(element.Role) && element.GetFocused() &&
				elementPathEqual(element.Path, path) && strings.Contains(element.GetText(), text) {
				return true, nil
			}
		}
		return false, nil
	}); err != nil {
		t.Fatalf("owned TextEdit text area never acquired AX focus: %v", err)
	}

	return &keyboardTextEditFixture{
		application: app,
		window:      targetWindow,
		textArea:    textArea,
		display:     targetDisplay,
		filePath:    filePath,
		elementPath: path,
	}
}

func previewDiagnosticText(value string, fromStart bool) string {
	const limit = 80
	characters := []rune(value)
	if len(characters) <= limit {
		return value
	}
	if fromStart {
		return string(characters[:limit])
	}
	return string(characters[len(characters)-limit:])
}

func visibleElementPointInWindow(element *pb.Element, bounds *pb.Bounds) (*pbtype.Point, bool) {
	if element == nil || bounds == nil ||
		element.X == nil || element.Y == nil ||
		element.Width == nil || element.Height == nil ||
		element.GetWidth() <= 0 || element.GetHeight() <= 0 ||
		bounds.GetWidth() <= 0 || bounds.GetHeight() <= 0 {
		return nil, false
	}
	left := max(element.GetX(), bounds.GetX())
	top := max(element.GetY(), bounds.GetY())
	right := min(element.GetX()+element.GetWidth(), bounds.GetX()+bounds.GetWidth())
	bottom := min(element.GetY()+element.GetHeight(), bounds.GetY()+bounds.GetHeight())
	if right <= left || bottom <= top {
		return nil, false
	}
	return &pbtype.Point{
		X: left + (right-left)/2,
		Y: top + (bottom-top)/2,
	}, true
}

func getTextEditContent(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	fixture *keyboardTextEditFixture,
) string {
	t.Helper()
	response, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
		Name: fixture.application.Name, VisibleOnly: true,
	})
	if err != nil {
		return ""
	}
	if element := resolveOwnedTextEditTextArea(response.Elements, fixture); element != nil {
		return strings.TrimSpace(element.GetText())
	}
	return ""
}

func cleanupKeyboardApplication(t *testing.T, client pb.MacosUseClient, app *pb.Application) {
	t.Helper()
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cleanupApplication(t, cleanupCtx, client, app)
}

// sendKeyboardInput sends a CreateInput request and returns the response.
func sendKeyboardInput(t *testing.T, ctx context.Context, client pb.MacosUseClient, parent string, action *pb.InputAction) *pb.Input {
	t.Helper()
	return createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			parent,
			applicationInputTarget(parent),
			action,
		),
		2,
		"send keyboard input",
	)
}

// killTextEdit force-kills the explicitly authorized golden application and
// waits for exact process disappearance without AppleScript or fixed sleeps.
func killTextEdit(t *testing.T) {
	t.Helper()
	_ = exec.Command("pkill", "-9", "TextEdit").Run()
	waitCtx, cancelWait := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancelWait()
	if err := PollUntilContext(waitCtx, 50*time.Millisecond, func() (bool, error) {
		return exec.Command("pgrep", "-x", "TextEdit").Run() != nil, nil
	}); err != nil {
		t.Fatalf("TextEdit processes did not terminate: %v", err)
	}

	_ = exec.Command("defaults", "write", "com.apple.TextEdit", "NSShowAppCenterRecent", "-bool", "false").Run()
	_ = exec.Command("defaults", "write", "-g", "NSShowAppCenterRecent", "-bool", "false").Run()
	_ = exec.Command("defaults", "write", "com.apple.TextEdit", "NSQuitAlwaysKeepsWindows", "-bool", "false").Run()

	home, _ := os.UserHomeDir()
	if home != "" {
		_ = os.RemoveAll(filepath.Join(home, "Library", "Saved Application State", "com.apple.TextEdit.savedState"))
	}
}

// TestKeyboardModifiers_SelectAllCopyPaste verifies Cmd+A, Cmd+C, Cmd+Down,
// Cmd+V via CGEvent key presses. Verifies clipboard content changes and
// document text growth.
func TestKeyboardModifiers_SelectAllCopyPaste(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	testText := "Hello Modifier Test"
	fixture := setupTextEditWithDocument(t, ctx, client, opsClient, testText)
	app := fixture.application
	defer cleanupKeyboardApplication(t, client, app)
	restoreClipboard := preserveClipboard(t, ctx, client)
	defer restoreClipboard()

	// Step 0: Cmd+Down to place cursor into the text view.
	// This is critical: even though setupTextEditWithDocument clicks into the
	// text area, the text NSTextView may not have first-responder status.
	// Cmd+Down forces the cursor into the document text, establishing
	// first-responder on the text view so subsequent Cmd+A works.
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "down",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			},
		},
	})
	t.Log("Cmd+Down (establish cursor in text view) sent")
	// Inter-keystroke gap: CGEvent posts are asynchronous; the window server
	// needs time to process each event before the next arrives. There is no
	// observable AX/API state to poll between keystrokes (text selection is
	// internal to NSTextView). All *assertions* below use PollUntilContext.

	// Step 1: Cmd+A (select all).
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "a",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			},
		},
	})
	t.Log("Cmd+A (select all) sent")

	// Step 2: Cmd+C (copy).
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "c",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			},
		},
	})
	t.Log("Cmd+C (copy) sent")

	// Step 3: Verify clipboard contains the test text.
	var clipText string
	err := PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		clipResp, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
		if err != nil {
			return false, nil
		}
		clipText = clipResp.GetContent().GetText()
		return strings.Contains(clipText, testText), nil
	})
	if err != nil {
		t.Fatalf("Clipboard did not contain %q after Cmd+A, Cmd+C; got %q: %v",
			testText, clipText, err)
	}
	t.Logf("Clipboard after Cmd+A + Cmd+C: %q", clipText)

	// Step 4: Cmd+Down (move to end, deselects).
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "down",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			},
		},
	})
	t.Log("Cmd+Down (move to end) sent")

	// Step 5: Cmd+V (paste at end).
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "v",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			},
		},
	})
	t.Log("Cmd+V (paste) sent")

	// Step 6: Verify text was duplicated (document text grew).
	var finalText string
	err = PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		finalText = getTextEditContent(t, ctx, client, fixture)
		return strings.Count(finalText, testText) >= 2, nil
	})
	if err != nil {
		t.Fatalf("Text was not duplicated after paste: got %q: %v", finalText, err)
	}

	t.Logf("Text after paste: %q (testText appears %d times)",
		finalText, strings.Count(finalText, testText))
	t.Log("Keyboard modifier test (select all + copy + paste) passed")
}

// TestKeyboardModifiers_MultipleModifiers verifies combining multiple modifiers
// in a single KeyPress (Cmd+Shift+Left for line selection) and Cmd+C to copy.
// Verifies clipboard content after selection.
func TestKeyboardModifiers_MultipleModifiers(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	testText := "Alpha Beta Gamma"
	fixture := setupTextEditWithDocument(t, ctx, client, opsClient, testText)
	app := fixture.application
	defer cleanupKeyboardApplication(t, client, app)
	restoreClipboard := preserveClipboard(t, ctx, client)
	defer restoreClipboard()

	// Clear clipboard through the public API before observing the copy delta.
	_, err := client.ClearClipboard(ctx, &pb.ClearClipboardRequest{})
	if err != nil {
		t.Fatalf("ClearClipboard failed: %v", err)
	}

	// Move cursor to end of text.
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "down",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			},
		},
	})

	// Cmd+Shift+Left: Select from cursor (end of text) to beginning of line.
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key: "left",
				Modifiers: []pb.KeyPress_Modifier{
					pb.KeyPress_MODIFIER_COMMAND,
					pb.KeyPress_MODIFIER_SHIFT,
				},
			},
		},
	})
	t.Log("Cmd+Shift+Left (select to beginning) sent")

	// Cmd+C to copy the selection.
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "c",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			},
		},
	})
	t.Log("Cmd+C (copy) sent")

	// Verify clipboard contains the selected text.
	var clipText string
	err = PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		clipResp, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
		if err != nil {
			return false, nil
		}
		clipText = clipResp.GetContent().GetText()
		return clipText == testText, nil
	})
	if err != nil {
		t.Fatalf("Clipboard did not contain expected text %q, got %q: %v",
			testText, clipText, err)
	}
	t.Logf("Clipboard after Cmd+Shift+Left + Cmd+C: %q", clipText)

	t.Log("Multi-modifier keyboard test passed")
}

// TestKeyboardModifiers_OptionSpecialCharacter verifies Option+key produces
// a special character. On US keyboard layout, Option+P produces pi (π).
// Uses TextEdit to type and verify a character was inserted.
func TestKeyboardModifiers_OptionSpecialCharacter(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	fixture := setupTextEditWithDocument(t, ctx, client, opsClient, "X")
	app := fixture.application
	defer cleanupKeyboardApplication(t, client, app)

	// Move cursor to end.
	sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "down",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			},
		},
	})

	// Press Option+P which produces π on US keyboard layout.
	optPResp := sendKeyboardInput(t, ctx, client, app.Name, &pb.InputAction{
		InputType: &pb.InputAction_PressKey{
			PressKey: &pb.KeyPress{
				Key:       "p",
				Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_OPTION},
			},
		},
	})
	if optPResp.State != pb.Input_STATE_COMPLETED {
		t.Fatalf("Option+P failed: state=%v error=%s", optPResp.State, optPResp.Error)
	}
	t.Log("Option+P completed")

	// Verify Option modified the key rather than merely inserting an unmodified
	// "p". The exact glyph is input-layout dependent (π on the active US layout).
	var content string
	err := PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		content = getTextEditContent(t, ctx, client, fixture)
		runes := []rune(content)
		return len(runes) == 2 && runes[0] == 'X' && runes[1] != 'p' && runes[1] != 'P', nil
	})
	if err != nil {
		t.Fatalf("Option+P did not produce a modified character after X: content=%q: %v", content, err)
	}

	t.Logf("Option+P produced character: content=%q (was %q)", content, "X")
	t.Log("Option special character test passed")
}
