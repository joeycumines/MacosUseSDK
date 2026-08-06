// Copyright 2026 Joseph Cumines

package transport

import (
	"bytes"
	"encoding/json"
	"fmt"
)

const (
	parseErrorMessage     = "Parse error"
	invalidRequestMessage = "Invalid Request"
)

// DecodeRequest decodes and validates one JSON-RPC 2.0 Request object.
// Syntax failures are parse errors; well-formed JSON that is not a valid
// Request object is an invalid-request error. Both are recoverable at the
// message boundary and require a response whose ID is null.
func DecodeRequest(data []byte) (*Message, error) {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || !json.Valid(trimmed) {
		return nil, newRequestReadError(ErrCodeParseError, parseErrorMessage, fmt.Errorf("invalid JSON"))
	}
	if trimmed[0] != '{' {
		return nil, newRequestReadError(ErrCodeInvalidRequest, invalidRequestMessage, fmt.Errorf("request is not an object"))
	}

	var msg Message
	if err := json.Unmarshal(trimmed, &msg); err != nil {
		return nil, newRequestReadError(ErrCodeInvalidRequest, invalidRequestMessage, err)
	}
	if err := ValidateRequest(&msg); err != nil {
		return nil, err
	}
	return &msg, nil
}

// ValidateRequest validates fields that are preserved by Message. It is also
// used by the production dispatcher so direct callers cannot bypass the same
// JSON-RPC Request-object contract enforced by HTTP and stdio decoders.
func ValidateRequest(msg *Message) *MessageReadError {
	if msg == nil {
		return newRequestReadError(ErrCodeInvalidRequest, invalidRequestMessage, fmt.Errorf("request is nil"))
	}
	if msg.JSONRPC != "2.0" {
		return newRequestReadError(ErrCodeInvalidRequest, invalidRequestMessage, fmt.Errorf("jsonrpc must be 2.0"))
	}
	if msg.Method == "" {
		return newRequestReadError(ErrCodeInvalidRequest, invalidRequestMessage, fmt.Errorf("method is required"))
	}
	if !validRequestParams(msg.Params) {
		return newRequestReadError(ErrCodeInvalidRequest, invalidRequestMessage, fmt.Errorf("params must be an object or array"))
	}
	if !validRequestID(msg.ID) {
		return newRequestReadError(ErrCodeInvalidRequest, invalidRequestMessage, fmt.Errorf("id must be a string or number when present"))
	}
	return nil
}

func newRequestReadError(code int, message string, cause error) *MessageReadError {
	return &MessageReadError{Code: code, Message: message, Cause: cause}
}

func validRequestParams(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return true
	}
	if !json.Valid(trimmed) {
		return false
	}
	return trimmed[0] == '{' || trimmed[0] == '['
}

func validRequestID(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return true
	}
	if bytes.Equal(trimmed, []byte("null")) {
		return false
	}
	if !json.Valid(trimmed) {
		return false
	}
	if trimmed[0] == '"' {
		return true
	}
	return trimmed[0] == '-' || trimmed[0] >= '0' && trimmed[0] <= '9'
}
