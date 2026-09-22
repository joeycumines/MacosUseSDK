package integrationguard

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/tools/go/packages"
)

const (
	ruleDragSymbol               = "drag-symbol"
	ruleDragToolName             = "drag-tool-name"
	ruleDragToolsCallJSON        = "drag-tools-call-json"
	ruleDragToolsCallComposite   = "drag-tools-call-composite"
	ruleDynamicCommandExecutable = "dynamic-command-executable"
	ruleLifecycleHelperBinding   = "lifecycle-helper-binding"
	ruleServerWideKill           = "server-wide-kill"
	ruleStrayServerHelper        = "stray-server-helper"
	ruleDirectServerProcessKill  = "direct-server-process-kill"
	ruleInvalidServerCleanup     = "invalid-server-cleanup"
	ruleMissingServerCleanup     = "missing-server-cleanup"
	ruleUnreadyServerCleanup     = "unready-server-cleanup"
)

type violation struct {
	rule     string
	filename string
	position token.Position
}

type parsedSource struct {
	fileSet *token.FileSet
	file    *ast.File
}

func (v violation) String() string {
	return fmt.Sprintf("%s: %s:%d:%d", v.rule, v.filename, v.position.Line, v.position.Column)
}

func locateRepositoryRoot(t *testing.T) string {
	t.Helper()

	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller could not locate integration guard")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(thisFile), "..", ".."))
}

func inspectIntegrationDirectory(root string) ([]violation, error) {
	filesOnDisk := make(map[string]struct{})
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || filepath.Ext(path) != ".go" {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		filesOnDisk[filepath.ToSlash(relative)] = struct{}{}
		return nil
	})
	if err != nil {
		return nil, err
	}

	loaded, err := packages.Load(&packages.Config{
		Mode: packages.NeedName | packages.NeedFiles | packages.NeedCompiledGoFiles | packages.NeedSyntax |
			packages.NeedTypes | packages.NeedTypesInfo | packages.NeedImports | packages.NeedDeps | packages.NeedModule,
		Dir:   root,
		Tests: true,
	}, ".")
	if err != nil {
		return nil, fmt.Errorf("load automatic integration package: %w", err)
	}
	var selected *packages.Package
	selectedFileCount := -1
	for _, candidate := range loaded {
		if candidate.Name != "integration" || len(candidate.Syntax) <= selectedFileCount {
			continue
		}
		selected = candidate
		selectedFileCount = len(candidate.Syntax)
	}
	if selected == nil || selected.Fset == nil || selected.TypesInfo == nil {
		return nil, fmt.Errorf("load automatic integration package: complete test variant not found")
	}
	if len(selected.Errors) != 0 {
		return nil, fmt.Errorf("type-check automatic integration package: %s", formatPackageErrors(selected.Errors))
	}

	parsed := make(map[string]parsedSource, len(selected.Syntax))
	for index, file := range selected.Syntax {
		if index >= len(selected.CompiledGoFiles) {
			return nil, fmt.Errorf("type-check automatic integration package: syntax/file inventory mismatch")
		}
		relative, err := filepath.Rel(root, selected.CompiledGoFiles[index])
		if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			continue
		}
		filename := filepath.ToSlash(relative)
		parsed[filename] = parsedSource{fileSet: selected.Fset, file: file}
	}
	for filename := range filesOnDisk {
		if _, ok := parsed[filename]; !ok {
			loadedNames := make([]string, 0, len(parsed))
			for loadedName := range parsed {
				loadedNames = append(loadedNames, loadedName)
			}
			sort.Strings(loadedNames)
			return nil, fmt.Errorf(
				"automatic integration source %s was excluded from package %s; loaded=%s",
				filename,
				selected.ID,
				strings.Join(loadedNames, ","),
			)
		}
	}
	return inspectParsedSources(parsed, constantResolverFromTypesInfo(selected.TypesInfo))
}

func formatPackageErrors(errors []packages.Error) string {
	formatted := make([]string, len(errors))
	for index, typeError := range errors {
		formatted[index] = typeError.Error()
	}
	return strings.Join(formatted, "; ")
}

