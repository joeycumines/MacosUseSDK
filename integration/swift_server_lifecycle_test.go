package integration

import (
	"bytes"
	"context"
	"maps"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"github.com/joeycumines/ExactMac/internal/integrationfixture"
)

const swiftServerLifecycleTimeout = 5 * time.Second

func TestSwiftServerLifecycle_FatalBindExitsNonzero(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("occupy TCP address: %v", err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port

	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_LISTEN_ADDRESS": "127.0.0.1",
		"GRPC_PORT":           strconv.Itoa(port),
		"GRPC_UNIX_SOCKET":    "",
	})
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced {
		t.Fatalf("server stayed alive after fatal bind failure; logs=%q", logs.String())
	}
	if waitErr == nil || cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Fatalf("fatal bind exit=%v state=%v, want prompt nonzero; logs=%q", waitErr, cmd.ProcessState, logs.String())
	}
}

func TestSwiftServerLifecycle_PreexistingUnixPathIsPreserved(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "server.sock")
	marker := []byte("do-not-delete")
	if err := os.WriteFile(socketPath, marker, 0o600); err != nil {
		t.Fatalf("create pre-existing path: %v", err)
	}
	before, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("lstat pre-existing path: %v", err)
	}

	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced {
		t.Errorf("server stayed alive after destructive Unix-path admission; logs=%q", logs.String())
	}
	if waitErr == nil || cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Errorf("pre-existing Unix path exit=%v state=%v, want prompt nonzero; logs=%q", waitErr, cmd.ProcessState, logs.String())
	}

	after, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("pre-existing path was removed: %v; logs=%q", err, logs.String())
	}
	contents, err := os.ReadFile(socketPath)
	if err != nil {
		t.Fatalf("pre-existing path is no longer a regular file: %v; logs=%q", err, logs.String())
	}
	if !os.SameFile(before, after) || !bytes.Equal(contents, marker) {
		t.Fatalf("pre-existing path changed: before=%v after=%v contents=%q; logs=%q", before, after, contents, logs.String())
	}
}

func TestSwiftServerLifecycle_PreexistingUnixDirectoryAndSymlinkArePreserved(t *testing.T) {
	t.Run("directory", func(t *testing.T) {
		root := t.TempDir()
		socketPath := filepath.Join(root, "server.sock")
		if err := os.Mkdir(socketPath, 0o700); err != nil {
			t.Fatalf("create pre-existing directory: %v", err)
		}
		markerPath := filepath.Join(socketPath, "marker")
		marker := []byte("directory-marker")
		if err := os.WriteFile(markerPath, marker, 0o600); err != nil {
			t.Fatalf("create directory marker: %v", err)
		}
		before, err := os.Lstat(socketPath)
		if err != nil {
			t.Fatalf("lstat pre-existing directory: %v", err)
		}

		assertSwiftServerRefusesPreexistingUnixPath(t, socketPath)

		after, err := os.Lstat(socketPath)
		if err != nil || !os.SameFile(before, after) || !after.IsDir() {
			t.Fatalf("pre-existing directory changed: before=%v after=%v err=%v", before, after, err)
		}
		contents, err := os.ReadFile(markerPath)
		if err != nil || !bytes.Equal(contents, marker) {
			t.Fatalf("pre-existing directory contents changed: contents=%q err=%v", contents, err)
		}
	})

	t.Run("symlink", func(t *testing.T) {
		root := t.TempDir()
		targetPath := filepath.Join(root, "target")
		marker := []byte("symlink-target")
		if err := os.WriteFile(targetPath, marker, 0o600); err != nil {
			t.Fatalf("create symlink target: %v", err)
		}
		socketPath := filepath.Join(root, "server.sock")
		if err := os.Symlink(targetPath, socketPath); err != nil {
			t.Fatalf("create pre-existing symlink: %v", err)
		}

		assertSwiftServerRefusesPreexistingUnixPath(t, socketPath)

		linkTarget, err := os.Readlink(socketPath)
		if err != nil || linkTarget != targetPath {
			t.Fatalf("pre-existing symlink changed: target=%q err=%v", linkTarget, err)
		}
		contents, err := os.ReadFile(targetPath)
		if err != nil || !bytes.Equal(contents, marker) {
			t.Fatalf("symlink target changed: contents=%q err=%v", contents, err)
		}
	})
}

