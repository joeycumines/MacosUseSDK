package integrationguard

import (
	"path/filepath"
	"testing"
)

func TestAutomaticIntegrationContainsNoPhysicalDrag(t *testing.T) {
	t.Parallel()

	repositoryRoot := locateRepositoryRoot(t)
	violations, err := inspectIntegrationDirectory(filepath.Join(repositoryRoot, "integration"))
	if err != nil {
		t.Fatalf("scan automatic integration: %v", err)
	}
	if len(violations) != 0 {
		t.Fatalf("automatic integration safety violations:\n%s", formatViolations(violations))
	}
}

func TestDragSafetyGuardRejectsMutations(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		filename  string
		source    string
		wantRules []string
	}{
		{
			name:     "former close then wildcard drag sequence",
			filename: "drag_operation_test.go",
			source: `package integration
func first() { _ = pb.InputAction_Drag{Drag: &pb.MouseDrag{}}; client.CloseWindow(ctx, closeRequest) }
func TestDragOperation_InputStateTracking() { _ = pb.CreateInputRequest{Parent: "applications/-", Input: &pb.Input{Action: &pb.InputAction{InputType: &pb.InputAction_Drag{Drag: &pb.MouseDrag{}}}}} }
`,
			wantRules: []string{ruleDragSymbol},
		},
		{
			name:      "application parent does not make global drag safe",
			filename:  "apparently_owned_test.go",
			source:    "package integration\nvar _ = pb.CreateInputRequest{Parent: app.Name, Input: &pb.Input{Action: &pb.InputAction{InputType: &pb.InputAction_Drag{Drag: &pb.MouseDrag{}}}}}\n",
			wantRules: []string{ruleDragSymbol},
		},
		{
			name:      "renamed file remains covered",
			filename:  "unrelated_new_name.go",
			source:    "package integration\nvar _ = pb.MouseDrag{}\n",
			wantRules: []string{ruleDragSymbol},
		},
		{
			name:      "dot imported generated symbols",
			filename:  "dot_import_test.go",
			source:    "package integration\nvar _ = InputAction_Drag{Drag: &MouseDrag{}}\n",
			wantRules: []string{ruleDragSymbol},
		},
		{
			name:      "aliased generated drag type",
			filename:  "alias_test.go",
			source:    "package integration\ntype unsafeDrag = pb.InputAction_Drag\n",
			wantRules: []string{ruleDragSymbol},
		},
		{
			name:      "raw JSON tool invocation",
			filename:  "raw_json_test.go",
			source:    "package integration\nvar request = `{" + `"jsonrpc":"2.0","method":"tools/call","params":{"name":"drag","arguments":{}}` + "}`\n",
			wantRules: []string{ruleDragToolsCallJSON},
		},
		{
			name:     "map built tool invocation",
			filename: "map_call_test.go",
			source: `package integration
var request = map[string]any{"method": "tools/call", "params": map[string]any{"name": "drag"}}
`,
			wantRules: []string{ruleDragToolName, ruleDragToolsCallComposite},
		},
		{
			name:     "table driven tool invocation",
			filename: "mcp_tools_test.go",
			source: `package integration
func test() {
	tests := []struct{ tool string }{{tool: "drag"}}
	for _, item := range tests {
		_ = map[string]any{"method": "tools/call", "params": map[string]any{"name": item.tool}}
	}
}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "split request composites",
			filename: "split_call_test.go",
			source: `package integration
func test() {
	params := map[string]any{"name": "drag"}
	_ = map[string]any{"method": "tools/call", "params": params}
}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "description shaped split request",
			filename: "mcp_protocol_test.go",
			source: `package integration
var params = map[string]any{"name": "drag", "description": "Drag", "inputSchema": map[string]any{}}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:      "binary computed drag name",
			filename:  "computed_drag_test.go",
			source:    "package integration\nconst dragTool = \"dr\" + \"ag\"\nvar request = map[string]any{\"name\": dragTool}\n",
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "local implicit constant drag name",
			filename: "local_implicit_drag_test.go",
			source: `package integration
func test() {
	const (
		prefix = "dr"
		alias
		suffix = "ag"
	)
	_ = map[string]any{"name": alias + suffix}
}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "named string conversion of a string",
			filename: "named_string_test.go",
			source: `package integration
type text string
const dragTool = text("d") + "rag"
var request = map[string]any{"name": dragTool}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "parenthesized named string conversion",
			filename: "parenthesized_string_test.go",
			source: `package integration
type text (string)
const dragTool = text("d") + "rag"
var request = map[string]any{"name": dragTool}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "standard library named string conversion",
			filename: "imported_string_test.go",
			source: `package integration
import "encoding/json"
const dragTool = json.Number("d") + "rag"
var request = map[string]any{"name": dragTool}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "nested integer conversion",
			filename: "nested_conversion_test.go",
			source: `package integration
const dragTool = string(byte(100)) + "rag"
var request = map[string]any{"name": dragTool}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "arbitrary precision integer conversion",
			filename: "arbitrary_precision_test.go",
			source: `package integration
const dragTool = string(((1 << 100) * 100) / (1 << 100)) + "rag"
var request = map[string]any{"name": dragTool}
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "iota shifts and complement",
			filename: "iota_shift_test.go",
			source: `package integration
const (
	zero = iota
	code = 99 + iota
)
const shifted = string((1<<6)+36) + "rag"
const complemented = string(^(-101)) + "rag"
const fromIota = string(code) + "rag"
`,
			wantRules: []string{ruleDragToolName},
		},
		{
			name:     "computed raw JSON drag call",
			filename: "computed_json_test.go",
			source: `package integration
const prefix = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"dr"
const request = prefix + "ag\",\"arguments\":{}}}"
`,
			wantRules: []string{ruleDragToolsCallJSON},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			violations, err := inspectSources(map[string]string{test.filename: test.source})
			if err != nil {
				t.Fatalf("inspect drag mutation: %v", err)
			}
			if got := uniqueRuleIDs(violations); !equalStrings(got, test.wantRules) {
				t.Fatalf("rules = %v, want %v; violations:\n%s", got, test.wantRules, formatViolations(violations))
			}
		})
	}
}

func TestDragSafetyGuardRejectsCrossFileConstants(t *testing.T) {
	t.Parallel()

	tests := []map[string]string{
		{
			"constants_test.go": `package integration
const (
	unsafePrefix = "dr"
	unsafeAlias
	unsafeSuffix = "ag"
)
`,
			"invocation_test.go": `package integration
var request = map[string]any{"name": unsafeAlias + unsafeSuffix}
`,
		},
		{
			"types_test.go":     "package integration\ntype base string\ntype text base\n",
			"constants_test.go": "package integration\nconst dragTool = text(\"d\") + \"rag\"\n",
			"invocation_test.go": `package integration
var request = map[string]any{"name": dragTool}
`,
		},
		{
			"unsafe_test.go": `package integration
func unsafe() {
	const prefix = "d"
	const name = prefix + "rag"
	_ = map[string]any{"name": name}
}
`,
			"safe_test.go": `package integration
func safe() {
	const prefix = "s"
	const name = prefix + "afe"
	_ = name
}
`,
		},
	}

	for _, sources := range tests {
		violations, err := inspectSources(sources)
		if err != nil {
			t.Fatalf("inspect cross-file constants: %v", err)
		}
		if got := uniqueRuleIDs(violations); !equalStrings(got, []string{ruleDragToolName}) {
			t.Fatalf("rules = %v, want %v; violations:\n%s", got, []string{ruleDragToolName}, formatViolations(violations))
		}
	}
}

func TestDragSafetyGuardAllowsOnlyBoundedProofContexts(t *testing.T) {
	t.Parallel()

	allowed := map[string]string{
		"physical_input_truth_test.go": `package integration
type ownedDragPoint struct{ x, y float64 }
type ownedTextEditDragCall struct {
	toolName string
	action *pb.InputAction
}
func requireOwnedTextEditDrag(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
	path []ownedDragPoint,
	duration float64,
) ownedTextEditDragCall {
	geometry := requireCurrentOwnedTextEditGeometry(t, ctx, client, fixture)
	for _, point := range path {
		requireOwnedDragPoint(t, geometry, point)
	}
	return ownedTextEditDragCall{
		toolName: "drag",
		action: &pb.InputAction{InputType: &pb.InputAction_Drag{Drag: &pb.MouseDrag{}}},
	}
}
`,
		"inputadmission_test.go": `package integration
func nonPhysicalInputAdmissionDragCase() physicalInputAdmissionCase {
	return physicalInputAdmissionCase{
		name: "drag",
		wantAction: &pb.InputAction{InputType: &pb.InputAction_Drag{Drag: &pb.MouseDrag{}}},
	}
}
`,
		"nonapplicationmatrix_test.go": `package integration
var safeNonApplicationAdmissionFixtures = map[string]map[string]any{
	"drag": {"target": "desktop"},
}
var safeNonApplicationFirstRPC = map[string]string{
	"drag": "CreateInput",
}
`,
	}
	violations, err := inspectSources(allowed)
	if err != nil {
		t.Fatalf("inspect bounded drag proof contexts: %v", err)
	}
	if len(violations) != 0 {
		t.Fatalf("bounded drag proof contexts were rejected:\n%s", formatViolations(violations))
	}
}

func TestDragSafetyGuardRejectsMutatedOwnedDragChokePoint(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		filename string
		source   string
	}{
		{
			name:     "wrong file",
			filename: "renamed_physical_test.go",
			source: `package integration
func requireOwnedTextEditDrag(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
	path []ownedDragPoint,
	duration float64,
) ownedTextEditDragCall {
	geometry := requireCurrentOwnedTextEditGeometry(t, ctx, client, fixture)
	for _, point := range path { requireOwnedDragPoint(t, geometry, point) }
	return ownedTextEditDragCall{toolName: "drag"}
}
`,
		},
		{
			name:     "missing live geometry",
			filename: "physical_input_truth_test.go",
			source: `package integration
func requireOwnedTextEditDrag(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
	path []ownedDragPoint,
	duration float64,
) ownedTextEditDragCall {
	for _, point := range path { requireOwnedDragPoint(t, fixture, point) }
	return ownedTextEditDragCall{toolName: "drag"}
}
`,
		},
		{
			name:     "missing point validation",
			filename: "physical_input_truth_test.go",
			source: `package integration
func requireOwnedTextEditDrag(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
	path []ownedDragPoint,
	duration float64,
) ownedTextEditDragCall {
	_ = requireCurrentOwnedTextEditGeometry(t, ctx, client, fixture)
	return ownedTextEditDragCall{toolName: "drag"}
}
`,
		},
		{
			name:     "wrong return type",
			filename: "physical_input_truth_test.go",
			source: `package integration
func requireOwnedTextEditDrag(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	fixture *keyboardTextEditFixture,
	path []ownedDragPoint,
	duration float64,
) string {
	geometry := requireCurrentOwnedTextEditGeometry(t, ctx, client, fixture)
	for _, point := range path { requireOwnedDragPoint(t, geometry, point) }
	return "drag"
}
`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			violations, err := inspectSources(map[string]string{test.filename: test.source})
			if err != nil {
				t.Fatalf("inspect mutated choke point: %v", err)
			}
			if len(violations) == 0 {
				t.Fatal("mutated owned-drag choke point was accepted")
			}
		})
	}
}

func TestDragSafetyGuardAllowsRuntimeAndNonDragStrings(t *testing.T) {
	t.Parallel()

	tests := []map[string]string{
		{"ordinary_call_test.go": "package integration\nimport \"strconv\"\nvar value = strconv.Itoa(100) + \"rag\"\n"},
		{"tools_list_inventory_test.go": "package integration\nvar seen map[string]struct{}\nvar _, found = seen[\"drag\"]\n"},
		{"arbitrary_precision_safe_test.go": "package integration\nconst value = string(((1 << 32) + 100) % 101) + \"rag\"\n"},
		{
			"definition.go": "package integration\nimport \"encoding/json\"\nvar string = func(int) json.Number { return \"safe\" }\n",
			"use.go":        "package integration\nvar value = string(100) + \"rag\"\n",
		},
	}
	for _, sources := range tests {
		violations, err := inspectSources(sources)
		if err != nil {
			t.Fatalf("inspect non-drag string: %v", err)
		}
		if len(violations) != 0 {
			t.Fatalf("non-drag string rejected:\n%s", formatViolations(violations))
		}
	}
}

func TestDragSafetyGuardFailsClosedOnMalformedSource(t *testing.T) {
	t.Parallel()

	if _, err := inspectSources(map[string]string{"broken_test.go": "package integration\nfunc broken("}); err == nil {
		t.Fatal("malformed integration source was accepted")
	}
}
