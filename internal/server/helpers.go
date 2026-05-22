// Copyright 2025 Joseph Cumines
//
// Helper functions for tool handlers

package server

import (
	"fmt"
	"slices"
	"strings"

	_type "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/transport"
	"google.golang.org/grpc/codes"
	grpcstatus "google.golang.org/grpc/status"
)

// maxDisplayTextLen is the maximum length for text shown in result summaries.
// Longer text is truncated with "..." suffix.
const maxDisplayTextLen = 50

// truncateText truncates text to maxDisplayTextLen characters with "..." suffix if needed.
func truncateText(s string) string {
	if len(s) > maxDisplayTextLen {
		return s[:maxDisplayTextLen] + "..."
	}
	return s
}

// errorResult creates a ToolResult with IsError=true and the given message.
// This reduces boilerplate for error responses across handlers.
func errorResult(msg string) *ToolResult {
	return &ToolResult{
		IsError: true,
		Content: []Content{{Type: "text", Text: msg}},
	}
}

// errorResultf creates a ToolResult with IsError=true and a formatted message.
// This is the sprintf version of errorResult.
func errorResultf(format string, args ...any) *ToolResult {
	return errorResult(fmt.Sprintf(format, args...))
}

// textResult creates a ToolResult with a single text content.
// This reduces boilerplate for simple text responses.
func textResult(text string) *ToolResult {
	return &ToolResult{
		Content: []Content{{Type: "text", Text: text}},
	}
}

// textResultf creates a ToolResult with a formatted text content.
func textResultf(format string, args ...any) *ToolResult {
	return textResult(fmt.Sprintf(format, args...))
}

// boundsString returns a formatted string representation of window bounds,
// safely handling nil bounds with a fallback value.
func boundsString(b *pb.Bounds) string {
	if b == nil {
		return "(unknown position and size)"
	}
	return fmt.Sprintf("(%.0f, %.0f) %.0fx%.0f", b.X, b.Y, b.Width, b.Height)
}

// boundsPosition returns a formatted position string from window bounds,
// safely handling nil bounds.
func boundsPosition(b *pb.Bounds) string {
	if b == nil {
		return "(unknown)"
	}
	return fmt.Sprintf("(%.0f, %.0f)", b.X, b.Y)
}

// boundsSize returns a formatted size string from window bounds,
// safely handling nil bounds.
func boundsSize(b *pb.Bounds) string {
	if b == nil {
		return "(unknown)"
	}
	return fmt.Sprintf("%.0fx%.0f", b.Width, b.Height)
}

// frameString returns a formatted string representation of a display frame,
// safely handling nil frames.
func frameString(f *_type.Region) string {
	if f == nil {
		return "(unknown frame)"
	}
	return fmt.Sprintf("%.0fx%.0f @ (%.0f, %.0f)", f.Width, f.Height, f.X, f.Y)
}

// formatGRPCError formats a gRPC error with context for MCP tool responses.
// It extracts the gRPC status code and message, and provides actionable suggestions
// for common error scenarios.
func formatGRPCError(err error, toolName string) string {
	if err == nil {
		return ""
	}

	st, ok := grpcstatus.FromError(err)
	if !ok {
		// Not a gRPC error, return as-is
		return fmt.Sprintf("Error in %s: %s", toolName, err.Error())
	}

	code := st.Code()
	msg := st.Message()
	suggestion := ""

	switch code {
	case codes.PermissionDenied:
		suggestion = "Ensure accessibility permissions are granted in System Preferences > Privacy & Security > Accessibility"
	case codes.NotFound:
		suggestion = "Verify the resource exists and the name/ID is correct"
	case codes.InvalidArgument:
		suggestion = "Check the request parameters for invalid or missing values"
	case codes.Unavailable:
		suggestion = "The gRPC server may be down or unreachable. Check server status"
	case codes.DeadlineExceeded:
		suggestion = "Operation timed out. Try increasing timeout or simplifying the request"
	case codes.Internal:
		suggestion = "An internal server error occurred. Check server logs for details"
	case codes.FailedPrecondition:
		suggestion = "The operation failed due to a precondition not being met. Check if the resource is in the correct state"
	case codes.AlreadyExists:
		suggestion = "A resource with this identifier already exists"
	case codes.ResourceExhausted:
		suggestion = "Rate limit exceeded or quota exhausted. Try again later"
	case codes.Unimplemented:
		suggestion = "This operation is not implemented or supported"
	}

	result := fmt.Sprintf("Error in %s: %s - %s", toolName, code.String(), msg)
	if suggestion != "" {
		result += fmt.Sprintf("\nSuggestion: %s", suggestion)
	}
	return result
}

