// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"os"
	"sync"
	"testing"
	"time"

	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/protobuf/proto"
)

type physicalInputRecord struct {
	parent string
	input  *pb.Input
}

type ownedDragPoint struct {
	x float64
	y float64
}

type ownedTextEditGeometry struct {
	window          *pb.Window
	textArea        *pb.Element
	visibleTextArea ownedRectangle
	displays        []*pb.Display
}

type ownedRectangle struct {
	x      float64
	y      float64
	width  float64
	height float64
}

type ownedTextEditDragCall struct {
	toolName      string
	arguments     map[string]any
	expected      *pb.InputAction
	maximumEvents int32
	path          []ownedDragPoint
}

type ownedCalculatorDisplay struct {
	path []int32
	role string
}

func TestPhysicalInputTruth_ProductionRoutes(t *testing.T) {
	if external := os.Getenv("INTEGRATION_SERVER_ADDR"); external != "" {
		t.Fatalf(
			"physical truth requires one fixture-owned release Swift server, got INTEGRATION_SERVER_ADDR=%q",
			external,
		)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	serverCommand, serverAddress := startServer(t, ctx)
	defer cleanupServer(t, serverCommand, serverAddress)
	connection := connectToServer(t, ctx, serverAddress)
	defer connection.Close()
	client := pb.NewExactMacClient(connection)

	originalClipboard := requireClipboardSnapshot(t, ctx, client)
	var restoreClipboardOnce sync.Once
	restoreClipboard := func() {
		restoreClipboardOnce.Do(func() {
			restoreClipboardSnapshot(t, client, originalClipboard)
		})
	}
	defer restoreClipboard()
	originalCursor, displays := requireCursorSnapshot(t, ctx, client)
	var restoreCursorOnce sync.Once
	restoreCursor := func() {
		restoreCursorOnce.Do(func() {
			restoreCursorSnapshot(t, client, originalCursor)
		})
	}
	defer restoreCursor()

	httpCommand, baseURL, cleanupHTTP := startMCPTestServer(t, ctx, serverAddress)
	defer cleanupHTTP()
	stdioCommand, stdioInput, stdioOutput, cleanupStdio := startMCPStdioProcess(
		t,
		ctx,
		serverAddress,
	)
	defer cleanupStdio()

	httpClient := &http.Client{Timeout: 30 * time.Second}
	var closeHTTPIdleOnce sync.Once
	closeHTTPIdle := func() {
		closeHTTPIdleOnce.Do(httpClient.CloseIdleConnections)
	}
	defer closeHTTPIdle()
	httpSession := initializeHTTPSession(t, ctx, httpClient, baseURL, 1)
	initialized := sendSessionMCP(
		t,
		ctx,
		httpClient,
		baseURL,
		http.MethodPost,
		httpSession,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
	)
	if initialized.Err != nil || initialized.Status != http.StatusAccepted ||
		len(initialized.Body) != 0 {
		t.Fatalf(
			"HTTP initialized status=%d body=%q error=%v",
			initialized.Status,
			initialized.Body,
			initialized.Err,
		)
	}
	stdioInitialize, err := sendStdioRequest(
		ctx,
		stdioInput,
		stdioOutput,
		validMCPInitializeRequest(2),
	)
	if err != nil || stdioInitialize == nil || stdioInitialize.Error != nil {
		t.Fatalf("stdio initialize response=%+v error=%v", stdioInitialize, err)
	}
	if err := writeStdioMessage(stdioInput, map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}); err != nil {
		t.Fatalf("stdio initialized notification: %v", err)
	}

	seenNames := make(map[string]struct{})
	var records []physicalInputRecord
	record := func(parent string, input *pb.Input) {
		t.Helper()
		if _, duplicate := seenNames[input.GetName()]; duplicate {
			t.Fatalf("physical matrix reused Input identity %q", input.GetName())
		}
		seenNames[input.GetName()] = struct{}{}
		records = append(records, physicalInputRecord{
			parent: parent,
			input:  proto.Clone(input).(*pb.Input),
		})
	}

	// Calculator: exact coordinate click and double-click must alter the exact
	// owned display rather than merely return an OK transport status.
	calculator := openCalculator(t, ctx, client)
	var cleanupCalculatorOnce sync.Once
	cleanupCalculator := func() {
		cleanupCalculatorOnce.Do(func() {
			cleanupKeyboardApplication(t, client, calculator)
		})
	}
	defer cleanupCalculator()
	calculatorWindow := requireOwnedApplicationWindow(t, ctx, client, calculator)
	switchCalculatorToBasicWithGeneratedInput(t, ctx, client, calculator, calculatorWindow)
	calculatorWindow = requireOwnedApplicationWindow(t, ctx, client, calculator)
	clearCalculatorWithGeneratedInput(t, ctx, client, calculator, calculatorWindow)
	calculatorDisplay := requireCalculatorPhysicalValue(t, ctx, client, calculator, nil, "0")

	buttonSeven := requireCalculatorButtonElement(
		t,
		ctx,
		client,
		calculator,
		calculatorWindow,
		displays,
		"7",
	)
	sevenPosition := elementCenter(buttonSeven)
	clickCount := int32(1)
	clickAction := &pb.InputAction{
		InputType: &pb.InputAction_MouseClick{MouseClick: &pb.MouseClick{
			Position:   sevenPosition,
			ClickType:  pb.MouseClick_CLICK_TYPE_LEFT.Enum(),
			ClickCount: &clickCount,
		}},
	}
	clickParent := calculator.GetName()
	clickTarget := windowInputTarget(calculatorWindow.GetName())
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			clickParent,
			clickTarget,
			&pb.InputAction{
				InputType: &pb.InputAction_MouseMove{
					MouseMove: &pb.MouseMove{Position: proto.Clone(sevenPosition).(*typepb.Point)},
				},
			},
		),
		1,
		"position cursor over owned Calculator button",
	)
	positionedCursor, err := client.CaptureCursorPosition(
		ctx,
		&pb.CaptureCursorPositionRequest{},
	)
	if err != nil ||
		math.Abs(positionedCursor.GetX()-sevenPosition.GetX()) > 1 ||
		math.Abs(positionedCursor.GetY()-sevenPosition.GetY()) > 1 {
		t.Fatalf(
			"owned Calculator cursor position=%+v error=%v, want=%+v",
			positionedCursor,
			err,
			sevenPosition,
		)
	}
	clickBefore := listInputSnapshot(t, ctx, client, clickParent)
	clickResult := callPhysicalHTTP(
		t,
		ctx,
		httpClient,
		baseURL,
		httpSession,
		10,
		"click",
		map[string]any{
			"target": calculatorWindow.GetName(),
			"x":      sevenPosition.GetX(),
			"y":      sevenPosition.GetY(),
		},
	)
	clickInput := requireCompletedMCPInput(
		t,
		ctx,
		client,
		clickParent,
		clickBefore,
		clickTarget,
		clickAction,
		2,
		clickResult,
	)
	record(clickParent, clickInput)
	requireCalculatorPhysicalValue(t, ctx, client, calculator, calculatorDisplay, "7")

	clearCalculatorWithGeneratedInput(t, ctx, client, calculator, calculatorWindow)
	requireCalculatorPhysicalValue(t, ctx, client, calculator, calculatorDisplay, "0")
	buttonEight := requireCalculatorButtonElement(
		t,
		ctx,
		client,
		calculator,
		calculatorWindow,
		displays,
		"8",
	)
	eightPosition := elementCenter(buttonEight)
	doubleCount := int32(2)
	doubleAction := &pb.InputAction{
		InputType: &pb.InputAction_MouseClick{MouseClick: &pb.MouseClick{
			Position:   eightPosition,
			ClickType:  pb.MouseClick_CLICK_TYPE_LEFT.Enum(),
			ClickCount: &doubleCount,
		}},
	}
	doubleBefore := listInputSnapshot(t, ctx, client, clickParent)
	doubleResult := callPhysicalStdio(
		t,
		ctx,
		stdioInput,
		stdioOutput,
		11,
		"double_click",
		map[string]any{
			"target": calculatorWindow.GetName(),
			"x":      eightPosition.GetX(),
			"y":      eightPosition.GetY(),
		},
	)
	doubleInput := requireCompletedMCPInput(
		t,
		ctx,
		client,
		clickParent,
		doubleBefore,
		clickTarget,
		doubleAction,
		4,
		doubleResult,
	)
	record(clickParent, doubleInput)
	requireCalculatorPhysicalValue(t, ctx, client, calculator, calculatorDisplay, "88")
	cleanupCalculator()
	requireWindowGone(t, ctx, client, calculatorWindow.GetName())

	// TextEdit: retain a long owned document so text, selection, scrolling,
	// completed drag, and cancellation all use the same exact window.
	document := physicalTruthDocument()
	textFixture := setupTextEditWithDocument(t, ctx, client, nil, document)
	var cleanupTextEditOnce sync.Once
	cleanupTextEdit := func() {
		cleanupTextEditOnce.Do(func() {
			cleanupKeyboardApplication(t, client, textFixture.application)
		})
	}
	defer cleanupTextEdit()
	textParent := textFixture.application.GetName()
	textTarget := windowInputTarget(textFixture.window.GetName())

	moveCaretToDocumentEnd(t, ctx, client, textFixture)
	typeTextBefore := requireCurrentTextEditRawContent(t, ctx, client, textFixture)
	unicodeSuffix := "\nλ界🙂"
	typeDelay := 0.01
	typeAction := &pb.InputAction{
		InputType: &pb.InputAction_TextInput{TextInput: &pb.TextInput{
			Text:      unicodeSuffix,
			CharDelay: typeDelay,
		}},
	}
	typeBefore := listInputSnapshot(t, ctx, client, textParent)
	typeResult := callPhysicalHTTP(
		t,
		ctx,
		httpClient,
		baseURL,
		httpSession,
		20,
		"type",
		map[string]any{
			"target":     textFixture.window.GetName(),
			"text":       unicodeSuffix,
			"char_delay": typeDelay,
		},
	)
	typeInput := requireCompletedMCPInput(
		t,
		ctx,
		client,
		textParent,
		typeBefore,
		textTarget,
		typeAction,
		8,
		typeResult,
	)
	record(textParent, typeInput)
	fullDocument := typeTextBefore + unicodeSuffix
	requireTextEditRawContent(t, ctx, client, textFixture, fullDocument)

	selectAllAction := &pb.InputAction{
		InputType: &pb.InputAction_KeyPress{KeyPress: &pb.KeyPress{
			Key:       "a",
			Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
		}},
	}
	selectAllBefore := listInputSnapshot(t, ctx, client, textParent)
	selectAllResult := callPhysicalStdio(
		t,
		ctx,
		stdioInput,
		stdioOutput,
		21,
		"keypress",
		map[string]any{
			"target": textFixture.window.GetName(),
			"keys":   []any{"meta", "a"},
		},
	)
	selectAllInput := requireCompletedMCPInput(
		t,
		ctx,
		client,
		textParent,
		selectAllBefore,
		textTarget,
		selectAllAction,
		2,
		selectAllResult,
	)
	record(textParent, selectAllInput)
	requireWholeDocumentSelectionAndUndo(t, ctx, client, textFixture, fullDocument)

	moveCaretToDocumentStart(t, ctx, client, textFixture)
	scrollBefore := requireTextEditVerticalScroll(t, ctx, client, textFixture)
	geometry := requireCurrentOwnedTextEditGeometry(t, ctx, client, textFixture)
	scrollPoint := &typepb.Point{
		X: geometry.visibleTextArea.x + geometry.visibleTextArea.width/2,
		Y: geometry.visibleTextArea.y + geometry.visibleTextArea.height/2,
	}
	scrollDelta := 12.0
	scrollDuration := 0.4
	scrollAction := &pb.InputAction{
		InputType: &pb.InputAction_ScrollAction{ScrollAction: &pb.Scroll{
			Position: scrollPoint,
			Vertical: -scrollDelta,
			Duration: scrollDuration,
		}},
	}
	scrollInputBefore := listInputSnapshot(t, ctx, client, textParent)
	scrollResult := callPhysicalHTTP(
		t,
		ctx,
		httpClient,
		baseURL,
		httpSession,
		30,
		"scroll",
		map[string]any{
			"target":   textFixture.window.GetName(),
			"x":        scrollPoint.GetX(),
			"y":        scrollPoint.GetY(),
			"scroll_y": scrollDelta,
			"duration": scrollDuration,
		},
	)
	scrollInput := requireCompletedMCPInput(
		t,
		ctx,
		client,
		textParent,
		scrollInputBefore,
		textTarget,
		scrollAction,
		12,
		scrollResult,
	)
	record(textParent, scrollInput)
	requireTextEditScrollDelta(t, ctx, client, textFixture, scrollBefore)

	completedDrag := requireOwnedTextEditDrag(
		t,
		ctx,
		client,
		textFixture,
		visibleTextDragPath(geometry),
		0.6,
	)
	dragBefore := listInputSnapshot(t, ctx, client, textParent)
	dragResult := callPhysicalStdio(
		t,
		ctx,
		stdioInput,
		stdioOutput,
		31,
		completedDrag.toolName,
		completedDrag.arguments,
	)
	dragInput := requireCompletedMCPInput(
		t,
		ctx,
		client,
		textParent,
		dragBefore,
		textTarget,
		completedDrag.expected,
		completedDrag.maximumEvents,
		dragResult,
	)
	record(textParent, dragInput)
	requirePartialDocumentSelectionAndUndo(t, ctx, client, textFixture, fullDocument)

	// Direct generated gRPC hover must dwell for the requested interval and
	// leave the cursor at the exact point authorized by the desktop union.
	// Display-resource geometry is proved by W1; this cursor-only W2 leg uses
	// the explicit desktop authority exposed by the same public contract.
	mainDisplay := requireMainDisplay(t, displays)
	hoverPoint := requireUniqueDisplayPoint(t, mainDisplay, displays, 0.35, 0.35)
	hoverDuration := 0.25
	hoverRequest := newIntegrationInputRequest(
		t,
		"applications/-",
		&pb.InputTarget{
			Destination: &pb.InputTarget_Desktop{Desktop: true},
		},
		&pb.InputAction{
			InputType: &pb.InputAction_HoverAction{HoverAction: &pb.Hover{
				Position: hoverPoint,
				Duration: hoverDuration,
			}},
		},
	)
	hoverInput := createCompletedInput(
		t,
		ctx,
		client,
		hoverRequest,
		1,
		"direct generated hover",
	)
	if elapsed := hoverInput.GetCompleteTime().AsTime().Sub(
		hoverInput.GetCreateTime().AsTime(),
	); elapsed < time.Duration(hoverDuration*float64(time.Second)) {
		t.Fatalf("hover settled after %s, shorter than requested %.3fs", elapsed, hoverDuration)
	}
	requireCursorAt(t, ctx, client, hoverPoint)
	record("applications/-", hoverInput)

	// HTTP cancellation begins only after mouse-down and a routed waypoint are
	// externally visible. The terminal record must therefore remain precise
	// POSSIBLY_COMMITTED rather than claiming no effect or full completion.
	cancelGeometry := requireCurrentOwnedTextEditGeometry(t, ctx, client, textFixture)
	cancelDrag := requireOwnedTextEditDrag(
		t,
		ctx,
		client,
		textFixture,
		cancellableTextDragPath(cancelGeometry),
		8,
	)
	cancelBefore := listInputSnapshot(t, ctx, client, textParent)
	httpRequestResult := make(chan sessionHTTPResult, 1)
	go func() {
		payload, marshalErr := json.Marshal(map[string]any{
			"jsonrpc": "2.0",
			"id":      40,
			"method":  "tools/call",
			"params": map[string]any{
				"name":      cancelDrag.toolName,
				"arguments": cancelDrag.arguments,
			},
		})
		if marshalErr != nil {
			httpRequestResult <- sessionHTTPResult{Err: marshalErr}
			return
		}
		httpRequestResult <- sendSessionMCP(
			t,
			ctx,
			httpClient,
			baseURL,
			http.MethodPost,
			httpSession,
			string(payload),
		)
	}()
	waitForMCPInputExecution(t, ctx, client, textParent, cancelBefore, textTarget, cancelDrag.expected)
	requireCursorAt(t, ctx, client, pointMessage(cancelDrag.path[1]))
	cancelledHTTP := cancelAdmittedPhysicalRequestOnce(
		t,
		ctx,
		httpClient,
		baseURL,
		httpSession,
		40,
		httpRequestResult,
	)
	if cancelledHTTP.Status != http.StatusNoContent || len(cancelledHTTP.Body) != 0 {
		t.Fatalf(
			"cancelled HTTP drag status=%d body=%q, want 204 empty",
			cancelledHTTP.Status,
			cancelledHTTP.Body,
		)
	}
	cancelledDragInput := requireCancelledMCPInput(
		t,
		ctx,
		client,
		textParent,
		cancelBefore,
		textTarget,
		cancelDrag.expected,
		cancelDrag.maximumEvents,
	)
	record(textParent, cancelledDragInput)

	movePoint := requireUniqueDisplayPoint(t, mainDisplay, displays, 0.45, 0.45)
	moveDuration := 0.4
	moveAction := &pb.InputAction{
		InputType: &pb.InputAction_MouseMove{MouseMove: &pb.MouseMove{
			Position: movePoint,
			Duration: moveDuration,
		}},
	}
	moveBefore := listInputSnapshot(t, ctx, client, "applications/-")
	moveResult := callPhysicalHTTP(
		t,
		ctx,
		httpClient,
		baseURL,
		httpSession,
		41,
		"move",
		map[string]any{
			"target":   "desktop",
			"x":        movePoint.GetX(),
			"y":        movePoint.GetY(),
			"duration": moveDuration,
		},
	)
	moveInput := requireCompletedMCPInput(
		t,
		ctx,
		client,
		"applications/-",
		moveBefore,
		&pb.InputTarget{
			Destination: &pb.InputTarget_Desktop{Desktop: true},
		},
		moveAction,
		20,
		moveResult,
	)
	record("applications/-", moveInput)
	requireCursorAt(t, ctx, client, movePoint)

	terminated := sendSessionMCP(
		t,
		ctx,
		httpClient,
		baseURL,
		http.MethodDelete,
		httpSession,
		"",
	)
	if terminated.Err != nil || terminated.Status != http.StatusNoContent ||
		len(terminated.Body) != 0 {
		t.Fatalf(
			"terminate HTTP session status=%d body=%q error=%v",
			terminated.Status,
			terminated.Body,
			terminated.Err,
		)
	}
	stale := sendSessionMCP(
		t,
		ctx,
		httpClient,
		baseURL,
		http.MethodPost,
		httpSession,
		`{"jsonrpc":"2.0","id":42,"method":"ping"}`,
	)
	if stale.Status != http.StatusNotFound {
		t.Fatalf("terminated HTTP session status=%d body=%q, want 404", stale.Status, stale.Body)
	}

	// Stdio cancellation must suppress the cancelled response and leave key-up
	// cleanup complete before the next response and physical mutation.
	moveCaretToDocumentEnd(t, ctx, client, textFixture)
	beforeHeldKeyText := getTextEditContent(t, ctx, client, textFixture)
	keyHoldDuration := 8.0
	heldKeyAction := &pb.InputAction{
		InputType: &pb.InputAction_KeyPress{KeyPress: &pb.KeyPress{
			Key:          "x",
			HoldDuration: keyHoldDuration,
		}},
	}
	heldKeyBefore := listInputSnapshot(t, ctx, client, textParent)
	if err := writeStdioMessage(stdioInput, map[string]any{
		"jsonrpc": "2.0",
		"id":      50,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "keypress",
			"arguments": map[string]any{
				"target":        textFixture.window.GetName(),
				"keys":          []any{"x"},
				"hold_duration": keyHoldDuration,
			},
		},
	}); err != nil {
		t.Fatalf("start stdio held key: %v", err)
	}
	waitForMCPInputExecution(t, ctx, client, textParent, heldKeyBefore, textTarget, heldKeyAction)
	requireTextEditChanged(t, ctx, client, textFixture, beforeHeldKeyText)
	if err := writeStdioMessage(stdioInput, map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/cancelled",
		"params": map[string]any{
			"requestId": 50,
			"reason":    "physical truth cancellation",
		},
	}); err != nil {
		t.Fatalf("cancel stdio held key: %v", err)
	}
	cancelledKeyInput := requireCancelledMCPInput(
		t,
		ctx,
		client,
		textParent,
		heldKeyBefore,
		textTarget,
		heldKeyAction,
		2,
	)
	record(textParent, cancelledKeyInput)

	recoveryText := "Q"
	recoveryAction := &pb.InputAction{
		InputType: &pb.InputAction_TextInput{TextInput: &pb.TextInput{
			Text: recoveryText,
		}},
	}
	recoveryBefore := listInputSnapshot(t, ctx, client, textParent)
	recoveryResult := callPhysicalStdio(
		t,
		ctx,
		stdioInput,
		stdioOutput,
		51,
		"type",
		map[string]any{
			"target": textFixture.window.GetName(),
			"text":   recoveryText,
		},
	)
	recoveryInput := requireCompletedMCPInput(
		t,
		ctx,
		client,
		textParent,
		recoveryBefore,
		textTarget,
		recoveryAction,
		2,
		recoveryResult,
	)
	record(textParent, recoveryInput)
	requireTextEditStableAfterRecovery(t, ctx, client, textFixture, recoveryText)

	cleanupTextEdit()
	requireWindowGone(t, ctx, client, textFixture.window.GetName())
	for _, stored := range records {
		requireInputRoundTrip(t, ctx, client, stored.parent, stored.input)
	}

	restoreClipboard()
	restoreCursor()
	closeHTTPIdle()
	cleanupHTTP()
	cleanupStdio()
	if httpCommand.ProcessState == nil || !httpCommand.ProcessState.Success() {
		t.Fatalf("HTTP MCP child did not settle successfully: %v", httpCommand.ProcessState)
	}
	if stdioCommand.ProcessState == nil || !stdioCommand.ProcessState.Success() {
		t.Fatalf("stdio MCP child did not settle successfully: %v", stdioCommand.ProcessState)
	}
}

