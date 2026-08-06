package integrationguard

import (
	"strings"
	"testing"
)

func TestProcessSafetyGuardRejectsMutations(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		filename  string
		source    string
		wantRules []string
	}{
		{
			name:      "command process wide server kill",
			filename:  "command_test.go",
			source:    "package integration\nfunc test() { exec.Command(\"killall\", \"-9\", \"MacosUseServer\") }\n",
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:      "command context process wide server kill",
			filename:  "command_context_test.go",
			source:    "package integration\nfunc test() { exec.CommandContext(ctx, \"pkill\", \"MacosUseServer\") }\n",
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:      "aliased exec process wide server kill",
			filename:  "aliased_exec_test.go",
			source:    "package integration\nfunc test() { osexec.Command(\"/usr/bin/killall\", \"-9\", \"MacosUseServer\") }\n",
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:      "dot imported process wide server kill",
			filename:  "dot_exec_test.go",
			source:    "package integration\nfunc test() { Command(\"pkill\", \"MacosUseServer\") }\n",
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:      "shell process wide server kill",
			filename:  "shell_exec_test.go",
			source:    "package integration\nfunc test() { exec.Command(\"sh\", \"-c\", \"killall -9 MacosUseServer\") }\n",
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:     "fragmented shell process wide server kill",
			filename: "fragmented_shell_exec_test.go",
			source: `package integration
func test() {
	exec.Command("sh", "-c", ("kill" + "all") + " -9 " + ("MacosUse" + "Server"))
}
`,
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:     "implicit constant fragmented shell server kill",
			filename: "implicit_fragmented_shell_exec_test.go",
			source: `package integration
const (
	killPrefix = "kill"
	killAlias
	serverPrefix = "MacosUse"
	serverAlias
)
func test() { exec.Command("sh", "-c", killAlias+"all -9 "+serverAlias+"Server") }
`,
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:      "variable process wide server kill",
			filename:  "variable_exec_test.go",
			source:    "package integration\nfunc test(command string) { server := \"MacosUseServer\"; exec.Command(command, server) }\n",
			wantRules: []string{ruleDynamicCommandExecutable, ruleServerWideKill},
		},
		{
			name:      "wrapper process wide server kill",
			filename:  "wrapper_exec_test.go",
			source:    "package integration\nfunc terminate(command, target string) {}\nfunc test() { terminate(\"killall\", \"MacosUseServer\") }\n",
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:     "derived executable basename process wide server kill",
			filename: "derived_server_name_test.go",
			source: `package integration
func test() {
	serverPath := "../Server/.build/release/MacosUseServer"
	serverName := filepath.Base(serverPath)
	exec.Command("killall", "-9", serverName)
}
`,
			wantRules: []string{ruleServerWideKill},
		},
		{
			name:     "fully dynamic process command and target",
			filename: "dynamic_process_test.go",
			source: `package integration
func terminate(command, target string) { exec.Command(command, "-9", target) }
func test() { terminate(os.Getenv("KILL_COMMAND"), os.Getenv("KILL_TARGET")) }
`,
			wantRules: []string{ruleDynamicCommandExecutable},
		},
		{
			name:     "function value alias of command",
			filename: "command_alias_test.go",
			source: `package integration
func test() {
	run := exec.Command
	run(os.Getenv("KILL_COMMAND"), "-9", os.Getenv("KILL_TARGET"))
}
`,
			wantRules: []string{ruleDynamicCommandExecutable},
		},
		{
			name:     "function value alias of dot imported command context",
			filename: "command_context_alias_test.go",
			source: `package integration
func test() {
	run := CommandContext
	run(ctx, os.Getenv("KILL_COMMAND"), "-9", os.Getenv("KILL_TARGET"))
}
`,
			wantRules: []string{ruleDynamicCommandExecutable},
		},
		{
			name:      "stray helper declaration and call",
			filename:  "helper_test.go",
			source:    "package integration\nfunc killStrayServers() {}\nfunc test() { killStrayServers() }\n",
			wantRules: []string{ruleStrayServerHelper},
		},
		{
			name:     "direct lifecycle child kill bypass",
			filename: "lifecycle_test.go",
			source: `package integration
func TestCoreLifecycle() { serverCmd, _ := startServer(); defer serverCmd.Process.Kill() }
func TestMultipleApplications() { serverCmd, _ := startServer(); defer serverCmd.Process.Kill() }
`,
			wantRules: []string{ruleDirectServerProcessKill, ruleMissingServerCleanup},
		},
		{
			name:     "renamed lifecycle child kill bypass",
			filename: "lifecycle_test.go",
			source: `package integration
func TestCoreLifecycle(t *testing.T) { cmd, addr := startServer(t, ctx); defer cmd.Process.Kill(); defer cleanupServer(t, cmd, addr) }
func TestMultipleApplications(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
`,
			wantRules: []string{ruleDirectServerProcessKill, ruleMissingServerCleanup},
		},
		{
			name:     "non deferred lifecycle cleanup",
			filename: "lifecycle_test.go",
			source: `package integration
func TestCoreLifecycle(t *testing.T) { cmd, addr := startServer(t, ctx); cleanupServer(t, cmd, addr) }
func TestMultipleApplications(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
`,
			wantRules: []string{ruleMissingServerCleanup},
		},
		{
			name:     "wrong lifecycle cleanup arguments",
			filename: "lifecycle_test.go",
			source: `package integration
func TestCoreLifecycle(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, otherCmd, addr) }
func TestMultipleApplications(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
`,
			wantRules: []string{ruleMissingServerCleanup},
		},
		{
			name:     "nested unreachable lifecycle cleanup",
			filename: "lifecycle_test.go",
			source: `package integration
func TestCoreLifecycle(t *testing.T) { cmd, addr := startServer(t, ctx); if false { defer cleanupServer(t, cmd, addr) } }
func TestMultipleApplications(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
`,
			wantRules: []string{ruleMissingServerCleanup},
		},
		{
			name:     "fatal path before lifecycle cleanup registration",
			filename: "lifecycle_test.go",
			source: `package integration
func TestCoreLifecycle(t *testing.T) { cmd, addr := startServer(t, ctx); if setupFailed() { t.Fatal("setup failed") }; defer cleanupServer(t, cmd, addr) }
func TestMultipleApplications(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
`,
			wantRules: []string{ruleMissingServerCleanup},
		},
		{
			name:     "shadowed lifecycle cleanup helper",
			filename: "lifecycle_test.go",
			source: `package integration
func TestCoreLifecycle(t *testing.T) { cleanupServer := func(*testing.T, *exec.Cmd, string) {}; cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
func TestMultipleApplications(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
`,
			wantRules: []string{ruleMissingServerCleanup},
		},
		{
			name:     "shadowed lifecycle start helper",
			filename: "lifecycle_test.go",
			source: `package integration
func TestCoreLifecycle(t *testing.T) { startServer := func(*testing.T, context.Context) (*exec.Cmd, string) { return nil, "" }; cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
func TestMultipleApplications(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
`,
			wantRules: []string{ruleMissingServerCleanup},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			violations, err := inspectSources(map[string]string{test.filename: test.source})
			if err != nil {
				t.Fatalf("inspect process mutation: %v", err)
			}
			if got := uniqueRuleIDs(violations); !equalStrings(got, test.wantRules) {
				t.Fatalf("rules = %v, want %v; violations:\n%s", got, test.wantRules, formatViolations(violations))
			}
		})
	}
}