// grpcErrorResult creates a ToolResult with IsError=true and a formatted gRPC error message.
// This is a convenience wrapper combining formatGRPCError and errorResult.
func grpcErrorResult(err error, toolName string) *ToolResult {
	return errorResult(formatGRPCError(err, toolName))
}

// validateToolInput validates JSON arguments against a tool's InputSchema.
// It checks:
//   - All required fields are present
//   - Field types match the schema (string, number, boolean, integer, array, object)
//   - Enum values are in the allowed set (if enum is specified)
//
// Returns a JSON-RPC error response with ErrCodeInvalidParams (-32602) if validation fails,
// nil if validation passes.
//
// Note: Extra properties not defined in the schema are allowed per JSON-RPC conventions.
func validateToolInput(toolName string, args map[string]any, tools map[string]*Tool) *transport.Message {
	tool, ok := tools[toolName]
	if !ok {
		// Tool not found - this is handled separately, return nil to let caller handle
		return nil
	}

	schema := tool.InputSchema
	if schema == nil {
		// No schema defined - nothing to validate
		return nil
	}

	// Get required fields from schema
	requiredFields := getRequiredFields(schema)

	// Check all required fields are present
	for _, field := range requiredFields {
		if _, exists := args[field]; !exists {
			return invalidParamsError(fmt.Sprintf("missing required field: %s", field))
		}
	}

	// Get properties from schema for type/enum validation
	properties := getSchemaProperties(schema)
	if properties == nil {
		// No properties defined - skip type validation
		return nil
	}

	// Validate each provided argument against its schema
	for fieldName, value := range args {
		propSchema, exists := properties[fieldName]
		if !exists {
			// Extra property not in schema - allowed per JSON-RPC conventions
			continue
		}

		if err := validateFieldValue(fieldName, value, propSchema); err != nil {
			return invalidParamsError(err.Error())
		}
	}

	return nil
}

// invalidParamsError creates a JSON-RPC error response with ErrCodeInvalidParams.
func invalidParamsError(message string) *transport.Message {
	return &transport.Message{
		JSONRPC: "2.0",
		Error: &transport.ErrorObj{
			Code:    transport.ErrCodeInvalidParams,
			Message: message,
		},
	}
}

// getRequiredFields extracts the "required" array from a JSON schema.
func getRequiredFields(schema map[string]any) []string {
	required, ok := schema["required"]
	if !ok {
		return nil
	}

	requiredArr, ok := required.([]string)
	if ok {
		return requiredArr
	}

	// Handle case where required is []interface{} (from JSON unmarshaling)
	requiredIface, ok := required.([]any)
	if !ok {
		return nil
	}

	result := make([]string, 0, len(requiredIface))
	for _, v := range requiredIface {
		if s, ok := v.(string); ok {
			result = append(result, s)
		}
	}
	return result
}

// getSchemaProperties extracts the "properties" map from a JSON schema.
func getSchemaProperties(schema map[string]any) map[string]map[string]any {
	props, ok := schema["properties"]
	if !ok {
		return nil
	}

	propsMap, ok := props.(map[string]any)
	if !ok {
		return nil
	}

	result := make(map[string]map[string]any, len(propsMap))
	for k, v := range propsMap {
		if propSchema, ok := v.(map[string]any); ok {
			result[k] = propSchema
		}
	}
	return result
}