func inspectSources(sources map[string]string) ([]violation, error) {
	filenames := make([]string, 0, len(sources))
	for filename := range sources {
		filenames = append(filenames, filename)
	}
	sort.Strings(filenames)

	parsed := make(map[string]parsedSource, len(filenames))
	fileSet := token.NewFileSet()
	for _, filename := range filenames {
		file, err := parser.ParseFile(fileSet, filename, sources[filename], 0)
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", filename, err)
		}
		parsed[filename] = parsedSource{fileSet: fileSet, file: file}
	}

	return inspectParsedSources(parsed, newConstantResolver(parsed))
}

func inspectParsedSources(parsed map[string]parsedSource, constants constantResolver) ([]violation, error) {
	filenames := make([]string, 0, len(parsed))
	for filename := range parsed {
		filenames = append(filenames, filename)
	}
	sort.Strings(filenames)

	var violations []violation
	for _, filename := range filenames {
		source := parsed[filename]
		violations = append(violations, inspectFile(source.fileSet, filename, source.file, constants)...)
	}
	if mainSource, ok := parsed["main_test.go"]; ok {
		for _, helperName := range []string{"startServer", "cleanupServer"} {
			count := 0
			valid := true
			for filename, source := range parsed {
				for _, declaration := range source.file.Decls {
					switch typed := declaration.(type) {
					case *ast.FuncDecl:
						if typed.Name.Name == helperName {
							count++
							valid = valid && filename == "main_test.go"
						}
					case *ast.GenDecl:
						if declarationDefinesName(typed, helperName) {
							valid = false
						}
					}
				}
			}
			if count != 1 || !valid {
				violations = append(violations, violation{
					rule: ruleLifecycleHelperBinding, filename: "main_test.go", position: mainSource.fileSet.Position(mainSource.file.Pos()),
				})
			}
		}
	}
	sort.Slice(violations, func(i, j int) bool {
		left, right := violations[i], violations[j]
		if left.filename != right.filename {
			return left.filename < right.filename
		}
		if left.position.Offset != right.position.Offset {
			return left.position.Offset < right.position.Offset
		}
		return left.rule < right.rule
	})
	return violations, nil
}

