// Copyright 2025 Joseph Cumines
package server

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math"
	"strings"
	"unicode/utf8"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

const (
	defaultCUAClickCount int32 = 1
	maximumCUAClickCount int32 = 10
)

func parseCUAButton(button *string) (pb.MouseClick_ClickType, error) {
	if button == nil {
		return pb.MouseClick_CLICK_TYPE_LEFT, nil
	}
	switch *button {
	case "left":
		return pb.MouseClick_CLICK_TYPE_LEFT, nil
	case "right":
		return pb.MouseClick_CLICK_TYPE_RIGHT, nil
	case "middle":
		return pb.MouseClick_CLICK_TYPE_MIDDLE, nil
	default:
		return pb.MouseClick_CLICK_TYPE_UNSPECIFIED, fmt.Errorf(
			"unsupported button %q; expected left, right, or middle",
			*button,
		)
	}
}

func parseCUAClickCount(clickCount *int32) (int32, error) {
	if clickCount == nil {
		return defaultCUAClickCount, nil
	}
	if *clickCount < 1 || *clickCount > maximumCUAClickCount {
		return 0, fmt.Errorf("click_count must be between 1 and %d", maximumCUAClickCount)
	}
	return *clickCount, nil
}

func parseCUAModifiers(keys []string) ([]pb.KeyPress_Modifier, error) {
	modifiers := make([]pb.KeyPress_Modifier, 0, len(keys))
	seen := make(map[pb.KeyPress_Modifier]string, len(keys))
	for _, key := range keys {
		modifier, ok := cuaModifier(key)
		if !ok {
			return nil, fmt.Errorf("keys accepts modifier keys only; unsupported value %q", key)
		}
		if previous, duplicate := seen[modifier]; duplicate {
			return nil, fmt.Errorf("duplicate modifier intent %q and %q", previous, key)
		}
		seen[modifier] = key
		modifiers = append(modifiers, modifier)
	}
	return modifiers, nil
}

func parseCUAKeyChord(keys []string) (string, []pb.KeyPress_Modifier, error) {
	if len(keys) == 0 {
		return "", nil, fmt.Errorf("keys parameter is required and must be non-empty")
	}
	modifiers := make([]pb.KeyPress_Modifier, 0, len(keys)-1)
	seenModifiers := make(map[pb.KeyPress_Modifier]string, len(keys))
	primaryKeys := make([]string, 0, 1)
	for _, key := range keys {
		if modifier, ok := cuaModifier(key); ok {
			if previous, duplicate := seenModifiers[modifier]; duplicate {
				return "", nil, fmt.Errorf("duplicate modifier intent %q and %q", previous, key)
			}
			seenModifiers[modifier] = key
			modifiers = append(modifiers, modifier)
			continue
		}
		primaryKey, err := normalizeCUAPrimaryKey(key)
		if err != nil {
			return "", nil, err
		}
		primaryKeys = append(primaryKeys, primaryKey)
	}
	if len(primaryKeys) != 1 {
		return "", nil, fmt.Errorf(
			"keypress requires exactly one primary key, got %d",
			len(primaryKeys),
		)
	}
	return primaryKeys[0], modifiers, nil
}

func cuaModifier(key string) (pb.KeyPress_Modifier, bool) {
	switch strings.ToLower(key) {
	case "ctrl", "control":
		return pb.KeyPress_MODIFIER_CONTROL, true
	case "alt", "option":
		return pb.KeyPress_MODIFIER_OPTION, true
	case "meta", "command", "cmd":
		return pb.KeyPress_MODIFIER_COMMAND, true
	case "shift":
		return pb.KeyPress_MODIFIER_SHIFT, true
	case "fn", "function":
		return pb.KeyPress_MODIFIER_FUNCTION, true
	default:
		return pb.KeyPress_MODIFIER_UNSPECIFIED, false
	}
}

