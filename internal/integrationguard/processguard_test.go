package integrationguard

import (
	"go/ast"
	"go/token"
	"slices"
	"strconv"
	"strings"
)

const (
	contextImportPath            = "context"
	integrationFixtureImportPath = "github.com/joeycumines/ExactMac/internal/integrationfixture"
	osExecImportPath             = "os/exec"
)

type identifierBinding struct {
	name        string
	declaration any
}

func declarationDefinesName(declaration *ast.GenDecl, name string) bool {
	for _, spec := range declaration.Specs {
		switch typed := spec.(type) {
		case *ast.ValueSpec:
			for _, identifier := range typed.Names {
				if identifier.Name == name {
					return true
				}
			}
		case *ast.TypeSpec:
			if typed.Name.Name == name {
				return true
			}
		}
	}
	return false
}

func compositeHasStringPair(literal *ast.CompositeLit, key, value string) bool {
	found := false
	ast.Inspect(literal, func(node ast.Node) bool {
		pair, ok := node.(*ast.KeyValueExpr)
		if !ok || expressionName(pair.Key) != key || stringValue(pair.Value) != value {
			return !found
		}
		found = true
		return false
	})
	return found
}

func allowedServerExecutablePositions(filename string, file *ast.File) map[token.Pos]struct{} {
	allowed := make(map[token.Pos]struct{})
	if filename != "main_test.go" {
		return allowed
	}
	for _, declaration := range file.Decls {
		function, ok := declaration.(*ast.FuncDecl)
		if !ok || function.Name.Name != "startServer" {
			continue
		}
		ast.Inspect(function.Body, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok || strings.Join(selectorChain(call.Fun), ".") != "exec.CommandContext" || len(call.Args) != 2 {
				return true
			}
			if stringValue(call.Args[1]) == "../Server/.build/release/ExactMacServer" {
				allowed[call.Args[1].Pos()] = struct{}{}
			}
			return true
		})
	}
	return allowed
}

func allowedProcessWideKillCommandPositions(file *ast.File) map[token.Pos]struct{} {
	allowed := make(map[token.Pos]struct{})
	ast.Inspect(file, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok || strings.Join(selectorChain(call.Fun), ".") != "exec.Command" || len(call.Args) != 3 {
			return true
		}
		target := stringValue(call.Args[2])
		if isProcessWideKillCommand(stringValue(call.Args[0])) && stringValue(call.Args[1]) == "-9" &&
			(target == "Calculator" || target == "TextEdit") {
			allowed[call.Args[0].Pos()] = struct{}{}
		}
		return true
	})
	return allowed
}

func isProcessWideKillCommand(value string) bool {
	return value == "killall" || value == "/usr/bin/killall" || value == "pkill" || value == "/usr/bin/pkill"
}

func commandExecutable(call *ast.CallExpr) (ast.Expr, bool) {
	switch calledFunctionName(call.Fun) {
	case "Command":
		if len(call.Args) >= 1 {
			return call.Args[0], true
		}
	case "CommandContext":
		if len(call.Args) >= 2 {
			return call.Args[1], true
		}
	}
	return nil, false
}

func directCommandCalleePositions(file *ast.File) map[token.Pos]struct{} {
	positions := make(map[token.Pos]struct{})
	ast.Inspect(file, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}
		switch calledFunctionName(call.Fun) {
		case "Command", "CommandContext":
			if identifier := terminalIdentifier(call.Fun); identifier != nil {
				positions[identifier.Pos()] = struct{}{}
			}
		}
		return true
	})
	return positions
}

func terminalIdentifier(expression ast.Expr) *ast.Ident {
	switch typed := expression.(type) {
	case *ast.Ident:
		return typed
	case *ast.SelectorExpr:
		return typed.Sel
	default:
		return nil
	}
}