func inspectFile(fileSet *token.FileSet, filename string, file *ast.File, constants constantResolver) []violation {
	var violations []violation
	cleanupFunctions := map[string]bool{}
	allowedServerExecutables := allowedServerExecutablePositions(filename, file)
	allowedProcessWideKillCommands := allowedProcessWideKillCommandPositions(file)
	allowedCommandCallees := directCommandCalleePositions(file)
	readOnlyIndexStrings := readOnlyIndexStringPositions(file)
	allowedDragProof := allowedDragProofPositions(filename, file)

	add := func(rule string, position token.Pos) {
		violations = append(violations, violation{rule: rule, filename: filename, position: fileSet.Position(position)})
	}

	ast.Inspect(file, func(node ast.Node) bool {
		switch typed := node.(type) {
		case *ast.Ident:
			if typed.Name == "InputAction_Drag" || typed.Name == "MouseDrag" {
				if _, allowed := allowedDragProof[typed.Pos()]; !allowed {
					add(ruleDragSymbol, typed.Pos())
				}
			}
			if typed.Name == "Command" || typed.Name == "CommandContext" {
				if _, allowed := allowedCommandCallees[typed.Pos()]; !allowed {
					add(ruleDynamicCommandExecutable, typed.Pos())
				}
			}
			if value, ok := constantStringValue(typed, constants); ok {
				if _, allowed := allowedDragProof[typed.Pos()]; !allowed {
					addComputedStringViolations(add, typed.Pos(), value)
				}
			}
		case *ast.BasicLit:
			if typed.Kind == token.STRING {
				if _, allowed := allowedDragProof[typed.Pos()]; !allowed {
					if literalCallsDragTool(typed.Value) {
						add(ruleDragToolsCallJSON, typed.Pos())
					}
				}
				value := stringValue(typed)
				if value == "drag" {
					if _, readOnly := readOnlyIndexStrings[typed.Pos()]; readOnly {
						break
					}
					if _, allowed := allowedDragProof[typed.Pos()]; !allowed {
						add(ruleDragToolName, typed.Pos())
					}
				}
				if strings.Contains(value, "ExactMacServer") {
					if _, allowed := allowedServerExecutables[typed.Pos()]; !allowed {
						add(ruleServerWideKill, typed.Pos())
					}
				}
				if isProcessWideKillCommand(value) {
					if _, allowed := allowedProcessWideKillCommands[typed.Pos()]; !allowed {
						add(ruleServerWideKill, typed.Pos())
					}
				}
			}
		case *ast.BinaryExpr:
			if value, ok := constantStringValue(typed, constants); ok {
				if _, allowed := allowedDragProof[typed.Pos()]; !allowed {
					addComputedStringViolations(add, typed.Pos(), value)
				}
			}
		case *ast.CompositeLit:
			if compositeHasStringPair(typed, "method", "tools/call") && compositeHasStringPair(typed, "name", "drag") {
				if _, allowed := allowedDragProof[typed.Pos()]; !allowed {
					add(ruleDragToolsCallComposite, typed.Pos())
				}
			}
		case *ast.FuncDecl:
			if typed.Name.Name == "killStrayServers" {
				add(ruleStrayServerHelper, typed.Name.Pos())
			}
			if filename == "lifecycle_test.go" && (typed.Name.Name == "TestCoreLifecycle" || typed.Name.Name == "TestMultipleApplications") {
				cleanupFunctions[typed.Name.Name] = hasExactDeferredServerCleanup(typed)
			}
			if filename == "main_test.go" && typed.Name.Name == "startServer" && !hasUnreadyServerCleanup(file, typed) {
				add(ruleUnreadyServerCleanup, typed.Name.Pos())
			}
			if filename == "main_test.go" && typed.Name.Name == "cleanupServer" && !hasExactCleanupServerBody(file, typed) {
				add(ruleInvalidServerCleanup, typed.Name.Pos())
			}
		case *ast.CallExpr:
			if calledFunctionName(typed.Fun) == "killStrayServers" {
				add(ruleStrayServerHelper, typed.Pos())
			}
			if executable, ok := commandExecutable(typed); ok && stringValue(executable) == "" {
				add(ruleDynamicCommandExecutable, executable.Pos())
			}
			if filename == "lifecycle_test.go" && hasSelectorSuffix(selectorChain(typed.Fun), "Process", "Kill") {
				add(ruleDirectServerProcessKill, typed.Pos())
			}
		}
		return true
	})

	if filename == "lifecycle_test.go" {
		for _, functionName := range []string{"TestCoreLifecycle", "TestMultipleApplications"} {
			if !cleanupFunctions[functionName] {
				add(ruleMissingServerCleanup, file.Pos())
			}
		}
	}
	return violations
}

func allowedDragProofPositions(filename string, file *ast.File) map[token.Pos]struct{} {
	positions := make(map[token.Pos]struct{})
	addTree := func(node ast.Node) {
		ast.Inspect(node, func(child ast.Node) bool {
			if child != nil {
				positions[child.Pos()] = struct{}{}
			}
			return true
		})
	}

	switch filename {
	case "physical_input_truth_test.go":
		for _, declaration := range file.Decls {
			function, ok := declaration.(*ast.FuncDecl)
			if !ok || !isOwnedTextEditDragChokePoint(function) {
				continue
			}
			addTree(function.Body)
		}
	case "inputadmission_test.go":
		for _, declaration := range file.Decls {
			function, ok := declaration.(*ast.FuncDecl)
			if !ok || !isNonPhysicalInputAdmissionDragCase(function) {
				continue
			}
			addTree(function.Body)
		}
	case "nonapplicationmatrix_test.go":
		for _, declaration := range file.Decls {
			general, ok := declaration.(*ast.GenDecl)
			if !ok {
				continue
			}
			for _, specification := range general.Specs {
				value, ok := specification.(*ast.ValueSpec)
				if !ok || len(value.Names) != 1 {
					continue
				}
				switch value.Names[0].Name {
				case "safeNonApplicationAdmissionFixtures", "safeNonApplicationFirstRPC":
					for _, expression := range value.Values {
						addTree(expression)
					}
				}
			}
		}
	}
	return positions
}

