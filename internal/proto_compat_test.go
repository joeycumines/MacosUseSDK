// Copyright 2025 Joseph Cumines
//
// Proto backward compatibility tests
//
// These tests verify that protobuf messages maintain backward compatibility:
// - New fields have zero-value defaults (old messages still parse)
// - Field numbers are consistent with expected patterns
// - Enum values are additive (existing values preserved)

package internal

import (
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// TestProtoBackwardCompat_Window_ZeroValueDefaults verifies that an empty
// Window message deserializes correctly with all fields having zero values.
func TestProtoBackwardCompat_Window_ZeroValueDefaults(t *testing.T) {
	// Simulate an "old" message with no fields set (empty bytes)
	emptyBytes := []byte{}

	var window pb.Window
	if err := proto.Unmarshal(emptyBytes, &window); err != nil {
		t.Fatalf("Failed to unmarshal empty bytes into Window: %v", err)
	}

	// Verify zero-value defaults
	if window.Name != "" {
		t.Errorf("Expected empty Name, got %q", window.Name)
	}
	if window.Title != "" {
		t.Errorf("Expected empty Title, got %q", window.Title)
	}
	if window.Layer != 0 {
		t.Errorf("Expected zero Layer, got %d", window.Layer)
	}
	if window.Bounds != nil {
		t.Errorf("Expected nil Bounds, got %v", window.Bounds)
	}
	if window.Visible {
		t.Error("Expected Visible=false")
	}
	if window.BundleId != "" {
		t.Errorf("Expected empty BundleId, got %q", window.BundleId)
	}
}

// TestProtoBackwardCompat_Observation_ZeroValueDefaults verifies Observation defaults.
func TestProtoBackwardCompat_Observation_ZeroValueDefaults(t *testing.T) {
	emptyBytes := []byte{}

	var obs pb.Observation
	if err := proto.Unmarshal(emptyBytes, &obs); err != nil {
		t.Fatalf("Failed to unmarshal empty bytes into Observation: %v", err)
	}

	if obs.Name != "" {
		t.Errorf("Expected empty Name, got %q", obs.Name)
	}
	if obs.Type != pb.ObservationType_OBSERVATION_TYPE_UNSPECIFIED {
		t.Errorf("Expected OBSERVATION_TYPE_UNSPECIFIED, got %v", obs.Type)
	}
	if obs.State != pb.Observation_STATE_UNSPECIFIED {
		t.Errorf("Expected STATE_UNSPECIFIED, got %v", obs.State)
	}
}

// TestProtoBackwardCompat_Session_ZeroValueDefaults verifies Session defaults.
func TestProtoBackwardCompat_Session_ZeroValueDefaults(t *testing.T) {
	emptyBytes := []byte{}

	var session pb.Session
	if err := proto.Unmarshal(emptyBytes, &session); err != nil {
		t.Fatalf("Failed to unmarshal empty bytes into Session: %v", err)
	}

	if session.Name != "" {
		t.Errorf("Expected empty Name, got %q", session.Name)
	}
	if session.DisplayName != "" {
		t.Errorf("Expected empty DisplayName, got %q", session.DisplayName)
	}
	if session.State != pb.Session_STATE_UNSPECIFIED {
		t.Errorf("Expected STATE_UNSPECIFIED, got %v", session.State)
	}
}

// TestProtoFieldNumbers_Window verifies Window field numbers are stable.
func TestProtoFieldNumbers_Window(t *testing.T) {
	var window pb.Window
	md := window.ProtoReflect().Descriptor()
	fields := md.Fields()

	// Map of expected field numbers for critical fields (from window.proto)
	expectedFields := map[string]protoreflect.FieldNumber{
		"name":      1,
		"title":     2,
		"bounds":    3,
		"layer":     11,
		"visible":   5,
		"bundle_id": 10,
	}

	for fieldName, expectedNum := range expectedFields {
		fd := fields.ByName(protoreflect.Name(fieldName))
		if fd == nil {
			t.Errorf("Field %q not found in Window message", fieldName)
			continue
		}
		if fd.Number() != expectedNum {
			t.Errorf("Field %q has number %d, expected %d", fieldName, fd.Number(), expectedNum)
		}
	}
}

// TestProtoFieldNumbers_Observation verifies Observation field numbers are stable.
func TestProtoFieldNumbers_Observation(t *testing.T) {
	var obs pb.Observation
	md := obs.ProtoReflect().Descriptor()
	fields := md.Fields()

	expectedFields := map[string]protoreflect.FieldNumber{
		"name":        1,
		"type":        2,
		"state":       3,
		"create_time": 4,
	}

	for fieldName, expectedNum := range expectedFields {
		fd := fields.ByName(protoreflect.Name(fieldName))
		if fd == nil {
			t.Errorf("Field %q not found in Observation message", fieldName)
			continue
		}
		if fd.Number() != expectedNum {
			t.Errorf("Field %q has number %d, expected %d", fieldName, fd.Number(), expectedNum)
		}
	}
}

// TestProtoFieldNumbers_Application verifies Application field numbers are stable.
func TestProtoFieldNumbers_Application(t *testing.T) {
	var app pb.Application
	md := app.ProtoReflect().Descriptor()
	fields := md.Fields()

	expectedFields := map[string]protoreflect.FieldNumber{
		"name":               1,
		"pid":                2,
		"display_name":       3,
		"application_bundle": 4,
		"bundle_id":          5,
		"active":             6,
		"process_start_time": 7,
	}

	for fieldName, expectedNum := range expectedFields {
		fd := fields.ByName(protoreflect.Name(fieldName))
		if fd == nil {
			t.Errorf("Field %q not found in Application message", fieldName)
			continue
		}
		if fd.Number() != expectedNum {
			t.Errorf("Field %q has number %d, expected %d", fieldName, fd.Number(), expectedNum)
		}
	}
}

// TestProtoFieldNumbers_ApplicationBundle verifies exact installed bundle
// identity remains wire-compatible.
func TestProtoFieldNumbers_ApplicationBundle(t *testing.T) {
	var bundle pb.ApplicationBundle
	fields := bundle.ProtoReflect().Descriptor().Fields()
	expectedFields := map[string]protoreflect.FieldNumber{
		"name":         1,
		"display_name": 2,
		"bundle_id":    3,
		"bundle_url":   4,
		"version":      5,
	}
	for fieldName, expectedNum := range expectedFields {
		fd := fields.ByName(protoreflect.Name(fieldName))
		if fd == nil {
			t.Errorf("Field %q not found in ApplicationBundle message", fieldName)
			continue
		}
		if fd.Number() != expectedNum {
			t.Errorf("Field %q has number %d, expected %d", fieldName, fd.Number(), expectedNum)
		}
	}
}

// TestProtoFieldNumbers_Session verifies Session field numbers are stable.
// Note: Field 6 is intentionally skipped in the proto to reserve for future use.
func TestProtoFieldNumbers_Session(t *testing.T) {
	var session pb.Session
	md := session.ProtoReflect().Descriptor()
	fields := md.Fields()

	expectedFields := map[string]protoreflect.FieldNumber{
		"name":             1,
		"display_name":     2,
		"state":            3,
		"create_time":      4,
		"last_access_time": 5,
		// Field 6 intentionally skipped
		"expire_time":    7,
		"transaction_id": 8,
		"metadata":       9,
	}

	for fieldName, expectedNum := range expectedFields {
		fd := fields.ByName(protoreflect.Name(fieldName))
		if fd == nil {
			t.Errorf("Field %q not found in Session message", fieldName)
			continue
		}
		if fd.Number() != expectedNum {
			t.Errorf("Field %q has number %d, expected %d", fieldName, fd.Number(), expectedNum)
		}
	}
}

// TestProtoFieldNumbers_Input verifies Input field numbers are stable.
func TestProtoFieldNumbers_Input(t *testing.T) {
	var input pb.Input
	md := input.ProtoReflect().Descriptor()
	fields := md.Fields()

	expectedFields := map[string]protoreflect.FieldNumber{
		"name":            1,
		"action":          2,
		"state":           3,
		"create_time":     4,
		"complete_time":   5,
		"error":           6,
		"target":          7,
		"delivery_result": 8,
	}

	for fieldName, expectedNum := range expectedFields {
		fd := fields.ByName(protoreflect.Name(fieldName))
		if fd == nil {
			t.Errorf("Field %q not found in Input message", fieldName)
			continue
		}
		if fd.Number() != expectedNum {
			t.Errorf("Field %q has number %d, expected %d", fieldName, fd.Number(), expectedNum)
		}
	}
}

// TestProtoFieldNumbers_InputTarget verifies every exact target arm remains
// stable on the wire.
func TestProtoFieldNumbers_InputTarget(t *testing.T) {
	var target pb.InputTarget
	fields := target.ProtoReflect().Descriptor().Fields()
	expectedFields := map[string]protoreflect.FieldNumber{
		"application": 1,
		"window":      2,
		"display":     3,
		"desktop":     4,
	}
	for fieldName, expectedNum := range expectedFields {
		fd := fields.ByName(protoreflect.Name(fieldName))
		if fd == nil {
			t.Errorf("Field %q not found in InputTarget message", fieldName)
			continue
		}
		if fd.Number() != expectedNum {
			t.Errorf("Field %q has number %d, expected %d", fieldName, fd.Number(), expectedNum)
		}
	}
}

// TestProtoFieldNumbers_InputDeliveryResult verifies delivery truth remains
// stable on the wire.
func TestProtoFieldNumbers_InputDeliveryResult(t *testing.T) {
	var delivery pb.InputDeliveryResult
	fields := delivery.ProtoReflect().Descriptor().Fields()
	expectedFields := map[string]protoreflect.FieldNumber{
		"commitment":               1,
		"posted_event_count":       2,
		"routed_delivery_observed": 3,
	}
	for fieldName, expectedNum := range expectedFields {
		fd := fields.ByName(protoreflect.Name(fieldName))
		if fd == nil {
			t.Errorf("Field %q not found in InputDeliveryResult message", fieldName)
			continue
		}
		if fd.Number() != expectedNum {
			t.Errorf("Field %q has number %d, expected %d", fieldName, fd.Number(), expectedNum)
		}
	}
}

// TestProtoEnumValues_ObservationType verifies ObservationType enum values are stable.
func TestProtoEnumValues_ObservationType(t *testing.T) {
	expectedValues := map[string]int32{
		"OBSERVATION_TYPE_UNSPECIFIED":         0,
		"OBSERVATION_TYPE_ELEMENT_CHANGES":     1,
		"OBSERVATION_TYPE_WINDOW_CHANGES":      2,
		"OBSERVATION_TYPE_APPLICATION_CHANGES": 3,
		"OBSERVATION_TYPE_ATTRIBUTE_CHANGES":   4,
		"OBSERVATION_TYPE_TREE_CHANGES":        5,
	}

	for name, expectedNum := range expectedValues {
		// Get enum value by name
		val := pb.ObservationType_value[name]
		if val != expectedNum {
			t.Errorf("Enum %s has value %d, expected %d", name, val, expectedNum)
		}
	}
}

// TestProtoEnumValues_ObservationState verifies Observation.State enum values are stable.
func TestProtoEnumValues_ObservationState(t *testing.T) {
	expectedValues := map[string]int32{
		"STATE_UNSPECIFIED": 0,
		"STATE_PENDING":     1,
		"STATE_ACTIVE":      2,
		"STATE_COMPLETED":   3,
		"STATE_CANCELLED":   4,
		"STATE_FAILED":      5,
	}

	for name, expectedNum := range expectedValues {
		val := pb.Observation_State_value[name]
		if val != expectedNum {
			t.Errorf("Enum Observation.State.%s has value %d, expected %d", name, val, expectedNum)
		}
	}
}

// TestProtoEnumValues_InputState verifies Input.State enum values are stable.
func TestProtoEnumValues_InputState(t *testing.T) {
	expectedValues := map[string]int32{
		"STATE_UNSPECIFIED": 0,
		"STATE_PENDING":     1,
		"STATE_EXECUTING":   2,
		"STATE_COMPLETED":   3,
		"STATE_FAILED":      4,
		"STATE_CANCELLED":   5,
	}

	for name, expectedNum := range expectedValues {
		val := pb.Input_State_value[name]
		if val != expectedNum {
			t.Errorf("Enum Input.State.%s has value %d, expected %d", name, val, expectedNum)
		}
	}
}

// TestProtoEnumValues_InputDeliveryCommitment verifies every public delivery
// truth value remains stable.
func TestProtoEnumValues_InputDeliveryCommitment(t *testing.T) {
	expectedValues := map[string]int32{
		"COMMITMENT_UNSPECIFIED":           0,
		"COMMITMENT_NO_EFFECT":             1,
		"COMMITMENT_POSSIBLY_COMMITTED":    2,
		"COMMITMENT_COMMITTED_AND_SETTLED": 3,
	}
	for name, expectedNum := range expectedValues {
		val := pb.InputDeliveryResult_Commitment_value[name]
		if val != expectedNum {
			t.Errorf(
				"Enum InputDeliveryResult.Commitment.%s has value %d, expected %d",
				name,
				val,
				expectedNum,
			)
		}
	}
}

// TestProtoEnumValues_ClickType verifies MouseClick.ClickType enum values are stable.
func TestProtoEnumValues_ClickType(t *testing.T) {
	expectedValues := map[string]int32{
		"CLICK_TYPE_UNSPECIFIED": 0,
		"CLICK_TYPE_LEFT":        1,
		"CLICK_TYPE_RIGHT":       2,
		"CLICK_TYPE_MIDDLE":      3,
	}

	for name, expectedNum := range expectedValues {
		val := pb.MouseClick_ClickType_value[name]
		if val != expectedNum {
			t.Errorf("Enum MouseClick.ClickType.%s has value %d, expected %d", name, val, expectedNum)
		}
	}
}

// TestProtoEnumValues_SessionState verifies Session.State enum values are stable.
func TestProtoEnumValues_SessionState(t *testing.T) {
	expectedValues := map[string]int32{
		"STATE_UNSPECIFIED":    0,
		"STATE_ACTIVE":         1,
		"STATE_IN_TRANSACTION": 2,
		"STATE_TERMINATED":     3,
		"STATE_EXPIRED":        4,
		"STATE_FAILED":         5,
	}

	for name, expectedNum := range expectedValues {
		val := pb.Session_State_value[name]
		if val != expectedNum {
			t.Errorf("Enum Session.State.%s has value %d, expected %d", name, val, expectedNum)
		}
	}
}

// TestProtoMessageFieldCounts verifies minimum field counts for key messages.
// This catches accidental field removals.
func TestProtoMessageFieldCounts(t *testing.T) {
	testCases := []struct {
		name     string
		msg      proto.Message
		minCount int
	}{
		{"Window", &pb.Window{}, 6},           // name, title, bounds, visible, bundle_id, layer
		{"Observation", &pb.Observation{}, 8}, // name, type, state, create_time, start_time, end_time, filter, activate
		{"Application", &pb.Application{}, 7}, // exact process identity and display metadata
		{"ApplicationBundle", &pb.ApplicationBundle{}, 5},
		{"Session", &pb.Session{}, 8}, // name, display_name, state, create_time, last_access_time, expire_time, transaction_id, metadata
		{"Input", &pb.Input{}, 8},     // plus exact target and delivery result
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			md := tc.msg.ProtoReflect().Descriptor()
			fieldCount := md.Fields().Len()
			if fieldCount < tc.minCount {
				t.Errorf("%s has %d fields, expected at least %d", tc.name, fieldCount, tc.minCount)
			}
		})
	}
}

