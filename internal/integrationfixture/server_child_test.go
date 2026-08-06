package integrationfixture

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"testing"
	"time"
)

const listenerHelperEnvironment = "MACOSUSESDK_LISTENER_HELPER"
const listenerIgnoreTerminationEnvironment = "MACOSUSESDK_LISTENER_IGNORE_TERM"

func TestNewSwiftServerCommandIsStaticAndIsolated(t *testing.T) {
	t.Parallel()

	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	environment := []string{"EXACT_FIXTURE=value"}
	cmd := NewSwiftServerCommand(environment, stdout, stderr)
	environment[0] = "EXACT_FIXTURE=mutated"

	if cmd.Path != swiftServerExecutable || len(cmd.Args) != 1 || cmd.Args[0] != swiftServerExecutable {
		t.Fatalf("Swift command path=%q args=%q, want exact %q", cmd.Path, cmd.Args, swiftServerExecutable)
	}
	if len(cmd.Env) != 1 || cmd.Env[0] != "EXACT_FIXTURE=value" {
		t.Fatalf("Swift command environment = %q, want isolated copy", cmd.Env)
	}
	if cmd.Stdout != stdout || cmd.Stderr != stderr {
		t.Fatal("Swift command did not retain the supplied log sinks")
	}
}

func TestStopChildAllowsExternalServer(t *testing.T) {
	t.Parallel()

	if err := StopChild(nil); err != nil {
		t.Fatalf("StopChild(nil): %v", err)
	}
}

func TestStopChildRejectsUnstartedCommand(t *testing.T) {
	t.Parallel()

	err := StopChild(exec.Command(os.Args[0], "-test.run=^TestListenerHelperProcess$"))
	if err == nil {
		t.Fatal("unstarted command was accepted")
	}
}

func TestWaitChildRejectsInvalidOwnershipAndTimeout(t *testing.T) {
	t.Parallel()

	if _, forced := WaitChild(nil, time.Second); forced {
		t.Fatal("nil child was reported as force-killed")
	}
	if waitErr, forced := WaitChild(exec.Command(os.Args[0]), time.Second); waitErr == nil || forced {
		t.Fatalf("unstarted child wait=(%v, %t), want validation failure without force", waitErr, forced)
	}

	cmd := exec.Command(os.Args[0], "-test.run=^TestListenerHelperProcess$")
	cmd.Env = os.Environ()
	if err := cmd.Start(); err != nil {
		t.Fatalf("start timeout-validation child: %v", err)
	}
	if waitErr, forced := WaitChild(cmd, 0); waitErr == nil || forced {
		t.Fatalf("nonpositive timeout wait=(%v, %t), want validation failure without force", waitErr, forced)
	}
	if err := StopChild(cmd); err != nil {
		t.Fatalf("stop timeout-validation child: %v", err)
	}
}

func TestWaitChildObservesNaturalExit(t *testing.T) {
	t.Parallel()

	cmd := exec.Command(os.Args[0], "-test.run=^TestListenerHelperProcess$")
	cmd.Env = os.Environ()
	if err := cmd.Start(); err != nil {
		t.Fatalf("start naturally exiting child: %v", err)
	}
	waitErr, forced := WaitChild(cmd, 2*time.Second)
	if waitErr != nil || forced {
		t.Fatalf("natural child wait=(%v, %t), want clean unforced exit", waitErr, forced)
	}
	if cmd.ProcessState == nil || !cmd.ProcessState.Success() {
		t.Fatalf("natural child was not reaped successfully: %v", cmd.ProcessState)
	}
}

func TestWaitChildForceKillsOnlyOwnedPIDAfterTimeout(t *testing.T) {
	t.Parallel()

	cmd, address, cancel := startListenerHelper(t, false)
	defer cancel()
	waitErr, forced := WaitChild(cmd, 25*time.Millisecond)
	if !forced {
		t.Fatalf("blocking child wait=(%v, %t), want explicit forced result", waitErr, forced)
	}
	requireReapedAndReleased(t, cmd, address)
}

