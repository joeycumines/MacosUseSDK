package integration

import (
	"context"
	"fmt"
	"regexp"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/rivo/uniseg"
	"google.golang.org/protobuf/proto"
)

var integrationInputSequence atomic.Uint64
var mcpInputResourcePattern = regexp.MustCompile(
	`^applications/(?:-|[0-9a-f]{64})/inputs/mcp-[0-9a-f]{32}$`,
)

// cleanupApplication closes the exact owned process and verifies state cleanup.
func cleanupApplication(t *testing.T, ctx context.Context, client pb.MacosUseClient, app *pb.Application) {
	CleanupApplication(t, ctx, client, app)
}

func applicationInputTarget(name string) *pb.InputTarget {
	return &pb.InputTarget{
		Destination: &pb.InputTarget_Application{Application: name},
	}
}

func windowInputTarget(name string) *pb.InputTarget {
	return &pb.InputTarget{
		Destination: &pb.InputTarget_Window{Window: name},
	}
}

func desktopInputTarget() *pb.InputTarget {
	return &pb.InputTarget{
		Destination: &pb.InputTarget_Desktop{Desktop: true},
	}
}

func newIntegrationInputRequest(
	t *testing.T,
	parent string,
	target *pb.InputTarget,
	action *pb.InputAction,
) *pb.CreateInputRequest {
	t.Helper()
	if parent == "" || target == nil || action == nil {
		t.Fatalf(
			"construct exact input request: parent=%q target=%v action=%v",
			parent,
			target,
			action,
		)
	}
	return &pb.CreateInputRequest{
		Parent: parent,
		Input: &pb.Input{
			Action: action,
			Target: target,
		},
		InputId: fmt.Sprintf(
			"integration-%016x",
			integrationInputSequence.Add(1),
		),
	}
}

func createCompletedInput(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	request *pb.CreateInputRequest,
	expectedPostedEvents int32,
	operation string,
) *pb.Input {
	t.Helper()
	input, err := client.CreateInput(ctx, request)
	if err != nil {
		t.Fatalf("%s CreateInput failed: %v", operation, err)
	}
	return requireCompletedInput(
		t,
		ctx,
		client,
		request,
		input,
		expectedPostedEvents,
		operation,
	)
}

func requireCompletedInput(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	request *pb.CreateInputRequest,
	initial *pb.Input,
	expectedPostedEvents int32,
	operation string,
) *pb.Input {
	t.Helper()
	if request == nil || request.GetInput() == nil || request.GetInputId() == "" {
		t.Fatalf("%s test lost its exact CreateInput request", operation)
	}
	if initial == nil {
		t.Fatalf("%s returned no Input resource", operation)
	}
	wantName := request.GetParent() + "/inputs/" + request.GetInputId()
	requireInputIdentity := func(input *pb.Input) {
		t.Helper()
		if input.GetName() != wantName {
			t.Fatalf("%s name=%q want=%q", operation, input.GetName(), wantName)
		}
		if !proto.Equal(input.GetAction(), request.GetInput().GetAction()) {
			t.Fatalf("%s changed the requested action", operation)
		}
		if !proto.Equal(input.GetTarget(), request.GetInput().GetTarget()) {
			t.Fatalf("%s changed the requested target", operation)
		}
	}
	requireInputIdentity(initial)

	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var terminal *pb.Input
	var lastErr error
	err := PollUntilContext(waitCtx, 50*time.Millisecond, func() (bool, error) {
		terminal, lastErr = client.GetInput(
			waitCtx,
			&pb.GetInputRequest{Name: wantName},
		)
		if lastErr != nil {
			return false, nil
		}
		requireInputIdentity(terminal)
		switch terminal.GetState() {
		case pb.Input_STATE_COMPLETED,
			pb.Input_STATE_FAILED,
			pb.Input_STATE_CANCELLED:
			return true, nil
		default:
			return false, nil
		}
	})
	if err != nil {
		t.Fatalf(
			"%s did not reach a terminal state: poll=%v last_error=%v",
			operation,
			err,
			lastErr,
		)
	}
	if terminal.GetState() != pb.Input_STATE_COMPLETED {
		t.Fatalf(
			"%s failed: state=%s error=%q",
			operation,
			terminal.GetState(),
			terminal.GetError(),
		)
	}
	if terminal.GetError() != "" {
		t.Fatalf("%s completed with terminal error %q", operation, terminal.GetError())
	}
	createTime := terminal.GetCreateTime()
	if createTime == nil {
		t.Fatalf("%s completed without create_time", operation)
	}
	if err := createTime.CheckValid(); err != nil {
		t.Fatalf("%s create_time is invalid: %v", operation, err)
	}
	completeTime := terminal.GetCompleteTime()
	if completeTime == nil {
		t.Fatalf("%s completed without complete_time", operation)
	}
	if err := completeTime.CheckValid(); err != nil {
		t.Fatalf("%s complete_time is invalid: %v", operation, err)
	}
	if completeTime.AsTime().Before(createTime.AsTime()) {
		t.Fatalf("%s complete_time precedes create_time", operation)
	}
	delivery := terminal.GetDeliveryResult()
	if delivery == nil {
		t.Fatalf("%s completed without a delivery result", operation)
	}
	if delivery.GetCommitment() !=
		pb.InputDeliveryResult_COMMITMENT_COMMITTED_AND_SETTLED {
		t.Fatalf(
			"%s commitment=%s want COMMITTED_AND_SETTLED",
			operation,
			delivery.GetCommitment(),
		)
	}
	if delivery.GetPostedEventCount() != expectedPostedEvents {
		t.Fatalf(
			"%s posted_event_count=%d want=%d",
			operation,
			delivery.GetPostedEventCount(),
			expectedPostedEvents,
		)
	}
	if !delivery.GetRoutedDeliveryObserved() {
		t.Fatalf("%s completed without routed delivery observation", operation)
	}
	return terminal
}