func normalizeCUAPrimaryKey(key string) (string, error) {
	if key == "" {
		return "", fmt.Errorf("primary key must not be blank")
	}
	lowered := strings.ToLower(key)
	if normalized, ok := cuaKeyMap[lowered]; ok {
		return normalized, nil
	}
	if utf8.RuneCountInString(key) == 1 {
		return lowered, nil
	}
	return "", fmt.Errorf("unknown primary key %q", key)
}

func buildCUAInputRequest(rawTarget string, input *pb.Input) (*pb.CreateInputRequest, error) {
	parent, target, err := parseCUAInputTarget(rawTarget)
	if err != nil {
		return nil, err
	}
	if input == nil {
		return nil, fmt.Errorf("input is required")
	}
	var randomID [16]byte
	if _, err := rand.Read(randomID[:]); err != nil {
		return nil, fmt.Errorf("generate input id: %w", err)
	}
	input.Target = target
	return &pb.CreateInputRequest{
		Parent:  parent,
		Input:   input,
		InputId: "mcp-" + hex.EncodeToString(randomID[:]),
	}, nil
}

func buildCUAKeyboardInputRequest(
	rawTarget string,
	input *pb.Input,
) (*pb.CreateInputRequest, error) {
	request, err := buildCUAInputRequest(rawTarget, input)
	if err != nil {
		return nil, err
	}
	if request.GetInput().GetTarget().GetDisplay() != "" {
		return nil, fmt.Errorf(
			"keyboard target must be desktop, applications/{application}, or applications/{application}/windows/{window}",
		)
	}
	return request, nil
}

func parseCUAInputTarget(rawTarget string) (string, *pb.InputTarget, error) {
	target := rawTarget
	if target == "" {
		return "", nil, fmt.Errorf("target is required")
	}
	if target == "desktop" {
		return defaultApplicationParent, &pb.InputTarget{
			Destination: &pb.InputTarget_Desktop{Desktop: true},
		}, nil
	}

	parts := strings.Split(target, "/")
	switch {
	case len(parts) == 2 &&
		parts[0] == "applications" &&
		isCanonicalCUAResourceID(parts[1]) &&
		parts[1] != "-":
		return target, &pb.InputTarget{
			Destination: &pb.InputTarget_Application{Application: target},
		}, nil
	case len(parts) == 4 &&
		parts[0] == "applications" &&
		isCanonicalCUAResourceID(parts[1]) &&
		parts[1] != "-" &&
		parts[2] == "windows" &&
		isCanonicalCUAResourceID(parts[3]) &&
		parts[3] != "-":
		parent := strings.Join(parts[:2], "/")
		return parent, &pb.InputTarget{
			Destination: &pb.InputTarget_Window{Window: target},
		}, nil
	case len(parts) == 2 &&
		parts[0] == "displays" &&
		isCanonicalDisplayResourceName(target):
		return defaultApplicationParent, &pb.InputTarget{
			Destination: &pb.InputTarget_Display{Display: target},
		}, nil
	default:
		return "", nil, fmt.Errorf(
			"target must be desktop, applications/{application}, applications/{application}/windows/{window}, or displays/{display}",
		)
	}
}

func isCanonicalCUAResourceID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if char >= 'a' && char <= 'z' ||
			char >= 'A' && char <= 'Z' ||
			char >= '0' && char <= '9' ||
			char == '-' || char == '_' || char == '.' || char == '~' {
			continue
		}
		return false
	}
	return true
}

func isFinite(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0)
}

func validateCUAKeypressInput(arguments map[string]any) error {
	rawKeys, ok := arguments["keys"].([]any)
	if !ok {
		return fmt.Errorf("keys parameter is required and must be an array")
	}
	keys := make([]string, len(rawKeys))
	for index, rawKey := range rawKeys {
		key, ok := rawKey.(string)
		if !ok {
			return fmt.Errorf("keys[%d] must be a string", index)
		}
		keys[index] = key
	}
	_, _, err := parseCUAKeyChord(keys)
	return err
}