func TestStopChildOperationFailures(t *testing.T) {
	t.Parallel()

	command := &exec.Cmd{Process: &os.Process{Pid: 4242}}
	hardFailure := errors.New("injected failure")
	tests := []struct {
		name       string
		operations childOperations
		wantError  string
	}{
		{
			name: "kill failure",
			operations: childOperations{
				kill:   func(*os.Process) error { return hardFailure },
				wait:   func(*exec.Cmd) error { t.Fatal("wait called after kill failure"); return nil },
				reaped: func(*exec.Cmd) bool { return true },
			},
			wantError: "kill server child 4242: injected failure",
		},
		{
			name: "wait failure",
			operations: childOperations{
				kill:   func(*os.Process) error { return nil },
				wait:   func(*exec.Cmd) error { return hardFailure },
				reaped: func(*exec.Cmd) bool { return true },
			},
			wantError: "wait for server child 4242: injected failure",
		},
		{
			name: "missing reap state",
			operations: childOperations{
				kill:   func(*os.Process) error { return os.ErrProcessDone },
				wait:   func(*exec.Cmd) error { return &exec.ExitError{} },
				reaped: func(*exec.Cmd) bool { return false },
			},
			wantError: "server child 4242 was not reaped",
		},
		{
			name: "already done and signal exit are accepted",
			operations: childOperations{
				kill:   func(*os.Process) error { return os.ErrProcessDone },
				wait:   func(*exec.Cmd) error { return &exec.ExitError{} },
				reaped: func(*exec.Cmd) bool { return true },
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := stopChild(command, test.operations)
			if test.wantError == "" {
				if err != nil {
					t.Fatalf("stopChild: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("stopChild error = %v, want substring %q", err, test.wantError)
			}
		})
	}
}

func TestStopChildKillsReapsAndReleasesListener(t *testing.T) {
	t.Parallel()

	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate listener address: %v", err)
	}
	address := probe.Addr().String()
	if err := probe.Close(); err != nil {
		t.Fatalf("release probe listener: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestListenerHelperProcess$")
	cmd.Env = append(os.Environ(), listenerHelperEnvironment+"="+address)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start listener helper: %v", err)
	}
	childStopped := false
	defer func() {
		if childStopped {
			return
		}
		if err := StopChild(cmd); err != nil {
			t.Errorf("cleanup listener helper: %v", err)
		}
	}()

	waitForCondition(t, ctx, func() bool {
		connection, err := net.DialTimeout("tcp", address, 50*time.Millisecond)
		if err != nil {
			return false
		}
		_ = connection.Close()
		return true
	}, "listener helper did not become ready")

	if err := StopChild(cmd); err != nil {
		t.Fatalf("StopChild: %v", err)
	}
	childStopped = true
	if cmd.ProcessState == nil {
		t.Fatal("listener helper was not reaped")
	}
	if err := cmd.Process.Kill(); !errors.Is(err, os.ErrProcessDone) {
		t.Fatalf("reaped process Kill error = %v, want os.ErrProcessDone", err)
	}
	waitForCondition(t, ctx, func() bool {
		listener, err := net.Listen("tcp", address)
		if err != nil {
			return false
		}
		_ = listener.Close()
		return true
	}, "listener address was not released")
}

func TestStopChildGracefullyReapsAndReleasesListener(t *testing.T) {
	t.Parallel()

	cmd, address, cancel := startListenerHelper(t, false)
	defer cancel()
	if err := StopChildGracefully(cmd, 2*time.Second); err != nil {
		t.Fatalf("StopChildGracefully: %v", err)
	}
	requireReapedAndReleased(t, cmd, address)
}

func TestStopChildGracefullyReportsForcedFallback(t *testing.T) {
	t.Parallel()

	cmd, address, cancel := startListenerHelper(t, true)
	defer cancel()
	err := StopChildGracefully(cmd, 25*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "forced termination") {
		t.Fatalf("StopChildGracefully error = %v, want forced termination", err)
	}
	requireReapedAndReleased(t, cmd, address)
}

func TestListenerHelperProcess(t *testing.T) {
	address := os.Getenv(listenerHelperEnvironment)
	if address == "" {
		return
	}
	if os.Getenv(listenerIgnoreTerminationEnvironment) != "" {
		signal.Ignore(syscall.SIGTERM)
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		os.Exit(2)
	}
	defer listener.Close()
	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			os.Exit(3)
		}
		_ = connection.Close()
	}
}

func startListenerHelper(t *testing.T, ignoreTermination bool) (*exec.Cmd, string, context.CancelFunc) {
	t.Helper()
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate listener address: %v", err)
	}
	address := probe.Addr().String()
	if err := probe.Close(); err != nil {
		t.Fatalf("release probe listener: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestListenerHelperProcess$")
	cmd.Env = append(os.Environ(), listenerHelperEnvironment+"="+address)
	if ignoreTermination {
		cmd.Env = append(cmd.Env, listenerIgnoreTerminationEnvironment+"=1")
	}
	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatalf("start listener helper: %v", err)
	}
	waitForCondition(t, ctx, func() bool {
		connection, err := net.DialTimeout("tcp", address, 50*time.Millisecond)
		if err != nil {
			return false
		}
		_ = connection.Close()
		return true
	}, "listener helper did not become ready")
	return cmd, address, cancel
}

func requireReapedAndReleased(t *testing.T, cmd *exec.Cmd, address string) {
	t.Helper()
	if cmd.ProcessState == nil {
		t.Fatal("listener helper was not reaped")
	}
	if err := cmd.Process.Kill(); !errors.Is(err, os.ErrProcessDone) {
		t.Fatalf("reaped process Kill error = %v, want os.ErrProcessDone", err)
	}
	releaseCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	waitForCondition(t, releaseCtx, func() bool {
		listener, err := net.Listen("tcp", address)
		if err != nil {
			return false
		}
		_ = listener.Close()
		return true
	}, "listener address was not released")
}

func waitForCondition(t *testing.T, ctx context.Context, condition func() bool, failure string) {
	t.Helper()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		if condition() {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal(failure)
		case <-ticker.C:
		}
	}
}