func TestProcessSafetyGuardAllowsExactLifecycleCleanup(t *testing.T) {
	t.Parallel()

	source := `package integration
func TestCoreLifecycle(t *testing.T) {
	cmd, addr := startServer(t, ctx)
	defer cleanupServer(t, cmd, addr)
}
func TestMultipleApplications(t *testing.T) {
	cmd, addr := startServer(t, ctx)
	defer cleanupServer(t, cmd, addr)
}
`
	violations, err := inspectSources(map[string]string{"lifecycle_test.go": source})
	if err != nil {
		t.Fatalf("inspect exact lifecycle cleanup: %v", err)
	}
	if len(violations) != 0 {
		t.Fatalf("exact lifecycle cleanup rejected:\n%s", formatViolations(violations))
	}
}

func TestProcessSafetyGuardRejectsPackageLevelLifecycleHelperReplacement(t *testing.T) {
	t.Parallel()

	sources := map[string]string{
		"main_test.go": `package integration
import (
	"context"
	"os/exec"
	"time"
	"github.com/joeycumines/MacosUseSDK/internal/integrationfixture"
)
func startServer(t *testing.T, ctx context.Context) {
	cmd := exec.CommandContext(ctx, "../Server/.build/release/MacosUseServer")
	if err := cmd.Start(); err != nil { t.Fatal(err) }
	t.Log("waiting")
	serverCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	err := PollUntilContext(serverCtx, time.Millisecond, ready)
	if err != nil {
		if stopErr := integrationfixture.StopChild(cmd); stopErr != nil {}
		t.Fatal(err)
	}
}
var cleanupServer = func() {}
`,
		"lifecycle_test.go": `package integration
func TestCoreLifecycle(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
func TestMultipleApplications(t *testing.T) { cmd, addr := startServer(t, ctx); defer cleanupServer(t, cmd, addr) }
`,
	}
	violations, err := inspectSources(sources)
	if err != nil {
		t.Fatalf("inspect helper replacement: %v", err)
	}
	if got := uniqueRuleIDs(violations); !equalStrings(got, []string{ruleLifecycleHelperBinding}) {
		t.Fatalf("rules = %v, want %v; violations:\n%s", got, []string{ruleLifecycleHelperBinding}, formatViolations(violations))
	}
}

