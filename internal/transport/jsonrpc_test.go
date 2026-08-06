// Copyright 2026 Joseph Cumines

package transport

import (
	"errors"
	"testing"
)

func TestDecodeRequest(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantCode int
	}{
		{name: "request", input: `{"jsonrpc":"2.0","id":1,"method":"ping"}`},
		{name: "notification", input: `{"jsonrpc":"2.0","method":"ping"}`},
		{name: "null ID request", input: `{"jsonrpc":"2.0","id":null,"method":"ping"}`, wantCode: ErrCodeInvalidRequest},
		{name: "string ID", input: `{"jsonrpc":"2.0","id":"request-1","method":"ping"}`},
		{name: "array params", input: `{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}`},
		{name: "object params", input: `{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}`},
		{name: "malformed", input: `{malformed`, wantCode: ErrCodeParseError},
		{name: "trailing JSON", input: `{"jsonrpc":"2.0","id":1,"method":"ping"} trailing`, wantCode: ErrCodeParseError},
		{name: "empty", input: ``, wantCode: ErrCodeParseError},
		{name: "array message", input: `[]`, wantCode: ErrCodeInvalidRequest},
		{name: "empty object", input: `{}`, wantCode: ErrCodeInvalidRequest},
		{name: "wrong version", input: `{"jsonrpc":"1.0","id":1,"method":"ping"}`, wantCode: ErrCodeInvalidRequest},
		{name: "numeric version", input: `{"jsonrpc":2,"id":1,"method":"ping"}`, wantCode: ErrCodeInvalidRequest},
		{name: "non-string method", input: `{"jsonrpc":"2.0","id":1,"method":1}`, wantCode: ErrCodeInvalidRequest},
		{name: "scalar params", input: `{"jsonrpc":"2.0","id":1,"method":"ping","params":"bad"}`, wantCode: ErrCodeInvalidRequest},
		{name: "boolean ID", input: `{"jsonrpc":"2.0","id":true,"method":"ping"}`, wantCode: ErrCodeInvalidRequest},
		{name: "object ID", input: `{"jsonrpc":"2.0","id":{},"method":"ping"}`, wantCode: ErrCodeInvalidRequest},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			message, err := DecodeRequest([]byte(test.input))
			if test.wantCode == 0 {
				if err != nil {
					t.Fatalf("DecodeRequest() error = %v", err)
				}
				if message == nil || message.Method != "ping" {
					t.Fatalf("DecodeRequest() message = %+v", message)
				}
				return
			}
			if message != nil {
				t.Fatalf("DecodeRequest() message = %+v, want nil", message)
			}
			var readErr *MessageReadError
			if !errors.As(err, &readErr) {
				t.Fatalf("DecodeRequest() error = %T %v, want *MessageReadError", err, err)
			}
			if readErr.Code != test.wantCode {
				t.Fatalf("DecodeRequest() code = %d, want %d", readErr.Code, test.wantCode)
			}
		})
	}
}