func listInputSnapshot(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	parent string,
) map[string]*pb.Input {
	t.Helper()
	if parent == "" {
		t.Fatal("input snapshot requires an exact parent")
	}
	snapshot := make(map[string]*pb.Input)
	seenTokens := make(map[string]struct{})
	pageToken := ""
	for {
		response, err := client.ListInputs(ctx, &pb.ListInputsRequest{
			Parent:    parent,
			PageSize:  1000,
			PageToken: pageToken,
		})
		if err != nil {
			t.Fatalf("ListInputs(%q, token=%q): %v", parent, pageToken, err)
		}
		if response == nil {
			t.Fatalf("ListInputs(%q, token=%q) returned nil", parent, pageToken)
		}
		for _, input := range response.GetInputs() {
			if input == nil || input.GetName() == "" {
				t.Fatalf("ListInputs(%q) returned an incomplete Input: %+v", parent, input)
			}
			if _, duplicate := snapshot[input.GetName()]; duplicate {
				t.Fatalf("ListInputs(%q) repeated Input %q", parent, input.GetName())
			}
			snapshot[input.GetName()] = proto.Clone(input).(*pb.Input)
		}
		pageToken = response.GetNextPageToken()
		if pageToken == "" {
			return snapshot
		}
		if _, duplicate := seenTokens[pageToken]; duplicate {
			t.Fatalf("ListInputs(%q) repeated page token", parent)
		}
		seenTokens[pageToken] = struct{}{}
	}
}

func requireOneNewInput(
	t *testing.T,
	before map[string]*pb.Input,
	after map[string]*pb.Input,
	wantTarget *pb.InputTarget,
	wantAction *pb.InputAction,
) *pb.Input {
	t.Helper()
	for name, previous := range before {
		current, ok := after[name]
		if !ok {
			t.Fatalf("Input history lost %q", name)
		}
		if !proto.Equal(current, previous) {
			t.Fatalf("Input history mutated for %q\nbefore=%v\nafter=%v", name, previous, current)
		}
	}
	additions := make([]*pb.Input, 0, 1)
	for name, input := range after {
		if _, existed := before[name]; !existed {
			additions = append(additions, input)
		}
	}
	if len(additions) != 1 {
		t.Fatalf("Input history added %d resources, want exactly one", len(additions))
	}
	input := additions[0]
	if !mcpInputResourcePattern.MatchString(input.GetName()) {
		t.Fatalf("MCP Input name %q is not a canonical caller-generated identity", input.GetName())
	}
	if !proto.Equal(input.GetTarget(), wantTarget) {
		t.Fatalf("Input %q target=%v want=%v", input.GetName(), input.GetTarget(), wantTarget)
	}
	if !proto.Equal(input.GetAction(), wantAction) {
		t.Fatalf("Input %q action=%v want=%v", input.GetName(), input.GetAction(), wantAction)
	}
	return input
}