func isOwnedTextEditDragChokePoint(function *ast.FuncDecl) bool {
	if function.Name == nil || function.Name.Name != "requireOwnedTextEditDrag" ||
		function.Recv != nil || function.Type == nil ||
		function.Type.Params == nil || function.Type.Results == nil ||
		fieldArity(function.Type.Params) != 6 ||
		fieldArity(function.Type.Results) != 1 ||
		!fieldListContainsIdentifier(function.Type.Results, "ownedTextEditDragCall") {
		return false
	}
	return functionCalls(function, "requireCurrentOwnedTextEditGeometry") &&
		functionCalls(function, "requireOwnedDragPoint")
}

func isNonPhysicalInputAdmissionDragCase(function *ast.FuncDecl) bool {
	return function.Name != nil &&
		function.Name.Name == "nonPhysicalInputAdmissionDragCase" &&
		function.Recv == nil &&
		function.Type != nil &&
		fieldArity(function.Type.Params) == 0 &&
		fieldArity(function.Type.Results) == 1 &&
		fieldListContainsIdentifier(function.Type.Results, "physicalInputAdmissionCase")
}

func fieldArity(fields *ast.FieldList) int {
	if fields == nil {
		return 0
	}
	count := 0
	for _, field := range fields.List {
		if len(field.Names) == 0 {
			count++
			continue
		}
		count += len(field.Names)
	}
	return count
}

func fieldListContainsIdentifier(fields *ast.FieldList, name string) bool {
	if fields == nil || len(fields.List) != 1 {
		return false
	}
	identifier, ok := fields.List[0].Type.(*ast.Ident)
	return ok && identifier.Name == name
}

func functionCalls(function *ast.FuncDecl, name string) bool {
	found := false
	ast.Inspect(function.Body, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if ok && calledFunctionName(call.Fun) == name {
			found = true
			return false
		}
		return !found
	})
	return found
}

// readOnlyIndexStringPositions identifies literals used only to inspect a map
// or slice. Reading tools/list metadata such as seen["drag"] cannot post input
// and must not be confused with constructing a tools/call invocation.
func readOnlyIndexStringPositions(file *ast.File) map[token.Pos]struct{} {
	positions := make(map[token.Pos]struct{})
	ast.Inspect(file, func(node ast.Node) bool {
		index, ok := node.(*ast.IndexExpr)
		if !ok {
			return true
		}
		literal, ok := index.Index.(*ast.BasicLit)
		if ok && literal.Kind == token.STRING {
			positions[literal.Pos()] = struct{}{}
		}
		return true
	})
	return positions
}

func literalCallsDragTool(quoted string) bool {
	decoded, err := strconv.Unquote(quoted)
	if err != nil {
		return false
	}
	return stringCallsDragTool(decoded)
}

func stringCallsDragTool(decoded string) bool {
	var request map[string]any
	if json.Unmarshal([]byte(decoded), &request) != nil || request["method"] != "tools/call" {
		return false
	}
	params, ok := request["params"].(map[string]any)
	return ok && params["name"] == "drag"
}

func addComputedStringViolations(add func(string, token.Pos), position token.Pos, value string) {
	if value == "drag" {
		add(ruleDragToolName, position)
	}
	if stringCallsDragTool(value) {
		add(ruleDragToolsCallJSON, position)
	}
	if strings.Contains(value, "ExactMacServer") || isProcessWideKillCommand(value) {
		add(ruleServerWideKill, position)
	}
}

func uniqueRuleIDs(violations []violation) []string {
	seen := map[string]struct{}{}
	for _, violation := range violations {
		seen[violation.rule] = struct{}{}
	}
	rules := make([]string, 0, len(seen))
	for rule := range seen {
		rules = append(rules, rule)
	}
	sort.Strings(rules)
	return rules
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func formatViolations(violations []violation) string {
	lines := make([]string, len(violations))
	for index, violation := range violations {
		lines[index] = violation.String()
	}
	return strings.Join(lines, "\n")
}