func hasExactDeferredServerCleanup(function *ast.FuncDecl) bool {
	if function.Body == nil {
		return false
	}
	var commandName, addressName string
	startIndex := -1
	startCount := 0
	for index, statement := range function.Body.List {
		assignment, ok := statement.(*ast.AssignStmt)
		if !ok || len(assignment.Lhs) != 2 || len(assignment.Rhs) != 1 {
			continue
		}
		call, ok := assignment.Rhs[0].(*ast.CallExpr)
		if !ok || !isUnshadowedFunctionCall(call, "startServer") {
			continue
		}
		command, commandOK := assignment.Lhs[0].(*ast.Ident)
		address, addressOK := assignment.Lhs[1].(*ast.Ident)
		if !commandOK || !addressOK {
			return false
		}
		startCount++
		startIndex = index
		commandName = command.Name
		addressName = address.Name
	}
	if startCount != 1 || startIndex+1 >= len(function.Body.List) {
		return false
	}
	deferred, ok := function.Body.List[startIndex+1].(*ast.DeferStmt)
	return ok && isUnshadowedFunctionCall(deferred.Call, "cleanupServer") && len(deferred.Call.Args) == 3 &&
		identifierName(deferred.Call.Args[0]) == "t" && identifierName(deferred.Call.Args[1]) == commandName &&
		identifierName(deferred.Call.Args[2]) == addressName
}

func hasExactCleanupServerBody(file *ast.File, function *ast.FuncDecl) bool {
	command, ok := functionParameterBinding(function, "cmd")
	if !ok || function.Body == nil || len(function.Body.List) != 1 {
		return false
	}
	outer, ok := function.Body.List[0].(*ast.IfStmt)
	if !ok {
		return false
	}
	stopIndex := -1
	stopCount := 0
	for index, statement := range outer.Body.List {
		if processKillUsesBinding(statement, command) {
			return false
		}
		check, ok := statement.(*ast.IfStmt)
		if !ok {
			continue
		}
		assignment, ok := check.Init.(*ast.AssignStmt)
		if !ok || len(assignment.Rhs) != 1 {
			continue
		}
		call, ok := assignment.Rhs[0].(*ast.CallExpr)
		if !ok || !isImportedSelectorCall(file, call, integrationFixtureImportPath, "StopChild") ||
			len(call.Args) != 1 || !expressionMatchesBinding(call.Args[0], command) {
			continue
		}
		stopCount++
		stopIndex = index
	}
	if stopCount != 1 {
		return false
	}
	return !slices.ContainsFunc(outer.Body.List[:stopIndex], statementCanExit)
}

func hasUnreadyServerCleanup(file *ast.File, function *ast.FuncDecl) bool {
	if function.Body == nil {
		return false
	}
	command, commandIndex, ok := exactServerChildBinding(file, function)
	if !ok {
		return false
	}
	testHandle, ok := functionParameterBinding(function, "t")
	if !ok {
		return false
	}
	startIndex, ok := exactServerChildStart(function, command, testHandle)
	if !ok || startIndex <= commandIndex {
		return false
	}
	for _, statement := range function.Body.List[commandIndex+1 : startIndex] {
		if statementMutatesBindingExceptFields(statement, command, "Env", "Stdout", "Stderr") {
			return false
		}
	}

	readinessIndex := -1
	var readinessError identifierBinding
	var readinessCall *ast.CallExpr
	for index := startIndex + 1; index < len(function.Body.List); index++ {
		assignment, ok := function.Body.List[index].(*ast.AssignStmt)
		if !ok || len(assignment.Lhs) != 1 || len(assignment.Rhs) != 1 {
			continue
		}
		call, ok := assignment.Rhs[0].(*ast.CallExpr)
		if !ok || (!isUnshadowedFunctionCall(call, "PollUntilContext") &&
			!isUnshadowedFunctionCall(call, "waitForServerReadiness")) {
			continue
		}
		identifier, ok := assignment.Lhs[0].(*ast.Ident)
		if !ok || readinessIndex != -1 {
			return false
		}
		readinessIndex = index
		readinessError = bindingForIdentifier(identifier)
		readinessCall = call
	}
	if readinessIndex == -1 || readinessIndex+1 >= len(function.Body.List) {
		return false
	}
	serverContext, ok := exactReadinessPreparation(file, function, startIndex, readinessIndex, testHandle)
	expectedArgumentCount := 3
	if isUnshadowedFunctionCall(readinessCall, "waitForServerReadiness") {
		expectedArgumentCount = 4
	}
	if !ok || len(readinessCall.Args) != expectedArgumentCount ||
		!expressionMatchesBinding(readinessCall.Args[0], serverContext) {
		return false
	}
	for _, statement := range function.Body.List[startIndex+1 : readinessIndex+1] {
		if statementMutatesBindingExceptFields(statement, command) {
			return false
		}
	}

	failure, ok := function.Body.List[readinessIndex+1].(*ast.IfStmt)
	if !ok || failure.Init != nil || !isBindingNotNil(failure.Cond, readinessError) || len(failure.Body.List) < 2 {
		return false
	}
	cleanupCheck, ok := failure.Body.List[0].(*ast.IfStmt)
	if !ok {
		return false
	}
	assignment, ok := cleanupCheck.Init.(*ast.AssignStmt)
	if !ok || len(assignment.Rhs) != 1 {
		return false
	}
	call, ok := assignment.Rhs[0].(*ast.CallExpr)
	if !ok || !isImportedSelectorCall(file, call, integrationFixtureImportPath, "StopChild") ||
		len(call.Args) != 1 || !expressionMatchesBinding(call.Args[0], command) {
		return false
	}
	last, ok := failure.Body.List[len(failure.Body.List)-1].(*ast.ExprStmt)
	if !ok {
		return false
	}
	fatal, ok := last.X.(*ast.CallExpr)
	return ok && isTestingFatalCall(fatal, testHandle)
}