func TestProcessSafetyGuardRejectsUnreadyServerDirectKill(t *testing.T) {
	t.Parallel()

	source := processFixtureSource(`
		_ = cmd.Process.Kill()
		t.Fatalf("unready: %v", err)`)
	violations, err := inspectSources(map[string]string{"main_test.go": source})
	if err != nil {
		t.Fatalf("inspect unready direct kill: %v", err)
	}
	if got := uniqueRuleIDs(violations); !equalStrings(got, []string{ruleUnreadyServerCleanup}) {
		t.Fatalf("rules = %v, want %v; violations:\n%s", got, []string{ruleUnreadyServerCleanup}, formatViolations(violations))
	}
}

func TestProcessSafetyGuardAllowsUnreadyServerStopChild(t *testing.T) {
	t.Parallel()

	source := processFixtureSource(`
		if stopErr := integrationfixture.StopChild(cmd); stopErr != nil { t.Log(stopErr) }
		t.Fatalf("unready: %v", err)`)
	violations, err := inspectSources(map[string]string{"main_test.go": source})
	if err != nil {
		t.Fatalf("inspect unready StopChild: %v", err)
	}
	if len(violations) != 0 {
		t.Fatalf("exact unready StopChild rejected:\n%s", formatViolations(violations))
	}
}

func TestProcessSafetyGuardAllowsBoundedReadinessHelper(t *testing.T) {
	t.Parallel()

	source := processFixtureSource(`
		if stopErr := integrationfixture.StopChild(cmd); stopErr != nil { t.Log(stopErr) }
		t.Fatalf("unready: %v", err)`)
	source = strings.Replace(
		source,
		"PollUntilContext(serverCtx, time.Millisecond, func() bool { return false })",
		"waitForServerReadiness(serverCtx, time.Millisecond, time.Millisecond, func(context.Context) error { return nil })",
		1,
	)
	violations, err := inspectSources(map[string]string{"main_test.go": source})
	if err != nil {
		t.Fatalf("inspect bounded readiness helper: %v", err)
	}
	if len(violations) != 0 {
		t.Fatalf("bounded readiness helper rejected:\n%s", formatViolations(violations))
	}
}

func TestProcessSafetyGuardRejectsUnreadyServerCleanupBypasses(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		"unrelated decoy branch": `
	var decoy error
	if decoy != nil { t.Fatal(decoy) }`,
		"server process field mutation": `
	cmd.Process = nil`,
		"server command pointer mutation": `
	var other exec.Cmd
	*cmd = other`,
	}
	for name, inserted := range tests {
		t.Run(name, func(t *testing.T) {
			source := processFixtureSourceWithPreparation(inserted, `
		if stopErr := integrationfixture.StopChild(cmd); stopErr != nil { t.Log(stopErr) }
		t.Fatal(err)`)
			violations, err := inspectSources(map[string]string{"main_test.go": source})
			if err != nil {
				t.Fatalf("inspect cleanup bypass: %v", err)
			}
			if got := uniqueRuleIDs(violations); !equalStrings(got, []string{ruleUnreadyServerCleanup}) {
				t.Fatalf("rules = %v, want %v; violations:\n%s", got, []string{ruleUnreadyServerCleanup}, formatViolations(violations))
			}
		})
	}
}

