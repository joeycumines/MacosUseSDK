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
	"strings"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pbtype "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// clickIntoTextArea finds a TextEdit document window and clicks into the
// text editing area (center, biased low) to ensure keyboard focus.
func clickIntoTextArea(t *testing.T, ctx context.Context, client pb.MacosUseClient, parent string) {
	t.Helper()

	err := PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: parent})
		if err != nil {
			return false, nil
		}
		for _, w := range resp.Windows {
			if w.Bounds != nil && w.Bounds.Height > 100 {
				clickX := w.Bounds.X + (w.Bounds.Width / 2)
				clickY := w.Bounds.Y + (w.Bounds.Height * 0.7)
				_, clickErr := client.CreateInput(ctx, &pb.CreateInputRequest{
					Parent: parent,
					Input: &pb.Input{
						Action: &pb.InputAction{
							InputType: &pb.InputAction_Click{
								Click: &pb.MouseClick{
									Position: &pbtype.Point{X: clickX, Y: clickY},
								},
							},
						},
					},
				})
				if clickErr != nil {
					return false, nil
				}
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Could not click into TextEdit text area: %v", err)
	}
}

// sendKeyboardInput sends a CreateInput request and returns the response.
func sendKeyboardInput(t *testing.T, ctx context.Context, client pb.MacosUseClient, parent string, action *pb.InputAction) *pb.Input {
	t.Helper()

	resp, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input: &pb.Input{
			Action: action,
		},
	})
	if err != nil {
		t.Fatalf("CreateInput gRPC error: %v", err)
	}
	return resp
}

