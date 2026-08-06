// Copyright 2026 Joseph Cumines

package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/big"
	"reflect"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

var jsonNumberPattern = regexp.MustCompile(`^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`)

type toolCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

func decodeToolCallParams(raw json.RawMessage) (toolCallParams, error) {
	var params toolCallParams
	decoder := json.NewDecoder(bytes.NewReader(raw))
	// The tools/call outer params (name, arguments, context) MUST be closed:
	// an unexpected top-level field is rejected as invalid params rather than
	// silently ignored. This preserves the OuterParamsAreClosed contract and
	// stops clients from typos like {"name":"x","arguments":{},"unexpcted":1}
	// from being admitted as a valid call.
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&params); err != nil {
		return toolCallParams{}, fmt.Errorf("decode tool call params: %w", err)
	}
	if err := requireJSONDecoderEOF(decoder); err != nil {
		return toolCallParams{}, fmt.Errorf("decode tool call params: %w", err)
	}
	if params.Name == "" {
		return toolCallParams{}, fmt.Errorf("tool name is required")
	}
	if len(params.Arguments) == 0 {
		params.Arguments = json.RawMessage(`{}`)
	}
	return params, nil
}

func decodeToolArguments(raw json.RawMessage) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var args map[string]any
	if err := decoder.Decode(&args); err != nil {
		return nil, fmt.Errorf("decode tool arguments: %w", err)
	}
	if err := requireJSONDecoderEOF(decoder); err != nil {
		return nil, fmt.Errorf("decode tool arguments: %w", err)
	}
	if args == nil {
		return nil, fmt.Errorf("tool arguments must be an object")
	}
	return args, nil
}

func requireJSONDecoderEOF(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if err == io.EOF {
		return nil
	}
	if err == nil {
		return fmt.Errorf("multiple JSON values are not allowed")
	}
	return err
}

// validateToolInput validates decoded arguments against the exact schema
// advertised for a production tool. The supported schema vocabulary is kept
// deliberately finite and fail-closed; an invalid schema rejects admission.
func validateToolInput(toolName string, args map[string]any, tools map[string]*Tool) *transport.Message {
	tool, ok := tools[toolName]
	if !ok {
		return nil
	}
	if tool.InputSchema == nil {
		return nil
	}
	if err := validateSchemaValue("", args, tool.InputSchema); err != nil {
		return invalidParamsError(err.Error())
	}
	if tool.ValidateInput != nil {
		if err := tool.ValidateInput(args); err != nil {
			return invalidParamsError(err.Error())
		}
	}
	return nil
}

func invalidParamsError(message string) *transport.Message {
	return &transport.Message{
		JSONRPC: "2.0",
		Error: &transport.ErrorObj{
			Code:    transport.ErrCodeInvalidParams,
			Message: message,
		},
	}
}

func validateSchemaValue(path string, value any, schema map[string]any) error {
	types, err := schemaTypes(schema)
	if err != nil {
		return schemaError(path, err)
	}
	if value == nil {
		if len(types) == 0 || containsString(types, "null") {
			return validateEnumConstraint(path, value, schema)
		}
		return fmt.Errorf("field %q must not be null", displayFieldPath(path))
	}

	if len(types) != 0 {
		matched := false
		for _, schemaType := range types {
			if matchesSchemaType(value, schemaType) {
				matched = true
				break
			}
		}
		if !matched {
			return fmt.Errorf(
				"field %q must be %s, got %T",
				displayFieldPath(path),
				describeSchemaTypes(types),
				value,
			)
		}
	}
	if err := validateEnumConstraint(path, value, schema); err != nil {
		return err
	}

	switch typed := value.(type) {
	case map[string]any:
		if containsString(types, "object") || len(types) == 0 {
			return validateObjectConstraints(path, typed, schema)
		}
	case []any:
		if containsString(types, "array") || len(types) == 0 {
			return validateArrayConstraints(path, typed, schema)
		}
	case string:
		return validateStringConstraints(path, typed, schema)
	}
	if _, ok := numericValue(value); ok {
		return validateNumericConstraints(path, value, schema)
	}
	return nil
}