func exactServerChildStart(function *ast.FuncDecl, command, testHandle identifierBinding) (int, bool) {
	index := -1
	count := 0
	for statementIndex, statement := range function.Body.List {
		failure, ok := statement.(*ast.IfStmt)
		if !ok {
			continue
		}
		assignment, ok := failure.Init.(*ast.AssignStmt)
		if !ok || len(assignment.Lhs) != 1 || len(assignment.Rhs) != 1 {
			continue
		}
		call, ok := assignment.Rhs[0].(*ast.CallExpr)
		if !ok || !isBoundMethodCall(call, command, "Start") {
			continue
		}
		errorIdentifier, ok := assignment.Lhs[0].(*ast.Ident)
		if !ok || !isBindingNotNil(failure.Cond, bindingForIdentifier(errorIdentifier)) || len(failure.Body.List) == 0 {
			return -1, false
		}
		last, ok := failure.Body.List[len(failure.Body.List)-1].(*ast.ExprStmt)
		if !ok {
			return -1, false
		}
		fatal, ok := last.X.(*ast.CallExpr)
		if !ok || !isTestingFatalCall(fatal, testHandle) {
			return -1, false
		}
		count++
		index = statementIndex
	}
	return index, count == 1
}

func exactReadinessPreparation(
	file *ast.File,
	function *ast.FuncDecl,
	startIndex, readinessIndex int,
	testHandle identifierBinding,
) (identifierBinding, bool) {
	if readinessIndex != startIndex+4 {
		return identifierBinding{}, false
	}
	logStatement, ok := function.Body.List[startIndex+1].(*ast.ExprStmt)
	if !ok {
		return identifierBinding{}, false
	}
	logCall, ok := logStatement.X.(*ast.CallExpr)
	if !ok || !isBoundMethodCall(logCall, testHandle, "Log") {
		return identifierBinding{}, false
	}
	timeoutAssignment, ok := function.Body.List[startIndex+2].(*ast.AssignStmt)
	if !ok || len(timeoutAssignment.Lhs) != 2 || len(timeoutAssignment.Rhs) != 1 {
		return identifierBinding{}, false
	}
	timeoutCall, ok := timeoutAssignment.Rhs[0].(*ast.CallExpr)
	if !ok || !isImportedSelectorCall(file, timeoutCall, contextImportPath, "WithTimeout") {
		return identifierBinding{}, false
	}
	serverContextIdentifier, contextOK := timeoutAssignment.Lhs[0].(*ast.Ident)
	cancelIdentifier, cancelOK := timeoutAssignment.Lhs[1].(*ast.Ident)
	if !contextOK || !cancelOK {
		return identifierBinding{}, false
	}
	deferred, ok := function.Body.List[startIndex+3].(*ast.DeferStmt)
	if !ok || len(deferred.Call.Args) != 0 || !expressionMatchesBinding(deferred.Call.Fun, bindingForIdentifier(cancelIdentifier)) {
		return identifierBinding{}, false
	}
	return bindingForIdentifier(serverContextIdentifier), true
}