func requireOwnedTextEditDrag(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
	path []ownedDragPoint,
	duration float64,
) ownedTextEditDragCall {
	t.Helper()
	geometry := requireCurrentOwnedTextEditGeometry(t, ctx, client, fixture)
	if len(path) < 2 || duration <= 0 || duration > 10 {
		t.Fatalf("owned drag path=%d duration=%v is outside the sealed contract", len(path), duration)
	}
	protoPath := make([]*typepb.Point, len(path))
	argumentsPath := make([]any, len(path))
	for index, point := range path {
		requireOwnedDragPoint(t, geometry, point)
		protoPath[index] = pointMessage(point)
		argumentsPath[index] = map[string]any{"x": point.x, "y": point.y}
	}
	left := pb.MouseClick_CLICK_TYPE_LEFT
	return ownedTextEditDragCall{
		toolName: "drag",
		arguments: map[string]any{
			"target":   geometry.window.GetName(),
			"path":     argumentsPath,
			"button":   "left",
			"duration": duration,
		},
		expected: &pb.InputAction{
			InputType: &pb.InputAction_MouseDrag{MouseDrag: &pb.MouseDrag{
				StartPosition: proto.Clone(protoPath[0]).(*typepb.Point),
				EndPosition:   proto.Clone(protoPath[len(protoPath)-1]).(*typepb.Point),
				Duration:      duration,
				Button:        &left,
				Waypoints:     protoPath,
			}},
		},
		maximumEvents: int32(len(path) + 1),
		path:          append([]ownedDragPoint(nil), path...),
	}
}