func validateObjectConstraints(path string, value map[string]any, schema map[string]any) error {
	required, err := schemaStringList(schema, "required")
	if err != nil {
		return schemaError(path, err)
	}
	for _, name := range required {
		if _, ok := value[name]; !ok {
			return fmt.Errorf("missing required field: %s", childFieldPath(path, name))
		}
	}

	properties, err := schemaProperties(schema)
	if err != nil {
		return schemaError(path, err)
	}
	keys := make([]string, 0, len(value))
	for name := range value {
		keys = append(keys, name)
	}
	sort.Strings(keys)
	for _, name := range keys {
		childPath := childFieldPath(path, name)
		if childSchema, ok := properties[name]; ok {
			if err := validateSchemaValue(childPath, value[name], childSchema); err != nil {
				return err
			}
			continue
		}
		switch additional := schema["additionalProperties"].(type) {
		case nil:
			continue
		case bool:
			if !additional {
				return fmt.Errorf("additional property not allowed: %s", childPath)
			}
		case map[string]any:
			if err := validateSchemaValue(childPath, value[name], additional); err != nil {
				return err
			}
		default:
			return schemaError(path, fmt.Errorf("additionalProperties must be a boolean or schema"))
		}
	}
	if err := validateCollectionCount(path, len(value), schema, "minProperties", "maxProperties"); err != nil {
		return err
	}
	return nil
}

func validateArrayConstraints(path string, value []any, schema map[string]any) error {
	if err := validateCollectionCount(path, len(value), schema, "minItems", "maxItems"); err != nil {
		return err
	}
	items, exists := schema["items"]
	if !exists {
		return nil
	}
	itemSchema, ok := items.(map[string]any)
	if !ok {
		return schemaError(path, fmt.Errorf("items must be a schema"))
	}
	for index, item := range value {
		if err := validateSchemaValue(fmt.Sprintf("%s[%d]", displayFieldPath(path), index), item, itemSchema); err != nil {
			return err
		}
	}
	return nil
}

func validateCollectionCount(path string, count int, schema map[string]any, minimumKey, maximumKey string) error {
	if raw, ok := schema[minimumKey]; ok {
		minimum, err := schemaNonNegativeInt(raw)
		if err != nil {
			return schemaError(path, fmt.Errorf("%s: %w", minimumKey, err))
		}
		if count < minimum {
			return fmt.Errorf("field %q must contain at least %d entries, got %d", displayFieldPath(path), minimum, count)
		}
	}
	if raw, ok := schema[maximumKey]; ok {
		maximum, err := schemaNonNegativeInt(raw)
		if err != nil {
			return schemaError(path, fmt.Errorf("%s: %w", maximumKey, err))
		}
		if count > maximum {
			return fmt.Errorf("field %q must contain at most %d entries, got %d", displayFieldPath(path), maximum, count)
		}
	}
	return nil
}

func validateStringConstraints(path, value string, schema map[string]any) error {
	length := utf8.RuneCountInString(value)
	if raw, ok := schema["minLength"]; ok {
		minimum, err := schemaNonNegativeInt(raw)
		if err != nil {
			return schemaError(path, fmt.Errorf("minLength: %w", err))
		}
		if length < minimum {
			return fmt.Errorf("field %q must contain at least %d characters, got %d", displayFieldPath(path), minimum, length)
		}
	}
	if raw, ok := schema["maxLength"]; ok {
		maximum, err := schemaNonNegativeInt(raw)
		if err != nil {
			return schemaError(path, fmt.Errorf("maxLength: %w", err))
		}
		if length > maximum {
			return fmt.Errorf("field %q must contain at most %d characters, got %d", displayFieldPath(path), maximum, length)
		}
	}
	if raw, ok := schema["pattern"]; ok {
		pattern, ok := raw.(string)
		if !ok {
			return schemaError(path, fmt.Errorf("pattern must be a string"))
		}
		expression, err := regexp.Compile(pattern)
		if err != nil {
			return schemaError(path, fmt.Errorf("invalid pattern: %w", err))
		}
		if !expression.MatchString(value) {
			return fmt.Errorf("field %q must match pattern %q", displayFieldPath(path), pattern)
		}
	}
	return nil
}

func validateNumericConstraints(path string, value any, schema map[string]any) error {
	number, ok := numericValue(value)
	if !ok {
		return fmt.Errorf("field %q must be a finite JSON number", displayFieldPath(path))
	}
	for _, constraint := range []struct {
		key        string
		comparison func(int) bool
		message    string
	}{
		{key: "minimum", comparison: func(result int) bool { return result < 0 }, message: "greater than or equal to"},
		{key: "maximum", comparison: func(result int) bool { return result > 0 }, message: "less than or equal to"},
		{key: "exclusiveMinimum", comparison: func(result int) bool { return result <= 0 }, message: "greater than"},
		{key: "exclusiveMaximum", comparison: func(result int) bool { return result >= 0 }, message: "less than"},
	} {
		raw, exists := schema[constraint.key]
		if !exists {
			continue
		}
		bound, ok := numericValue(raw)
		if !ok {
			return schemaError(path, fmt.Errorf("%s must be numeric", constraint.key))
		}
		if constraint.comparison(number.Cmp(bound)) {
			return fmt.Errorf(
				"field %q must be %s %v",
				displayFieldPath(path),
				constraint.message,
				raw,
			)
		}
	}
	return nil
}

