package integration

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pbtype "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
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

	// AGGRESSIVE CLEANUP: Kill any existing TextEdit process first.
	// This prevents inheriting a stale/hung TextEdit from a previous failed test.
	_ = exec.Command("killall", "-9", "TextEdit").Run()
	time.Sleep(100 * time.Millisecond) // Brief pause for process termination

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Ensure TextEdit isn't already tracked from previous runs
	CleanupApplication(t, ctx, client, "/Applications/TextEdit.app")

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
		Content:       &pb.ClipboardContent{Content: &pb.ClipboardContent_Text{Text: pasteText}},
		ClearExisting: true,
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
	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.TextEdit")
	defer cleanupApplication(t, ctx, client, app)

	// Wait until TextEdit has at least one DOCUMENT window (not menu bar)
	// TextEdit shows the menu bar as a separate window with ~33px height.
	// We need a window with reasonable height (> 100px) to be a document window.
	windowCtx, windowCancel := context.WithTimeout(ctx, 3*time.Second)
	defer windowCancel()

	var targetWindow *pb.Window
	err = PollUntilContext(windowCtx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, nil
		}
		// Find a window that looks like a document window (height > 100px)
		// Menu bar windows are typically 33px tall
		for _, w := range resp.Windows {
			if w == nil || w.Bounds == nil {
				continue
			}
			// Document windows should be at least 100px tall
			if w.Bounds.Width > 0 && w.Bounds.Height > 100 {
				targetWindow = w
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("TextEdit window never appeared: %v", err)
	}

	// Compute click point in the text editing area
	// Note: Window bounds use global display coordinates (top-left origin at main display top-left).
	// CGEvent also uses the same coordinate system, so no conversion is needed.
	//
	// TextEdit layout (approximate):
	// - Title bar: ~28px
	// - Format bar/toolbar: ~40px
	// - Text editing area: starts ~70px from top
	//
	// We click lower in the window (70% down) to reliably hit the text area,
	// not the title bar or toolbar.
	bx := targetWindow.Bounds.X
	by := targetWindow.Bounds.Y
	bw := targetWindow.Bounds.Width
	bh := targetWindow.Bounds.Height
	t.Logf("Window bounds: x=%.1f y=%.1f w=%.1f h=%.1f", bx, by, bw, bh)
	centerX := bx + (bw / 2.0)
	// Click 70% down the window to ensure we're in the text editing area
	textAreaY := by + (bh * 0.7)
	t.Logf("Clicking in text area: (%.1f, %.1f)", centerX, textAreaY)

	// Click to focus editing area
	clickInput, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: app.Name,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_Click{
					Click: &pb.MouseClick{
						Position:   &pbtype.Point{X: centerX, Y: textAreaY},
						ClickCount: int32(1),
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("CreateInput click failed: %v", err)
	}

	// Wait for click completion
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		st, err := client.GetInput(ctx, &pb.GetInputRequest{Name: clickInput.Name})
		if err != nil {
			return false, nil
		}
		return st.State == pb.Input_STATE_COMPLETED || st.State == pb.Input_STATE_FAILED, nil
	})
	if err != nil {
		t.Fatalf("click input did not complete: %v", err)
	}

	clickStatus, _ := client.GetInput(ctx, &pb.GetInputRequest{Name: clickInput.Name})
	t.Logf("Click status: %v", clickStatus.State)
	if clickStatus.State == pb.Input_STATE_FAILED {
		t.Fatalf("Click failed")
	}

	// CRITICAL: Use AppleScript to ensure TextEdit is activated and frontmost.
	// CGEvent key events go to the frontmost application, and clicking may not
	// reliably bring TextEdit to the front if another app has focus.
	t.Log("Activating TextEdit via AppleScript...")
	_, err = client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "TextEdit" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate TextEdit: %v", err)
	}

	// Poll until TextEdit is frontmost (avoids time.Sleep)
	activationCtx, cancelActivation := context.WithTimeout(ctx, 2*time.Second)
	defer cancelActivation()
	err = PollUntilContext(activationCtx, 50*time.Millisecond, func() (bool, error) {
		resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil // Retry
		}
		// Result should be "TextEdit"
		return resp.GetOutput() == "TextEdit", nil
	})
	if err != nil {
		t.Logf("Warning: could not confirm TextEdit is frontmost: %v (proceeding anyway)", err)
	}

	// Press Cmd+A to select all (selects the placeholder text so paste will replace it)
	selectAllInput, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: app.Name,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_PressKey{
					PressKey: &pb.KeyPress{
						Key:       "a",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("CreateInput select-all failed: %v", err)
	}

	// Wait for select-all to finish
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		st, err := client.GetInput(ctx, &pb.GetInputRequest{Name: selectAllInput.Name})
		if err != nil {
			return false, nil
		}
		return st.State == pb.Input_STATE_COMPLETED || st.State == pb.Input_STATE_FAILED, nil
	})
	if err != nil {
		t.Fatalf("select-all input did not complete: %v", err)
	}

	// Press Cmd+V to paste (replaces selected placeholder text)
	pasteInput, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: app.Name,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_PressKey{
					PressKey: &pb.KeyPress{
						Key:       "v",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("CreateInput paste failed: %v", err)
	}

	// Wait for paste to finish
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		st, err := client.GetInput(ctx, &pb.GetInputRequest{Name: pasteInput.Name})
		if err != nil {
			return false, nil
		}
		return st.State == pb.Input_STATE_COMPLETED || st.State == pb.Input_STATE_FAILED, nil
	})
	if err != nil {
		t.Fatalf("paste input did not complete: %v", err)
	}

	// CMD+S to save
	saveInput, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: app.Name,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_PressKey{
					PressKey: &pb.KeyPress{
						Key:       "s",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("CreateInput save failed: %v", err)
	}

	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		st, err := client.GetInput(ctx, &pb.GetInputRequest{Name: saveInput.Name})
		if err != nil {
			return false, nil
		}
		return st.State == pb.Input_STATE_COMPLETED || st.State == pb.Input_STATE_FAILED, nil
	})
	if err != nil {
		t.Fatalf("save input did not complete: %v", err)
	}

	// Verify clipboard still contains our text
	clipCheck, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil {
		t.Fatalf("Failed to verify clipboard: %v", err)
	}
	t.Logf("Clipboard after paste contains: %q (type=%v)", clipCheck.Content.GetText(), clipCheck.Content.Type)

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