func requireInputTerminalEvidence(
	t *testing.T,
	input *pb.Input,
	wantState pb.Input_State,
	wantCommitment pb.InputDeliveryResult_Commitment,
	minimumPosts int32,
	maximumPosts int32,
) {
	t.Helper()
	if input == nil {
		t.Fatal("terminal Input is nil")
	}
	if input.GetState() != wantState {
		t.Fatalf("Input %q state=%s want=%s error=%q", input.GetName(), input.GetState(), wantState, input.GetError())
	}
	switch wantState {
	case pb.Input_STATE_COMPLETED:
		if input.GetError() != "" {
			t.Fatalf("completed Input %q has error %q", input.GetName(), input.GetError())
		}
	case pb.Input_STATE_FAILED, pb.Input_STATE_CANCELLED:
		if input.GetError() == "" {
			t.Fatalf("terminal failure Input %q omitted its error", input.GetName())
		}
	default:
		t.Fatalf("terminal proof requested nonterminal state %s", wantState)
	}
	createTime := input.GetCreateTime()
	completeTime := input.GetCompleteTime()
	if createTime == nil || completeTime == nil {
		t.Fatalf("Input %q omitted create or complete time", input.GetName())
	}
	if err := createTime.CheckValid(); err != nil {
		t.Fatalf("Input %q create_time is invalid: %v", input.GetName(), err)
	}
	if err := completeTime.CheckValid(); err != nil {
		t.Fatalf("Input %q complete_time is invalid: %v", input.GetName(), err)
	}
	if completeTime.AsTime().Before(createTime.AsTime()) {
		t.Fatalf("Input %q completed before it was created", input.GetName())
	}
	delivery := input.GetDeliveryResult()
	if delivery == nil {
		t.Fatalf("Input %q omitted delivery evidence", input.GetName())
	}
	if delivery.GetCommitment() != wantCommitment {
		t.Fatalf(
			"Input %q commitment=%s want=%s",
			input.GetName(),
			delivery.GetCommitment(),
			wantCommitment,
		)
	}
	if delivery.GetPostedEventCount() < minimumPosts ||
		delivery.GetPostedEventCount() > maximumPosts {
		t.Fatalf(
			"Input %q posted_event_count=%d want range [%d,%d]",
			input.GetName(),
			delivery.GetPostedEventCount(),
			minimumPosts,
			maximumPosts,
		)
	}
	if !delivery.GetRoutedDeliveryObserved() {
		t.Fatalf("Input %q has no routed delivery observation", input.GetName())
	}
}

func requireInputRoundTrip(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	parent string,
	want *pb.Input,
) {
	t.Helper()
	if want == nil || want.GetName() == "" {
		t.Fatal("Input round trip requires an exact resource")
	}
	listed, ok := listInputSnapshot(t, ctx, client, parent)[want.GetName()]
	if !ok {
		t.Fatalf("ListInputs(%q) omitted %q", parent, want.GetName())
	}
	if !proto.Equal(listed, want) {
		t.Fatalf("ListInputs(%q) changed %q\nwant=%v\ngot=%v", parent, want.GetName(), want, listed)
	}
	fetched, err := client.GetInput(ctx, &pb.GetInputRequest{Name: want.GetName()})
	if err != nil {
		t.Fatalf("GetInput(%q): %v", want.GetName(), err)
	}
	if !proto.Equal(fetched, want) {
		t.Fatalf("GetInput(%q) changed the stored resource\nwant=%v\ngot=%v", want.GetName(), want, fetched)
	}
}

// performInput creates and executes an exact application-targeted text action.
func performInput(t *testing.T, ctx context.Context, client pb.MacosUseClient, app *pb.Application, text string) {
	request := newIntegrationInputRequest(
		t,
		app.GetName(),
		applicationInputTarget(app.GetName()),
		&pb.InputAction{
			InputType: &pb.InputAction_TypeText{
				TypeText: &pb.TextInput{
					Text: text,
				},
			},
		},
	)
	input := createCompletedInput(
		t,
		ctx,
		client,
		request,
		int32(2*uniseg.GraphemeClusterCount(text)),
		fmt.Sprintf("type %q", text),
	)
	t.Logf("Input created and executed: %s", input.GetName())
}