func exactServerChildBinding(file *ast.File, function *ast.FuncDecl) (identifierBinding, int, bool) {
	var binding identifierBinding
	index := -1
	count := 0
	for statementIndex, statement := range function.Body.List {
		assignment, ok := statement.(*ast.AssignStmt)
		if !ok || len(assignment.Lhs) != 1 || len(assignment.Rhs) != 1 {
			continue
		}
		call, ok := assignment.Rhs[0].(*ast.CallExpr)
		if !ok || !isImportedSelectorCall(file, call, osExecImportPath, "CommandContext") || len(call.Args) != 2 ||
			stringValue(call.Args[1]) != "../Server/.build/release/ExactMacServer" {
			continue
		}
		identifier, ok := assignment.Lhs[0].(*ast.Ident)
		if !ok {
			return identifierBinding{}, -1, false
		}
		count++
		binding = bindingForIdentifier(identifier)
		index = statementIndex
	}
	return binding, index, count == 1
}

func isImportedSelectorCall(file *ast.File, call *ast.CallExpr, importPath, functionName string) bool {
	alias, ok := importedPackageAlias(file, importPath)
	if !ok {
		return false
	}
	selector, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || selector.Sel.Name != functionName {
		return false
	}
	identifier, ok := selector.X.(*ast.Ident)
	return ok && identifier.Name == alias && identifier.Obj == nil
}

func importedPackageAlias(file *ast.File, importPath string) (string, bool) {
	alias := ""
	count := 0
	for _, spec := range file.Imports {
		if stringValue(spec.Path) != importPath {
			continue
		}
		count++
		if spec.Name != nil {
			if spec.Name.Name == "." || spec.Name.Name == "_" {
				return "", false
			}
			alias = spec.Name.Name
			continue
		}
		separator := strings.LastIndex(importPath, "/")
		alias = importPath[separator+1:]
	}
	return alias, count == 1
}

func bindingForIdentifier(identifier *ast.Ident) identifierBinding {
	binding := identifierBinding{name: identifier.Name}
	if identifier.Obj != nil {
		binding.declaration = identifier.Obj.Decl
	}
	return binding
}

func functionParameterBinding(function *ast.FuncDecl, name string) (identifierBinding, bool) {
	if function.Type.Params == nil {
		return identifierBinding{}, false
	}
	for _, field := range function.Type.Params.List {
		for _, identifier := range field.Names {
			if identifier.Name == name {
				return bindingForIdentifier(identifier), true
			}
		}
	}
	return identifierBinding{}, false
}

func expressionMatchesBinding(expression ast.Expr, binding identifierBinding) bool {
	identifier, ok := expression.(*ast.Ident)
	if !ok || identifier.Name != binding.name {
		return false
	}
	if binding.declaration == nil {
		return identifier.Obj == nil
	}
	return identifier.Obj != nil && identifier.Obj.Decl == binding.declaration
}

func isBoundMethodCall(call *ast.CallExpr, binding identifierBinding, method string) bool {
	selector, ok := call.Fun.(*ast.SelectorExpr)
	return ok && selector.Sel.Name == method && expressionMatchesBinding(selector.X, binding)
}

func isTestingFatalCall(call *ast.CallExpr, testHandle identifierBinding) bool {
	selector, ok := call.Fun.(*ast.SelectorExpr)
	return ok && (selector.Sel.Name == "Fatal" || selector.Sel.Name == "Fatalf") &&
		expressionMatchesBinding(selector.X, testHandle)
}

func expressionRootMatchesBinding(expression ast.Expr, binding identifierBinding) bool {
	switch typed := expression.(type) {
	case *ast.Ident:
		return expressionMatchesBinding(typed, binding)
	case *ast.SelectorExpr:
		return expressionRootMatchesBinding(typed.X, binding)
	case *ast.StarExpr:
		return expressionRootMatchesBinding(typed.X, binding)
	case *ast.IndexExpr:
		return expressionRootMatchesBinding(typed.X, binding)
	case *ast.IndexListExpr:
		return expressionRootMatchesBinding(typed.X, binding)
	case *ast.ParenExpr:
		return expressionRootMatchesBinding(typed.X, binding)
	default:
		return false
	}
}