func TestProcessSafetyGuardRejectsCleanupBindingBypasses(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name          string
		beforeCommand string
		preparation   string
		failureBody   string
	}{
		{
			name:          "shadowed integration fixture package",
			beforeCommand: "\tintegrationfixture := struct{ StopChild func(*exec.Cmd) error }{}\n",
			failureBody:   "\n\t\tif stopErr := integrationfixture.StopChild(cmd); stopErr != nil { t.Log(stopErr) }\n\t\tt.Fatal(err)",
		},
		{
			name:          "wrong command",
			beforeCommand: "\tvar otherCmd *exec.Cmd\n",
			failureBody:   "\n\t\tif stopErr := integrationfixture.StopChild(otherCmd); stopErr != nil { t.Log(stopErr) }\n\t\tt.Fatal(err)",
		},
		{
			name:          "reassigned command",
			beforeCommand: "\tvar otherCmd *exec.Cmd\n",
			preparation:   "\tcmd = otherCmd\n",
			failureBody:   "\n\t\tif stopErr := integrationfixture.StopChild(cmd); stopErr != nil { t.Log(stopErr) }\n\t\tt.Fatal(err)",
		},
		{
			name:          "non testing fatal receiver",
			beforeCommand: "\tfake := struct{ Fatal func(...any) }{}\n",
			failureBody:   "\n\t\tif stopErr := integrationfixture.StopChild(cmd); stopErr != nil { t.Log(stopErr) }\n\t\tfake.Fatal(err)",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			source := processFixtureSourceWithSegments(test.beforeCommand, test.preparation, test.failureBody)
			violations, err := inspectSources(map[string]string{"main_test.go": source})
			if err != nil {
				t.Fatalf("inspect binding bypass: %v", err)
			}
			if got := uniqueRuleIDs(violations); !equalStrings(got, []string{ruleUnreadyServerCleanup}) {
				t.Fatalf("rules = %v, want %v; violations:\n%s", got, []string{ruleUnreadyServerCleanup}, formatViolations(violations))
			}
		})
	}
}

func TestProcessSafetyGuardRejectsCleanupServerDirectKill(t *testing.T) {
	t.Parallel()

	source := `package integration
import "os/exec"
func cleanupServer(t *testing.T, cmd *exec.Cmd, addr string) {
	if cmd != nil { _ = cmd.Process.Kill() }
}
`
	violations, err := inspectSources(map[string]string{"main_test.go": source})
	if err != nil {
		t.Fatalf("inspect direct-kill cleanup: %v", err)
	}
	want := []string{ruleInvalidServerCleanup, ruleLifecycleHelperBinding}
	if got := uniqueRuleIDs(violations); !equalStrings(got, want) {
		t.Fatalf("rules = %v, want %v; violations:\n%s", got, want, formatViolations(violations))
	}
}

func processFixtureSource(failureBody string) string {
	return processFixtureSourceWithPreparation("", failureBody)
}

func processFixtureSourceWithPreparation(preparation, failureBody string) string {
	return processFixtureSourceWithSegments("", preparation, failureBody)
}

func processFixtureSourceWithSegments(beforeCommand, preparation, failureBody string) string {
	return `package integration
import (
	"context"
	"os/exec"
	"time"
	"github.com/joeycumines/MacosUseSDK/internal/integrationfixture"
)
func cleanupServer(t *testing.T, cmd *exec.Cmd, addr string) {
	if cmd != nil {
		if stopErr := integrationfixture.StopChild(cmd); stopErr != nil { return }
	}
}
func startServer(t *testing.T, ctx context.Context) {
` + beforeCommand + `	cmd := exec.CommandContext(ctx, "../Server/.build/release/MacosUseServer")
	if err := cmd.Start(); err != nil { t.Fatal(err) }
` + preparation + `
	t.Log("waiting")
	serverCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	err := PollUntilContext(serverCtx, time.Millisecond, func() bool { return false })
	if err != nil {` + failureBody + `
	}
}
`
}