func validateEnumConstraint(path string, value any, schema map[string]any) error {
	raw, exists := schema["enum"]
	if !exists {
		return nil
	}
	var values []any
	switch typed := raw.(type) {
	case []any:
		values = typed
	case []string:
		values = make([]any, len(typed))
		for index, item := range typed {
			values[index] = item
		}
	default:
		return schemaError(path, fmt.Errorf("enum must be an array"))
	}
	for _, allowed := range values {
		if schemaValuesEqual(value, allowed) {
			return nil
		}
	}
	return fmt.Errorf("field %q must be one of %v, got %v", displayFieldPath(path), values, value)
}

func schemaValuesEqual(left, right any) bool {
	leftNumber, leftIsNumber := numericValue(left)
	rightNumber, rightIsNumber := numericValue(right)
	if leftIsNumber || rightIsNumber {
		return leftIsNumber && rightIsNumber && leftNumber.Cmp(rightNumber) == 0
	}
	return reflect.DeepEqual(left, right)
}

func schemaTypes(schema map[string]any) ([]string, error) {
	raw, exists := schema["type"]
	if !exists {
		return nil, nil
	}
	var result []string
	switch typed := raw.(type) {
	case string:
		result = []string{typed}
	case []string:
		result = append(result, typed...)
	case []any:
		for _, value := range typed {
			schemaType, ok := value.(string)
			if !ok {
				return nil, fmt.Errorf("type entries must be strings")
			}
			result = append(result, schemaType)
		}
	default:
		return nil, fmt.Errorf("type must be a string or string array")
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("type array must not be empty")
	}
	for _, schemaType := range result {
		switch schemaType {
		case "null", "boolean", "object", "array", "number", "integer", "string":
		default:
			return nil, fmt.Errorf("unsupported schema type %q", schemaType)
		}
	}
	return result, nil
}

func schemaStringList(schema map[string]any, key string) ([]string, error) {
	raw, exists := schema[key]
	if !exists {
		return nil, nil
	}
	switch typed := raw.(type) {
	case []string:
		return append([]string(nil), typed...), nil
	case []any:
		result := make([]string, 0, len(typed))
		for _, value := range typed {
			item, ok := value.(string)
			if !ok {
				return nil, fmt.Errorf("%s entries must be strings", key)
			}
			result = append(result, item)
		}
		return result, nil
	default:
		return nil, fmt.Errorf("%s must be a string array", key)
	}
}

func schemaProperties(schema map[string]any) (map[string]map[string]any, error) {
	raw, exists := schema["properties"]
	if !exists {
		return nil, nil
	}
	properties, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("properties must be an object")
	}
	result := make(map[string]map[string]any, len(properties))
	for name, value := range properties {
		property, ok := value.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("property %q must be a schema", name)
		}
		result[name] = property
	}
	return result, nil
}

func matchesSchemaType(value any, schemaType string) bool {
	switch schemaType {
	case "null":
		return value == nil
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "object":
		_, ok := value.(map[string]any)
		return ok
	case "array":
		_, ok := value.([]any)
		return ok
	case "number":
		_, ok := numericValue(value)
		return ok
	case "integer":
		number, ok := numericValue(value)
		return ok && number.IsInt()
	case "string":
		_, ok := value.(string)
		return ok
	default:
		return false
	}
}

func numericValue(value any) (*big.Rat, bool) {
	switch typed := value.(type) {
	case json.Number:
		return parseJSONNumber(string(typed))
	case int:
		return new(big.Rat).SetInt64(int64(typed)), true
	case int8:
		return new(big.Rat).SetInt64(int64(typed)), true
	case int16:
		return new(big.Rat).SetInt64(int64(typed)), true
	case int32:
		return new(big.Rat).SetInt64(int64(typed)), true
	case int64:
		return new(big.Rat).SetInt64(typed), true
	case uint:
		return new(big.Rat).SetInt(new(big.Int).SetUint64(uint64(typed))), true
	case uint8:
		return new(big.Rat).SetInt(new(big.Int).SetUint64(uint64(typed))), true
	case uint16:
		return new(big.Rat).SetInt(new(big.Int).SetUint64(uint64(typed))), true
	case uint32:
		return new(big.Rat).SetInt(new(big.Int).SetUint64(uint64(typed))), true
	case uint64:
		return new(big.Rat).SetInt(new(big.Int).SetUint64(typed)), true
	case float32:
		if math.IsNaN(float64(typed)) || math.IsInf(float64(typed), 0) {
			return nil, false
		}
		return parseJSONNumber(strconv.FormatFloat(float64(typed), 'g', -1, 32))
	case float64:
		if math.IsNaN(typed) || math.IsInf(typed, 0) {
			return nil, false
		}
		return parseJSONNumber(strconv.FormatFloat(typed, 'g', -1, 64))
	default:
		return nil, false
	}
}