func statementMutatesBindingExceptFields(statement ast.Stmt, binding identifierBinding, allowedFields ...string) bool {
	allowed := make(map[string]struct{}, len(allowedFields))
	for _, field := range allowedFields {
		allowed[field] = struct{}{}
	}
	mutated := false
	ast.Inspect(statement, func(node ast.Node) bool {
		switch typed := node.(type) {
		case *ast.AssignStmt:
			for _, expression := range typed.Lhs {
				if !expressionRootMatchesBinding(expression, binding) {
					continue
				}
				selector, directSelector := expression.(*ast.SelectorExpr)
				_, fieldAllowed := allowed[selectorName(selector)]
				if !directSelector || !expressionMatchesBinding(selector.X, binding) || !fieldAllowed {
					mutated = true
					return false
				}
			}
		case *ast.IncDecStmt:
			if expressionRootMatchesBinding(typed.X, binding) {
				mutated = true
				return false
			}
		}
		return !mutated
	})
	return mutated
}

func selectorName(selector *ast.SelectorExpr) string {
	if selector == nil {
		return ""
	}
	return selector.Sel.Name
}

func processKillUsesBinding(statement ast.Stmt, binding identifierBinding) bool {
	found := false
	ast.Inspect(statement, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return !found
		}
		kill, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || kill.Sel.Name != "Kill" {
			return true
		}
		process, ok := kill.X.(*ast.SelectorExpr)
		if ok && process.Sel.Name == "Process" && expressionMatchesBinding(process.X, binding) {
			found = true
			return false
		}
		return true
	})
	return found
}

func statementCanExit(statement ast.Stmt) bool {
	found := false
	ast.Inspect(statement, func(node ast.Node) bool {
		switch typed := node.(type) {
		case *ast.ReturnStmt:
			found = true
			return false
		case *ast.CallExpr:
			if hasSelectorSuffix(selectorChain(typed.Fun), "Fatal") || hasSelectorSuffix(selectorChain(typed.Fun), "Fatalf") {
				found = true
				return false
			}
		}
		return !found
	})
	return found
}

func isBindingNotNil(expression ast.Expr, binding identifierBinding) bool {
	binary, ok := expression.(*ast.BinaryExpr)
	if !ok || binary.Op != token.NEQ {
		return false
	}
	return (expressionMatchesBinding(binary.X, binding) && identifierName(binary.Y) == "nil") ||
		(identifierName(binary.X) == "nil" && expressionMatchesBinding(binary.Y, binding))
}

func isUnshadowedFunctionCall(call *ast.CallExpr, name string) bool {
	identifier, ok := call.Fun.(*ast.Ident)
	if !ok || identifier.Name != name {
		return false
	}
	return identifier.Obj == nil || identifier.Obj.Kind == ast.Fun
}

func hasSelectorSuffix(chain []string, suffix ...string) bool {
	if len(chain) < len(suffix) {
		return false
	}
	start := len(chain) - len(suffix)
	for index := range suffix {
		if chain[start+index] != suffix[index] {
			return false
		}
	}
	return true
}

func calledFunctionName(expression ast.Expr) string {
	chain := selectorChain(expression)
	if len(chain) == 0 {
		return ""
	}
	return chain[len(chain)-1]
}

func selectorChain(expression ast.Expr) []string {
	switch typed := expression.(type) {
	case *ast.Ident:
		return []string{typed.Name}
	case *ast.SelectorExpr:
		return append(selectorChain(typed.X), typed.Sel.Name)
	default:
		return nil
	}
}

func expressionName(expression ast.Expr) string {
	switch typed := expression.(type) {
	case *ast.Ident:
		return typed.Name
	case *ast.BasicLit:
		return stringValue(typed)
	default:
		return ""
	}
}

func identifierName(expression ast.Expr) string {
	identifier, ok := expression.(*ast.Ident)
	if !ok {
		return ""
	}
	return identifier.Name
}

func stringValue(expression ast.Expr) string {
	literal, ok := expression.(*ast.BasicLit)
	if !ok || literal.Kind != token.STRING {
		return ""
	}
	value, err := strconv.Unquote(literal.Value)
	if err != nil {
		return ""
	}
	return value
}
