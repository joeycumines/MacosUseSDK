package integrationfixture

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"
)

const swiftServerExecutable = "../Server/.build/release/ExactMacServer"

// NewSwiftServerCommand constructs, but does not start, the repository's exact
// release Swift server child. Keeping the executable static here prevents
// integration tests from substituting a process-wide command or arbitrary
// executable while still allowing each fixture to supply isolated settings and
// log sinks.
func NewSwiftServerCommand(environment []string, stdout, stderr io.Writer) *exec.Cmd {
	cmd := exec.Command(swiftServerExecutable)
	cmd.Env = append([]string(nil), environment...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd
}

// StopChild kills and reaps only the process owned by cmd. A nil command is an
// external-server fixture and needs no local cleanup.
func StopChild(cmd *exec.Cmd) error {
	return stopChild(cmd, childOperations{
		kill:   func(process *os.Process) error { return process.Kill() },
		wait:   func(command *exec.Cmd) error { return command.Wait() },
		reaped: func(command *exec.Cmd) bool { return command.ProcessState != nil },
	})
}

// WaitChild waits for an exact fixture-owned child and force-kills only that
// PID if the deadline expires. The forced result remains explicit even when
// the child is successfully reaped.
func WaitChild(cmd *exec.Cmd, timeout time.Duration) (waitErr error, forced bool) {
	if cmd == nil {
		return errors.New("server child is required"), false
	}
	if cmd.Process == nil {
		return errors.New("server child was not started"), false
	}
	if cmd.ProcessState != nil {
		return errors.New("server child was already reaped"), false
	}
	if timeout <= 0 {
		return errors.New("server child wait timeout must be positive"), false
	}

	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case waitErr := <-waitCh:
		if cmd.ProcessState == nil {
			return fmt.Errorf("server child %d was not reaped", cmd.Process.Pid), false
		}
		return waitErr, false
	case <-timer.C:
		killErr := cmd.Process.Kill()
		if killErr != nil && !errors.Is(killErr, os.ErrProcessDone) {
			return fmt.Errorf("force-kill server child %d after %s: %w", cmd.Process.Pid, timeout, killErr), true
		}
		waitErr := <-waitCh
		if cmd.ProcessState == nil {
			return fmt.Errorf("server child %d was not reaped", cmd.Process.Pid), true
		}
		return waitErr, true
	}
}

// StopChildGracefully asks an exact fixture-owned process to terminate, waits
// for it to release resources, and force-kills only that PID if the deadline
// expires. A forced fallback is returned as an error even when reap succeeds so
// production-path tests cannot mistake abrupt cleanup for graceful shutdown.
func StopChildGracefully(cmd *exec.Cmd, timeout time.Duration) error {
	if cmd == nil {
		return nil
	}
	if cmd.Process == nil {
		return errors.New("server child was not started")
	}
	if timeout <= 0 {
		return errors.New("graceful stop timeout must be positive")
	}
	if cmd.ProcessState != nil {
		return nil
	}

	signalErr := cmd.Process.Signal(syscall.SIGTERM)
	if signalErr != nil && !errors.Is(signalErr, os.ErrProcessDone) {
		return fmt.Errorf("signal server child %d: %w", cmd.Process.Pid, signalErr)
	}

	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case waitErr := <-waitCh:
		return validateChildWait(cmd, waitErr)
	case <-timer.C:
		killErr := cmd.Process.Kill()
		if killErr != nil && !errors.Is(killErr, os.ErrProcessDone) {
			return fmt.Errorf("force-kill server child %d after %s: %w", cmd.Process.Pid, timeout, killErr)
		}
		waitErr := <-waitCh
		if err := validateChildWait(cmd, waitErr); err != nil {
			return err
		}
		return fmt.Errorf("server child %d did not exit within %s; forced termination", cmd.Process.Pid, timeout)
	}
}

func validateChildWait(cmd *exec.Cmd, waitErr error) error {
	var exitErr *exec.ExitError
	if waitErr != nil && !errors.As(waitErr, &exitErr) {
		return fmt.Errorf("wait for server child %d: %w", cmd.Process.Pid, waitErr)
	}
	if cmd.ProcessState == nil {
		return fmt.Errorf("server child %d was not reaped", cmd.Process.Pid)
	}
	return nil
}

type childOperations struct {
	kill   func(*os.Process) error
	wait   func(*exec.Cmd) error
	reaped func(*exec.Cmd) bool
}

func stopChild(cmd *exec.Cmd, operations childOperations) error {
	if cmd == nil {
		return nil
	}
	if cmd.Process == nil {
		return errors.New("server child was not started")
	}

	killErr := operations.kill(cmd.Process)
	if killErr != nil && !errors.Is(killErr, os.ErrProcessDone) {
		return fmt.Errorf("kill server child %d: %w", cmd.Process.Pid, killErr)
	}

	waitErr := operations.wait(cmd)
	var exitErr *exec.ExitError
	if waitErr != nil && !errors.As(waitErr, &exitErr) {
		return fmt.Errorf("wait for server child %d: %w", cmd.Process.Pid, waitErr)
	}
	if !operations.reaped(cmd) {
		return fmt.Errorf("server child %d was not reaped", cmd.Process.Pid)
	}
	return nil
}
