package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strconv"
)

const (
	productName       = "exactmac"
	independentClient = "1.0.0"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: validate-go-version <mode> <file> <version>")
		os.Exit(2)
	}
	mode, path, expected := os.Args[1], os.Args[2], os.Args[3]
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.AllErrors)
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse %s: %v\n", path, err)
		os.Exit(1)
	}

	var validationErr error
	switch mode {
	case "cli":
		validationErr = validateCLI(file, expected)
	case "protocol":
		validationErr = validateProtocol(file, expected)
	case "initialization":
		validationErr = validateInitialization(file, expected)
	case "resource", "prompts":
		validationErr = validateJSONFixture(file, mode, expected)
	case "independent":
		validationErr = validateIndependentClientInfo(file)
	default:
		validationErr = fmt.Errorf("unknown validation mode %q", mode)
	}
	if validationErr != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", path, validationErr)
		os.Exit(1)
	}
}

func stringLiteral(expression ast.Expr) (string, bool) {
	literal, ok := expression.(*ast.BasicLit)
	if !ok || literal.Kind != token.STRING {
		return "", false
	}
	value, err := strconv.Unquote(literal.Value)
	return value, err == nil
}

func keyName(expression ast.Expr) (string, bool) {
	if identifier, ok := expression.(*ast.Ident); ok {
		return identifier.Name, true
	}
	return stringLiteral(expression)
}

func stringField(literal *ast.CompositeLit, key string) (string, bool) {
	for _, element := range literal.Elts {
		pair, ok := element.(*ast.KeyValueExpr)
		if !ok {
			continue
		}
		name, ok := stringLiteral(pair.Key)
		if !ok || name != key {
			continue
		}
		return stringLiteral(pair.Value)
	}
	return "", false
}

func isStdoutStderr(expression ast.Expr) bool {
	selector, ok := expression.(*ast.SelectorExpr)
	if !ok || selector.Sel.Name != "Stderr" {
		return false
	}
	packageName, ok := selector.X.(*ast.Ident)
	return ok && packageName.Name == "os"
}

func validateCLI(file *ast.File, expected string) error {
	count := 0
	var unexpected int
	ast.Inspect(file, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok || len(call.Args) != 2 {
			return true
		}
		selector, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || selector.Sel.Name != "Fprintln" {
			return true
		}
		packageName, ok := selector.X.(*ast.Ident)
		if !ok || packageName.Name != "fmt" || !isStdoutStderr(call.Args[0]) {
			return true
		}
		value, ok := stringLiteral(call.Args[1])
		if !ok {
			return true
		}
		if value == productName+" "+expected {
			count++
		} else if len(value) >= len(productName)+1 && value[:len(productName)+1] == productName+" " {
			unexpected++
		}
		return true
	})
	if count != 1 || unexpected != 0 {
		return fmt.Errorf("CLI product version count = %d, unexpected values = %d", count, unexpected)
	}
	return nil
}

func validateProtocol(file *ast.File, expected string) error {
	count := 0
	ast.Inspect(file, func(node ast.Node) bool {
		literal, ok := node.(*ast.CompositeLit)
		if !ok {
			return true
		}
		for _, element := range literal.Elts {
			pair, ok := element.(*ast.KeyValueExpr)
			if !ok {
				continue
			}
			key, ok := stringLiteral(pair.Key)
			if !ok || key != "serverInfo" {
				continue
			}
			serverInfo, ok := pair.Value.(*ast.CompositeLit)
			if !ok {
				continue
			}
			name, nameOK := stringField(serverInfo, "name")
			version, versionOK := stringField(serverInfo, "version")
			if nameOK && versionOK && name == productName && version == expected {
				count++
			}
		}
		return true
	})
	if count != 1 {
		return fmt.Errorf("serverInfo product map count = %d, want 1", count)
	}
	return nil
}