// validateFieldValue validates a single field value against its property schema.
// Returns an error if validation fails.
func validateFieldValue(fieldName string, value any, propSchema map[string]any) error {
	// Skip validation for nil/null values (unless required, which is checked above)
	if value == nil {
		return nil
	}

	// Get expected type from schema
	schemaType, hasType := propSchema["type"].(string)
	if !hasType {
		// No type specified - skip type validation
		return validateEnumValue(fieldName, value, propSchema)
	}

	// Validate type
	if err := validateType(fieldName, value, schemaType); err != nil {
		return err
	}

	// Validate enum if present
	return validateEnumValue(fieldName, value, propSchema)
}

// validateType validates that a value matches the expected JSON Schema type.
// JSON Schema types: string, number, integer, boolean, array, object
func validateType(fieldName string, value any, expectedType string) error {
	switch expectedType {
	case "string":
		if _, ok := value.(string); !ok {
			return fmt.Errorf("field %q must be a string, got %T", fieldName, value)
		}
	case "number":
		// JSON numbers can be float64 or json.Number; integers are also valid numbers
		if !isNumber(value) {
			return fmt.Errorf("field %q must be a number, got %T", fieldName, value)
		}
	case "integer":
		// Integers must be whole numbers
		if !isInteger(value) {
			return fmt.Errorf("field %q must be an integer, got %T", fieldName, value)
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("field %q must be a boolean, got %T", fieldName, value)
		}
	case "array":
		if _, ok := value.([]any); !ok {
			return fmt.Errorf("field %q must be an array, got %T", fieldName, value)
		}
	case "object":
		if _, ok := value.(map[string]any); !ok {
			return fmt.Errorf("field %q must be an object, got %T", fieldName, value)
		}
	default:
		// Unknown type - skip validation
	}
	return nil
}

// isNumber returns true if the value is a valid JSON number (float64 or integer).
func isNumber(value any) bool {
	switch value.(type) {
	case float64, float32, int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return true
	default:
		return false
	}
}

// isInteger returns true if the value is an integer (whole number).
// JSON unmarshaling to interface{} produces float64 for all numbers,
// so we need to check if the float64 is a whole number.
func isInteger(value any) bool {
	switch v := value.(type) {
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return true
	case float64:
		// Check if the float64 is a whole number
		return v == float64(int64(v))
	case float32:
		return v == float32(int32(v))
	default:
		return false
	}
}

// validateEnumValue validates that a value is in the allowed enum set.
// Returns nil if no enum is defined or if value is in the allowed set.
func validateEnumValue(fieldName string, value any, propSchema map[string]any) error {
	enumValues, ok := propSchema["enum"]
	if !ok {
		return nil
	}

	// Handle enum as []string (defined in registerTools)
	if enumStrings, ok := enumValues.([]string); ok {
		valueStr, ok := value.(string)
		if !ok {
			// Enum is defined but value is not a string - type mismatch
			return fmt.Errorf("field %q must be a string for enum validation, got %T", fieldName, value)
		}
		if slices.Contains(enumStrings, valueStr) {
			return nil
		}
		return fmt.Errorf("field %q must be one of [%s], got %q", fieldName, strings.Join(enumStrings, ", "), valueStr)
	}

	// Handle enum as []interface{} (from JSON unmarshaling)
	if enumIface, ok := enumValues.([]any); ok {
		for _, allowed := range enumIface {
			if value == allowed {
				return nil
			}
			// Also compare as strings for flexibility
			if valueStr, ok := value.(string); ok {
				if allowedStr, ok := allowed.(string); ok && valueStr == allowedStr {
					return nil
				}
			}
		}
		// Build error message with allowed values
		allowedStrs := make([]string, 0, len(enumIface))
		for _, v := range enumIface {
			allowedStrs = append(allowedStrs, fmt.Sprintf("%v", v))
		}
		return fmt.Errorf("field %q must be one of [%s], got %v", fieldName, strings.Join(allowedStrs, ", "), value)
	}

	return nil
}