func requireCurrentOwnedTextEditGeometry(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
) ownedTextEditGeometry {
	t.Helper()
	if fixture == nil || fixture.application == nil || fixture.window == nil ||
		fixture.textArea == nil || fixture.display == nil {
		t.Fatal("owned TextEdit geometry is incomplete")
	}
	window, err := client.GetWindow(ctx, &pb.GetWindowRequest{Name: fixture.window.GetName()})
	if err != nil || window.GetName() != fixture.window.GetName() ||
		window.GetBounds() == nil || !window.GetVisible() {
		t.Fatalf("revalidate owned TextEdit window response=%+v error=%v", window, err)
	}
	response, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
		Name:        fixture.application.GetName(),
		VisibleOnly: true,
	})
	if err != nil {
		t.Fatalf("revalidate owned TextEdit traversal: %v", err)
	}
	// resolveOwnedTextEditTextArea tolerates a window-index shift caused by
	// stale TextEdit state; the name-rebinding guard below still catches a
	// genuine identity change when the frozen path matched at fixture creation.
	textArea := resolveOwnedTextEditTextArea(response.GetElements(), fixture)
	if textArea != nil &&
		elementPathEqual(textArea.GetPathIndices(), fixture.elementPath) &&
		fixture.textArea.GetName() != "" &&
		textArea.GetName() != fixture.textArea.GetName() {
		t.Fatalf(
			"owned TextEdit path rebound from %q to %q",
			fixture.textArea.GetName(),
			textArea.GetName(),
		)
	}
	if textArea == nil || textArea.X == nil || textArea.Y == nil ||
		textArea.Width == nil || textArea.Height == nil ||
		textArea.GetWidth() <= 0 || textArea.GetHeight() <= 0 {
		t.Fatalf("owned TextEdit text area is unavailable: %+v", textArea)
	}
	visibleTextArea := intersectOwnedTextAreaWithWindow(textArea, window.GetBounds())
	if visibleTextArea.width <= 0 || visibleTextArea.height <= 0 {
		t.Fatalf(
			"owned TextEdit text area does not intersect its exact window: window=%+v text_area=%+v",
			window.GetBounds(),
			textArea,
		)
	}
	displays, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{PageSize: 1000})
	if err != nil || len(displays.GetDisplays()) == 0 {
		t.Fatalf("revalidate active displays response=%+v error=%v", displays, err)
	}
	return ownedTextEditGeometry{
		window:          window,
		textArea:        textArea,
		visibleTextArea: visibleTextArea,
		displays:        displays.GetDisplays(),
	}
}