func parseJSONNumber(value string) (*big.Rat, bool) {
	if len(value) == 0 || len(value) > 4096 || !jsonNumberPattern.MatchString(value) {
		return nil, false
	}
	mantissa := value
	exponent := 0
	if index := strings.IndexAny(mantissa, "eE"); index >= 0 {
		parsed, err := strconv.Atoi(mantissa[index+1:])
		if err != nil || parsed < -10000 || parsed > 10000 {
			return nil, false
		}
		exponent = parsed
		mantissa = mantissa[:index]
	}
	fractionalDigits := 0
	if index := strings.IndexByte(mantissa, '.'); index >= 0 {
		fractionalDigits = len(mantissa) - index - 1
		mantissa = mantissa[:index] + mantissa[index+1:]
	}
	numerator, ok := new(big.Int).SetString(mantissa, 10)
	if !ok {
		return nil, false
	}
	denominator := big.NewInt(1)
	if fractionalDigits > 0 {
		denominator.Exp(big.NewInt(10), big.NewInt(int64(fractionalDigits)), nil)
	}
	if exponent > 0 {
		numerator.Mul(numerator, new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(exponent)), nil))
	} else if exponent < 0 {
		denominator.Mul(denominator, new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(-exponent)), nil))
	}
	return new(big.Rat).SetFrac(numerator, denominator), true
}

func schemaNonNegativeInt(value any) (int, error) {
	number, ok := numericValue(value)
	if !ok || !number.IsInt() || number.Sign() < 0 || !number.Num().IsInt64() {
		return 0, fmt.Errorf("must be a non-negative integer")
	}
	parsed := number.Num().Int64()
	if int64(int(parsed)) != parsed {
		return 0, fmt.Errorf("is too large")
	}
	return int(parsed), nil
}

func closeToolObjectSchemas(schema map[string]any) {
	if schema == nil {
		return
	}
	types, _ := schemaTypes(schema)
	if containsString(types, "object") {
		// An explicit additionalProperties:true is an author opt-out: the object
		// is a flexible container (e.g. a proto oneof branch, or a pass-through
		// whose payload the handler validates via protojson) and must stay open.
		// Only objects that do not declare additionalProperties (the common case)
		// are force-closed for defense-in-depth.
		if existing, ok := schema["additionalProperties"]; !ok || existing != true {
			schema["additionalProperties"] = false
		}
	}
	if properties, ok := schema["properties"].(map[string]any); ok {
		for _, value := range properties {
			if child, ok := value.(map[string]any); ok {
				closeToolObjectSchemas(child)
			}
		}
	}
	if items, ok := schema["items"].(map[string]any); ok {
		closeToolObjectSchemas(items)
	}
	for _, keyword := range []string{"allOf", "anyOf", "oneOf"} {
		if alternatives, ok := schema[keyword].([]any); ok {
			for _, value := range alternatives {
				if child, ok := value.(map[string]any); ok {
					closeToolObjectSchemas(child)
				}
			}
		}
	}
}

func containsString(values []string, expected string) bool {
	return slices.Contains(values, expected)
}

func childFieldPath(parent, child string) string {
	if parent == "" {
		return child
	}
	return parent + "." + child
}

func displayFieldPath(path string) string {
	if path == "" {
		return "arguments"
	}
	return path
}

func describeSchemaTypes(types []string) string {
	if len(types) == 1 {
		article := "a"
		if strings.HasPrefix(types[0], "i") || strings.HasPrefix(types[0], "o") || strings.HasPrefix(types[0], "a") {
			article = "an"
		}
		return article + " " + types[0]
	}
	return "one of [" + strings.Join(types, ", ") + "]"
}

func schemaError(path string, err error) error {
	return fmt.Errorf("invalid schema for field %q: %w", displayFieldPath(path), err)
}