// Manual runs must omit GRPC_UNIX_SOCKET (DEPLOYMENT.md). Without launchd
// socket activation the server fails closed and must not create the pathname.
func TestSwiftServerLifecycle_UnixSocketWithoutLaunchdFailsClosedWithoutCreatingPath(t *testing.T) {
	socketPath := newShortSwiftSocketPath(t)
	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced {
		t.Fatalf("server stayed alive without launchd activation; logs=%q", logs.String())
	}
	if waitErr == nil || cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Fatalf("Unix-socket exit=%v state=%v, want prompt nonzero without launchd; logs=%q", waitErr, cmd.ProcessState, logs.String())
	}
	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("fail-closed activation created pathname (err=%v); logs=%q", err, logs.String())
	}
}

func TestSwiftServerLifecycle_UnixSocketFailClosedReportsLaunchdActivationRequired(t *testing.T) {
	socketPath := newShortSwiftSocketPath(t)
	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced || waitErr == nil || cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Fatalf("Unix-socket exit=%v forced=%t state=%v, want prompt nonzero; logs=%q", waitErr, forced, cmd.ProcessState, logs.String())
	}
	message := logs.String()
	if !bytes.Contains([]byte(message), []byte("launchdActivationRequired")) {
		t.Fatalf("missing launchdActivationRequired in logs: %q", message)
	}
	if !bytes.Contains([]byte(message), []byte(socketPath)) {
		t.Fatalf("missing configured socket path in logs: %q", message)
	}
}

func TestSwiftServerLifecycle_SIGTERMDrainsAndExitsZero(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve TCP address: %v", err)
	}
	address := listener.Addr().String()
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatalf("release TCP address: %v", err)
	}

	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_LISTEN_ADDRESS": "127.0.0.1",
		"GRPC_PORT":           strconv.Itoa(port),
		"GRPC_UNIX_SOCKET":    "",
	})
	readyCtx, cancelReady := context.WithTimeout(context.Background(), swiftServerLifecycleTimeout)
	defer cancelReady()
	if err := PollUntilContext(readyCtx, 20*time.Millisecond, func() (bool, error) {
		connection, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err != nil {
			return false, nil
		}
		return true, connection.Close()
	}); err != nil {
		stopSwiftLifecycleProcess(t, cmd)
		t.Fatalf("server did not become ready: %v; logs=%q", err, logs.String())
	}

	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		stopSwiftLifecycleProcess(t, cmd)
		t.Fatalf("signal server: %v", err)
	}
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced {
		t.Fatalf("SIGTERM did not drain server before deadline; logs=%q", logs.String())
	}
	if waitErr != nil || cmd.ProcessState == nil || !cmd.ProcessState.Success() {
		t.Fatalf("SIGTERM exit=%v state=%v, want zero after drain; logs=%q", waitErr, cmd.ProcessState, logs.String())
	}

	releaseCtx, cancelRelease := context.WithTimeout(context.Background(), time.Second)
	defer cancelRelease()
	if err := waitForPortAvailable(t, releaseCtx, address); err != nil {
		t.Fatalf("server address was not released after SIGTERM: %v", err)
	}
}

func startSwiftLifecycleProcess(t *testing.T, overrides map[string]string) (*exec.Cmd, *bytes.Buffer) {
	t.Helper()
	defaults := map[string]string{
		"GRPC_LISTEN_ADDRESS": "127.0.0.1",
		"GRPC_PORT":           "0",
		"GRPC_UNIX_SOCKET":    "",
	}
	maps.Copy(defaults, overrides)
	logs := &bytes.Buffer{}
	cmd := integrationfixture.NewSwiftServerCommand(testEnvironment(defaults), os.Stdout, logs)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start release Swift server: %v", err)
	}
	t.Cleanup(func() {
		stopSwiftLifecycleProcess(t, cmd)
	})
	return cmd, logs
}

func assertSwiftServerRefusesPreexistingUnixPath(t *testing.T, socketPath string) {
	t.Helper()
	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced || waitErr == nil || cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Fatalf("pre-existing Unix path exit=%v forced=%t state=%v, want prompt nonzero; logs=%q", waitErr, forced, cmd.ProcessState, logs.String())
	}
}

func newShortSwiftSocketPath(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "exactmac-lifecycle-")
	if err != nil {
		t.Fatalf("create short Unix-socket directory: %v", err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("remove short Unix-socket directory: %v", err)
		}
	})
	return filepath.Join(directory, "server.sock")
}

func stopSwiftLifecycleProcess(t *testing.T, cmd *exec.Cmd) {
	t.Helper()
	if cmd == nil || cmd.ProcessState != nil {
		return
	}
	if err := integrationfixture.StopChild(cmd); err != nil {
		t.Errorf("stop exact Swift server child: %v", err)
	}
}
