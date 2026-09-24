// Copyright 2026 Joseph Cumines

package internal

import (
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	annotations "google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
)

func TestWindowPublishesLayerAndRemovesMisleadingZIndex(t *testing.T) {
	message := (&pb.Window{}).ProtoReflect().Descriptor()
	fields := message.Fields()
	if field := fields.ByName("z_index"); field != nil {
		t.Fatalf("Window.z_index remains live at field %d", field.Number())
	}
	layer := fields.ByName("layer")
	if layer == nil {
		t.Fatal("Window.layer is missing")
	}
	if layer.Number() != 6 || layer.Kind() != protoreflect.Int32Kind {
		t.Fatalf("Window.layer = field %d kind %s, want field 6 int32", layer.Number(), layer.Kind())
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

	if message.ReservedNames().Len() != 0 || message.ReservedRanges().Len() != 0 {
		t.Fatal("Window must not retain reservations after the final declaration-order contract")
	}
}

func TestWindowStateRemovesUnimplementedFullscreen(t *testing.T) {
	message := (&pb.WindowState{}).ProtoReflect().Descriptor()
	if field := message.Fields().ByName("fullscreen"); field != nil {
		t.Fatalf("WindowState.fullscreen remains live at field %d", field.Number())
	}
	if message.ReservedNames().Len() != 0 || message.ReservedRanges().Len() != 0 {
		t.Fatal("WindowState must not retain reservations after the final declaration-order contract")
	}
}