func intersectOwnedTextAreaWithWindow(element *pb.Element, window *pb.Bounds) ownedRectangle {
	left := max(element.GetX(), window.GetX())
	top := max(element.GetY(), window.GetY())
	right := min(element.GetX()+element.GetWidth(), window.GetX()+window.GetWidth())
	bottom := min(element.GetY()+element.GetHeight(), window.GetY()+window.GetHeight())
	return ownedRectangle{
		x:      left,
		y:      top,
		width:  right - left,
		height: bottom - top,
	}
}

func requireOwnedDragPoint(
	t *testing.T,
	geometry ownedTextEditGeometry,
	point ownedDragPoint,
) {
	t.Helper()
	if math.IsNaN(point.x) || math.IsInf(point.x, 0) ||
		math.IsNaN(point.y) || math.IsInf(point.y, 0) {
		t.Fatalf("owned drag point is not finite: %+v", point)
	}
	if !pointInWindow(point.x, point.y, geometry.window.GetBounds()) ||
		!pointInElement(point.x, point.y, geometry.textArea) {
		t.Fatalf(
			"owned drag point %+v escapes window=%+v text_area=%+v",
			point,
			geometry.window.GetBounds(),
			geometry.textArea,
		)
	}
	owners := 0
	for _, display := range geometry.displays {
		if pointInRegion(point.x, point.y, display.GetVisibleFrame()) {
			owners++
		}
	}
	if owners != 1 {
		t.Fatalf("owned drag point %+v belongs to %d visible displays, want one", point, owners)
	}
}