// getTextEditContent reads the current text content from the front TextEdit
// document via AppleScript.
func getTextEditContent(t *testing.T, ctx context.Context, client pb.MacosUseClient) string {
	t.Helper()

	asResp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "TextEdit"
	if (count of documents) > 0 then
		return text of document 1
	else
		return ""
	end if
end tell`,
	})
	if err != nil {
		t.Logf("AppleScript text retrieval failed: %v", err)
		return ""
	}
	return strings.TrimSpace(asResp.GetOutput())
}

// setTextEditContent sets the text content of the front TextEdit document
// directly via AppleScript.
func setTextEditContent(t *testing.T, ctx context.Context, client pb.MacosUseClient, text string) {
	t.Helper()

	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: fmt.Sprintf(`tell application "TextEdit" to set text of front document to %q`, text),
	})
	if err != nil {
		t.Fatalf("Failed to set TextEdit document text: %v", err)
	}
}

// waitForTextEditContent polls until getTextEditContent satisfies pred.
func waitForTextEditContent(t *testing.T, ctx context.Context, client pb.MacosUseClient, pred func(string) bool) (string, error) {
	t.Helper()
	var content string
	err := PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		content = getTextEditContent(t, ctx, client)
		return pred(content), nil
	})
	return content, err
}

// killTextEdit force-kills all TextEdit processes for test isolation
// and configures TextEdit preferences to avoid modal dialogs that
// block AppleEvent handling. Also removes saved state to prevent
// window restoration on next launch.
func killTextEdit(t *testing.T) {
	t.Helper()
	_ = exec.Command("osascript", "-e",
		`tell application "TextEdit" to quit saving no`).Run()

	// Poll until TextEdit is no longer running (or force kill after timeout).
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if exec.Command("pgrep", "-x", "TextEdit").Run() != nil {
			break // Not running
		}
		time.Sleep(50 * time.Millisecond)
	}
	// Force kill any remaining TextEdit processes.
	_ = exec.Command("pkill", "-9", "TextEdit").Run()

	// CRITICAL: Disable the "Open Recent" dialog that blocks AppleEvents.
	// Without this, TextEdit shows a modal dialog on launch that prevents
	// all AppleScript communication (AppleEvent timed out error -1712).
	_ = exec.Command("defaults", "write", "com.apple.TextEdit",
		"NSShowAppCenterRecent", "-bool", "false").Run()
	_ = exec.Command("defaults", "write", "-g",
		"NSShowAppCenterRecent", "-bool", "false").Run()
	_ = exec.Command("defaults", "write", "com.apple.TextEdit",
		"NSQuitAlwaysKeepsWindows", "-bool", "false").Run()

	// Remove saved state so TextEdit doesn't restore previous documents.
	home, _ := os.UserHomeDir()
	if home != "" {
		savedStatePath := home + "/Library/Saved Application State/com.apple.TextEdit.savedState"
		_ = os.RemoveAll(savedStatePath)
	}

	// Poll to confirm TextEdit is fully terminated after SIGKILL.
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if exec.Command("pgrep", "-x", "TextEdit").Run() != nil {
			break // Not running
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// setupTextEditWithDocument kills TextEdit, starts it fresh via the server,
// closes any restored documents, creates a new document, sets content,
// and verifies the content is present. Returns the application resource.
func setupTextEditWithDocument(
	t *testing.T, ctx context.Context,
	client pb.MacosUseClient, opsClient longrunningpb.OperationsClient,
	text string,
) *pb.Application {
	t.Helper()

	killTextEdit(t)

	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.TextEdit")

	// Close ALL existing documents (restored from saved state).
	// This ensures a clean slate.
	for i := 0; i < 5; i++ {
		_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "TextEdit"
	if (count of documents) > 0 then
		close front document saving no
		return "closed"
	else
		return "none"
	end if
end tell`,
		})
		if err != nil {
			break
		}
	}

	// Create a fresh document.
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "TextEdit" to make new document`,
	})
	if err != nil {
		t.Fatalf("Failed to create TextEdit document: %v", err)
	}

	// Activate TextEdit and wait until frontmost.
	_, err = client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "TextEdit" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate TextEdit: %v", err)
	}
	err = PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil
		}
		return strings.TrimSpace(resp.GetOutput()) == "TextEdit", nil
	})
	if err != nil {
		t.Logf("Warning: TextEdit may not be frontmost: %v", err)
	}

	// Wait for a document window to appear.
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, nil
		}
		for _, w := range resp.Windows {
			if w.Bounds != nil && w.Bounds.Height > 100 {
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("TextEdit document window never appeared: %v", err)
	}

	// Set content via AppleScript (targets front document).
	setTextEditContent(t, ctx, client, text)

	// Verify content was set.
	got, err := waitForTextEditContent(t, ctx, client, func(s string) bool {
		return strings.Contains(s, text)
	})
	if err != nil {
		t.Fatalf("Expected text %q in TextEdit, got %q: %v", text, got, err)
	}

	// Click into the text area to give it keyboard focus,
	// then Cmd+Down to ensure the cursor is placed within the text view
	// (establishing NSTextView as first responder).
	clickIntoTextArea(t, ctx, client, app.Name)
	time.Sleep(100 * time.Millisecond)

	return app
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
	app := setupTextEditWithDocument(t, ctx, client, opsClient, testText)
	defer CleanupApplication(t, ctx, client, app.Name)

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
	time.Sleep(150 * time.Millisecond)

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
	time.Sleep(150 * time.Millisecond)

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
	time.Sleep(100 * time.Millisecond)

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
		finalText = getTextEditContent(t, ctx, client)
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
	app := setupTextEditWithDocument(t, ctx, client, opsClient, testText)
	defer CleanupApplication(t, ctx, client, app.Name)

	// Clear clipboard first.
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `set the clipboard to ""`,
	})
	if err != nil {
		t.Fatalf("Failed to clear clipboard: %v", err)
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
	time.Sleep(100 * time.Millisecond)

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
	time.Sleep(100 * time.Millisecond)

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

	app := setupTextEditWithDocument(t, ctx, client, opsClient, "X")
	defer CleanupApplication(t, ctx, client, app.Name)

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

	// Verify additional character was inserted.
	var content string
	err := PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		content = getTextEditContent(t, ctx, client)
		return len(content) > 1, nil
	})
	if err != nil {
		t.Fatalf("Option+P did not produce additional character: content=%q: %v", content, err)
	}

	t.Logf("Option+P produced character: content=%q (was %q)", content, "X")
	t.Log("Option special character test passed")
}