// TestProtoUnknownFieldPreservation verifies that messages preserve unknown fields
// during round-trip serialization (forward compatibility).
func TestProtoUnknownFieldPreservation(t *testing.T) {
	// Create a Window with known fields
	original := &pb.Window{
		Name:  "windows/123",
		Title: "Test Window",
		Layer: 42,
	}

	// Serialize
	data, err := proto.Marshal(original)
	if err != nil {
		t.Fatalf("Failed to marshal Window: %v", err)
	}

	// Add some "unknown" bytes (simulating a future field)
	// Field 99 with varint value 42
	unknownField := []byte{0xF8, 0x06, 0x2A} // tag 99 varint, value 42
	dataWithUnknown := append(data, unknownField...)

	// Deserialize
	var parsed pb.Window
	if err := proto.Unmarshal(dataWithUnknown, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal with unknown field: %v", err)
	}

	// Verify known fields are preserved
	if parsed.Name != original.Name {
		t.Errorf("Name not preserved: got %q, want %q", parsed.Name, original.Name)
	}
	if parsed.Title != original.Title {
		t.Errorf("Title not preserved: got %q, want %q", parsed.Title, original.Title)
	}
	if parsed.Layer != original.Layer {
		t.Errorf("Layer not preserved: got %d, want %d", parsed.Layer, original.Layer)
	}

	// Re-serialize and verify unknown field is preserved
	reserialized, err := proto.Marshal(&parsed)
	if err != nil {
		t.Fatalf("Failed to re-marshal: %v", err)
	}

	// The reserialized data should be longer than original (includes unknown field)
	if len(reserialized) <= len(data) {
		t.Errorf("Unknown field not preserved: reserialized len=%d, original len=%d",
			len(reserialized), len(data))
	}
}