func decodeJSON(data []byte) (map[string]any, error) {
	var value map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	var extra any
	if err := decoder.Decode(&extra); err == nil {
		return nil, errors.New("multiple JSON values")
	}
	return value, nil
}

func jsonServerInfo(value map[string]any) (map[string]any, bool) {
	serverInfo, ok := value["serverInfo"].(map[string]any)
	return serverInfo, ok
}

func validateInitialization(file *ast.File, expected string) error {
	responseCount := 0
	ast.Inspect(file, func(node ast.Node) bool {
		pair, ok := node.(*ast.KeyValueExpr)
		if !ok {
			return true
		}
		key, ok := keyName(pair.Key)
		if !ok || key != "response" {
			return true
		}
		raw, ok := stringLiteral(pair.Value)
		if !ok {
			return true
		}
		document, err := decodeJSON([]byte(raw))
		if err != nil {
			return true
		}
		serverInfo, ok := jsonServerInfo(document)
		if !ok {
			return true
		}
		if serverInfo["name"] == productName && serverInfo["version"] == expected {
			responseCount++
		}
		return true
	})

	protocolCount := 0
	ast.Inspect(file, func(node ast.Node) bool {
		literal, ok := node.(*ast.CompositeLit)
		if !ok {
			return true
		}
		for _, element := range literal.Elts {
			pair, ok := element.(*ast.KeyValueExpr)
			if !ok {
				continue
			}
			key, ok := stringLiteral(pair.Key)
			if !ok || key != "serverInfo" {
				continue
			}
			serverInfo, ok := pair.Value.(*ast.CompositeLit)
			if !ok {
				continue
			}
			name, nameOK := stringField(serverInfo, "name")
			version, versionOK := stringField(serverInfo, "version")
			if nameOK && versionOK && name == productName && version == expected {
				protocolCount++
			}
		}
		return true
	})
	if responseCount != 2 || protocolCount != 1 {
		return fmt.Errorf("initialization response count = %d, serverInfo map count = %d", responseCount, protocolCount)
	}
	return nil
}

func validateJSONFixture(file *ast.File, mode string, expected string) error {
	count := 0
	ast.Inspect(file, func(node ast.Node) bool {
		assignment, ok := node.(*ast.AssignStmt)
		if !ok || len(assignment.Lhs) != 1 || len(assignment.Rhs) != 1 {
			return true
		}
		name, ok := assignment.Lhs[0].(*ast.Ident)
		if !ok || name.Name != "initResponseJSON" {
			return true
		}
		raw, ok := stringLiteral(assignment.Rhs[0])
		if !ok {
			return true
		}
		document, err := decodeJSON([]byte(raw))
		if err != nil {
			return true
		}
		if mode == "prompts" {
			result, ok := document["result"].(map[string]any)
			if !ok {
				return true
			}
			document = result
		}
		serverInfo, ok := jsonServerInfo(document)
		if ok && serverInfo["name"] == productName && serverInfo["version"] == expected {
			count++
		}
		return true
	})
	if count != 1 {
		return fmt.Errorf("JSON fixture serverInfo count = %d, want 1", count)
	}
	return nil
}

func validateIndependentClientInfo(file *ast.File) error {
	count := 0
	ast.Inspect(file, func(node ast.Node) bool {
		literal, ok := node.(*ast.CompositeLit)
		if !ok {
			return true
		}
		for _, element := range literal.Elts {
			pair, ok := element.(*ast.KeyValueExpr)
			if !ok {
				continue
			}
			key, ok := stringLiteral(pair.Key)
			if !ok || key != "clientInfo" {
				continue
			}
			clientInfo, ok := pair.Value.(*ast.CompositeLit)
			if !ok {
				continue
			}
			if version, ok := stringField(clientInfo, "version"); ok && version == independentClient {
				count++
			}
		}
		return true
	})
	if count != 4 {
		return fmt.Errorf("independent clientInfo version count = %d, want 4", count)
	}
	return nil
}
