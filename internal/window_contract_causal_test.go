// Copyright 2026 Joseph Cumines

package internal

import (
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	annotations "google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
)

func TestWindowPublishesLayerAndReservesMisleadingZIndex(t *testing.T) {
	message := (&pb.Window{}).ProtoReflect().Descriptor()
	fields := message.Fields()
	if field := fields.ByName("z_index"); field != nil {
		t.Fatalf("Window.z_index remains live at field %d", field.Number())
	}
	layer := fields.ByName("layer")
	if layer == nil {
		t.Fatal("Window.layer is missing")
	}
	if layer.Number() != 11 || layer.Kind() != protoreflect.Int32Kind {
		t.Fatalf("Window.layer = field %d kind %s, want field 11 int32", layer.Number(), layer.Kind())
	}
	options, ok := layer.Options().(*descriptorpb.FieldOptions)
	if !ok || !proto.HasExtension(options, annotations.E_FieldBehavior) {
		t.Fatal("Window.layer has no field behavior")
	}
	behaviors, ok := proto.GetExtension(options, annotations.E_FieldBehavior).([]annotations.FieldBehavior)
	if !ok {
		t.Fatal("Window.layer field behavior extension has unexpected type")
	}
	outputOnly := false
	for _, behavior := range behaviors {
		outputOnly = outputOnly || behavior == annotations.FieldBehavior_OUTPUT_ONLY
	}
	if !outputOnly {
		t.Fatal("Window.layer must be output-only")
	}

	reservedName := false
	for index := 0; index < message.ReservedNames().Len(); index++ {
		reservedName = reservedName || message.ReservedNames().Get(index) == "z_index"
	}
	if !reservedName {
		t.Fatal("Window must reserve removed name z_index")
	}

	reservedNumber := false
	for index := 0; index < message.ReservedRanges().Len(); index++ {
		fieldRange := message.ReservedRanges().Get(index)
		reservedNumber = reservedNumber || fieldRange[0] <= 4 && 4 < fieldRange[1]
	}
	if !reservedNumber {
		t.Fatal("Window must reserve removed field number 4")
	}
}

func TestWindowStateReservesUnimplementedFullscreen(t *testing.T) {
	message := (&pb.WindowState{}).ProtoReflect().Descriptor()
	if field := message.Fields().ByName("fullscreen"); field != nil {
		t.Fatalf("WindowState.fullscreen remains live at field %d", field.Number())
	}
	reservedName := false
	for index := 0; index < message.ReservedNames().Len(); index++ {
		reservedName = reservedName || message.ReservedNames().Get(index) == "fullscreen"
	}
	if !reservedName {
		t.Fatal("WindowState must reserve removed name fullscreen")
	}
	reservedNumber := false
	for index := 0; index < message.ReservedRanges().Len(); index++ {
		fieldRange := message.ReservedRanges().Get(index)
		reservedNumber = reservedNumber || fieldRange[0] <= 10 && 10 < fieldRange[1]
	}
	if !reservedNumber {
		t.Fatal("WindowState must reserve removed field number 10")
	}
}
