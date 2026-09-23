// Copyright 2026 Joseph Cumines

package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/joeycumines/ExactMac/internal/transport"
	"google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
)

func TestExecutableMCPContractMatrix(t *testing.T) {
	server := &MCPServer{tools: make(map[string]*Tool)}
	server.registerTools()

	liveNames := keySet(server.tools)
	expectedNames := keySet(executableToolContracts)
	assertInventoryEqual(t, "production MCP registry", expectedNames, liveNames)

	rpcNames := descriptorMethodSet(t)
	serverDir := filepath.Join(repositoryRoot(t), "internal", "server")
	for name, contract := range executableToolContracts {
		tool := server.tools[name]
		if tool == nil {
			continue
		}
		if tool.Name != name {
			t.Errorf("registry key %q exposes mismatched tool name %q", name, tool.Name)
		}
		if tool.Description == "" || tool.InputSchema == nil || tool.Handler == nil {
			t.Errorf("tool %q has incomplete executable metadata", name)
		}
		if contract.effect == "" || contract.proof == "" || contract.source == "" || contract.handler == "" {
			t.Errorf("tool %q has incomplete contract classification: %+v", name, contract)
		}
		if got := handlerName(tool.Handler); got != contract.handler {
			t.Errorf("tool %q handler = %q, want %q", name, got, contract.handler)
		}

		source := readFile(t, filepath.Join(serverDir, contract.source))
		if !strings.Contains(source, "func (s *MCPServer) "+contract.handler+"(") {
			t.Errorf("tool %q handler %q is absent from %s", name, contract.handler, contract.source)
		}
		for _, rpc := range contract.exactMacRPCs {
			if _, ok := rpcNames[rpc]; !ok {
				t.Errorf("tool %q depends on missing ExactMac RPC %q", name, rpc)
			}
			if !strings.Contains(source, "s.client."+rpc+"(") {
				t.Errorf("tool %q contract says %s is used, but %s contains no client call", name, rpc, contract.source)
			}
		}
		for _, rpc := range contract.externalRPCs {
			if rpc != "google.longrunning.Operations.GetOperation" || !strings.Contains(source, "s.opsClient.GetOperation(") {
				t.Errorf("tool %q has unverified external RPC dependency %q", name, rpc)
			}
		}
	}

	direct := listedToolsFromRegistry(t, server.tools)
	http := listedToolsFromHTTP(t, server)
	stdio := listedToolsFromStdio(t, server)
	assertToolSurfacesEqual(t, "HTTP tools/list", direct, http)
	assertToolSurfacesEqual(t, "stdio tools/list", direct, stdio)
}

func TestExecutableGRPCContractMatrix(t *testing.T) {
	service := pb.File_exactmac_v1_exact_mac_proto.Services().ByName("ExactMac")
	if service == nil {
		t.Fatal("live protobuf descriptor has no ExactMac service")
	}

	contracts := flattenRPCContracts(t)
	liveNames := descriptorMethodSet(t)
	assertInventoryEqual(t, "ExactMac protobuf descriptor", keySet(contracts), liveNames)

	root := repositoryRoot(t)
	generatedSwift := readFile(t, filepath.Join(root, "Server", "Sources", "ExactMacProto", "exactmac", "v1", "exact_mac.grpc.swift"))
	serviceProtocol := swiftServiceProtocol(t, generatedSwift)
	serviceSource := readFile(t, filepath.Join(root, "Server", "Sources", "ExactMacServer", "ExactMacService.swift"))
	if !strings.Contains(serviceSource, "final class ExactMacService: Exactmac_V1_ExactMac.ServiceProtocol") {
		t.Error("ExactMacService does not declare generated ServiceProtocol conformance")
	}

	clientType := reflect.TypeFor[pb.ExactMacClient]()
	providerDir := filepath.Join(root, "Server", "Sources", "ExactMacServer")
	providerSources := make(map[string]string)
	for provider := range providerSet(contracts) {
		providerSources[provider] = readFile(t, filepath.Join(providerDir, provider))
	}

	methods := service.Methods()
	for index := 0; index < methods.Len(); index++ {
		descriptor := methods.Get(index)
		name := string(descriptor.Name())
		contract, ok := contracts[name]
		if !ok {
			continue
		}
		if contract.effect == "" || contract.proof == "" || contract.provider == "" {
			t.Errorf("RPC %q has incomplete executable classification: %+v", name, contract)
		}

		assertGoClientMethod(t, clientType, descriptor)
		swiftName := lowerCamel(name)
		if !strings.Contains(serviceProtocol, "func "+swiftName+"(") {
			t.Errorf("generated Swift ServiceProtocol is missing %s for RPC %s", swiftName, name)
		}
		if !strings.Contains(providerSources[contract.provider], "func "+swiftName+"(") {
			t.Errorf("Swift provider %s is missing %s for RPC %s", contract.provider, swiftName, name)
		}
		for provider, source := range providerSources {
			if provider != contract.provider && strings.Contains(source, "func "+swiftName+"(") {
				t.Errorf("RPC %s is unexpectedly also implemented in %s", name, provider)
			}
		}
	}
}

func TestExecutableGRPCMetadataContract(t *testing.T) {
	service := pb.File_exactmac_v1_exact_mac_proto.Services().ByName("ExactMac")
	if service == nil {
		t.Fatal("live protobuf descriptor has no ExactMac service")
	}

	methods := service.Methods()
	protoSource := readFile(t, filepath.Join(repositoryRoot(t), "proto", "exactmac", "v1", "exact_mac.proto"))
	if got := strings.Count(protoSource, "\n  rpc "); got != methods.Len() {
		t.Errorf("exact_mac.proto declares %d RPC source blocks, live descriptor has %d", got, methods.Len())
	}
	if got := strings.Count(protoSource, "option (google.api.http)"); got != methods.Len() {
		t.Errorf("exact_mac.proto declares %d HTTP options for %d RPCs; each RPC must have exactly one", got, methods.Len())
	}

	resourceTypes := executableResourceTypes(t)
	routes := make(map[string]string)
	for index := 0; index < methods.Len(); index++ {
		method := methods.Get(index)
		options, ok := method.Options().(*descriptorpb.MethodOptions)
		if !ok {
			t.Errorf("RPC %s has unexpected method options type %T", method.FullName(), method.Options())
			continue
		}

		assertExecutableHTTPRule(t, method, options, routes)
		assertExecutableMethodSignatures(t, method, options)
		assertExecutableLROMetadata(t, method, options)
		if name := string(method.Name()); strings.HasPrefix(name, "List") || strings.HasPrefix(name, "Find") {
			assertExecutablePaginationShape(t, method)
		}
	}
	assertExecutableResourceReferences(t, resourceTypes)
}

func TestApplicationDiscoveryResourceContract(t *testing.T) {
	service := pb.File_exactmac_v1_exact_mac_proto.Services().ByName("ExactMac")
	if service == nil {
		t.Fatal("live protobuf descriptor has no ExactMac service")
	}

	requireMethod := func(name protoreflect.Name) protoreflect.MethodDescriptor {
		t.Helper()
		method := service.Methods().ByName(name)
		if method == nil {
			t.Errorf("ExactMac is missing %s", name)
		}
		return method
	}
	requireMessage := func(name protoreflect.FullName) protoreflect.MessageDescriptor {
		t.Helper()
		messageType, err := protoregistry.GlobalTypes.FindMessageByName(name)
		if err != nil {
			t.Errorf("descriptor is missing message %s: %v", name, err)
			return nil
		}
		return messageType.Descriptor()
	}
	requireField := func(message protoreflect.MessageDescriptor, name protoreflect.Name, kind protoreflect.Kind) protoreflect.FieldDescriptor {
		t.Helper()
		if message == nil {
			return nil
		}
		field := message.Fields().ByName(name)
		if field == nil {
			t.Errorf("message %s is missing %s", message.FullName(), name)
			return nil
		}
		if field.Kind() != kind || field.Cardinality() == protoreflect.Repeated {
			t.Errorf("field %s has kind/cardinality %s/%s, want singular %s", field.FullName(), field.Kind(), field.Cardinality(), kind)
		}
		return field
	}
	requireResourceReference := func(field protoreflect.FieldDescriptor, want string) {
		t.Helper()
		if field == nil {
			return
		}
		options, ok := field.Options().(*descriptorpb.FieldOptions)
		if !ok || !proto.HasExtension(options, annotations.E_ResourceReference) {
			t.Errorf("field %s has no resource reference", field.FullName())
			return
		}
		reference, ok := proto.GetExtension(options, annotations.E_ResourceReference).(*annotations.ResourceReference)
		if !ok || reference == nil || reference.GetType() != want {
			t.Errorf("field %s resource reference = %v, want type %q", field.FullName(), reference, want)
		}
	}
	requireResource := func(message protoreflect.MessageDescriptor, resourceType, pattern string) {
		t.Helper()
		if message == nil {
			return
		}
		options, ok := message.Options().(*descriptorpb.MessageOptions)
		if !ok || !proto.HasExtension(options, annotations.E_Resource) {
			t.Errorf("message %s has no resource descriptor", message.FullName())
			return
		}
		descriptor, ok := proto.GetExtension(options, annotations.E_Resource).(*annotations.ResourceDescriptor)
		if !ok || descriptor == nil {
			t.Errorf("message %s has invalid resource descriptor", message.FullName())
			return
		}
		if descriptor.GetType() != resourceType || !reflect.DeepEqual(descriptor.GetPattern(), []string{pattern}) {
			t.Errorf("message %s resource = type %q patterns %v, want type %q pattern %q", message.FullName(), descriptor.GetType(), descriptor.GetPattern(), resourceType, pattern)
		}
	}

	bundle := requireMessage("exactmac.v1.ApplicationBundle")
	requireResource(bundle, "exactmac/ApplicationBundle", "applicationBundles/{application_bundle}")
	requireField(bundle, "name", protoreflect.StringKind)
	requireField(bundle, "display_name", protoreflect.StringKind)
	requireField(bundle, "bundle_id", protoreflect.StringKind)
	requireField(bundle, "bundle_url", protoreflect.StringKind)
	requireField(bundle, "version", protoreflect.StringKind)

	application := requireMessage("exactmac.v1.Application")
	requireResource(application, "exactmac/Application", "applications/{application}")
	requireResourceReference(requireField(application, "application_bundle", protoreflect.StringKind), "exactmac/ApplicationBundle")
	requireField(application, "bundle_id", protoreflect.StringKind)
	requireField(application, "active", protoreflect.BoolKind)
	processStart := requireField(application, "process_start_time", protoreflect.MessageKind)
	if processStart != nil && processStart.Message().FullName() != "google.protobuf.Timestamp" {
		t.Errorf("field %s message type = %s, want google.protobuf.Timestamp", processStart.FullName(), processStart.Message().FullName())
	}

	for _, name := range []protoreflect.Name{"GetApplicationBundle", "ListApplicationBundles", "ActivateApplication"} {
		requireMethod(name)
	}

	open := requireMethod("OpenApplication")
	if open != nil {
		requireResourceReference(requireField(open.Input(), "name", protoreflect.StringKind), "exactmac/ApplicationBundle")
		if open.Input().Fields().ByName("id") != nil {
			t.Errorf("%s retains free-form id", open.Input().FullName())
		}
		mode := open.Input().Fields().ByName("mode")
		if mode != nil && mode.Enum().Values().ByName("APPLICATION_OPEN_MODE_ACTIVATE_ONLY") != nil {
			t.Errorf("%s retains activate-only overload instead of exact ActivateApplication", mode.Enum().FullName())
		}
	}

	activate := requireMethod("ActivateApplication")
	if activate != nil {
		requireResourceReference(requireField(activate.Input(), "name", protoreflect.StringKind), "exactmac/Application")
	}

	getApplication := requireMethod("GetApplication")
	if getApplication != nil {
		if getApplication.Input().Fields().ByName("read_mask") != nil {
			t.Errorf("%s retains contradictory read_mask", getApplication.Input().FullName())
		}
		requireField(getApplication.Input(), "view", protoreflect.EnumKind)
	}
	listApplications := requireMethod("ListApplications")
	if listApplications != nil {
		requireField(listApplications.Input(), "view", protoreflect.EnumKind)
	}
	listBundles := requireMethod("ListApplicationBundles")
	if listBundles != nil {
		requireField(listBundles.Input(), "page_size", protoreflect.Int32Kind)
		requireField(listBundles.Input(), "page_token", protoreflect.StringKind)
		requireField(listBundles.Input(), "filter", protoreflect.StringKind)
		requireField(listBundles.Input(), "order_by", protoreflect.StringKind)
		requireField(listBundles.Input(), "view", protoreflect.EnumKind)
		requireField(listBundles.Output(), "next_page_token", protoreflect.StringKind)
	}
}

var executableHTTPPathVariable = regexp.MustCompile(`\{([^}=]+)(?:=[^}]*)?\}`)

func assertExecutableHTTPRule(
	t *testing.T,
	method protoreflect.MethodDescriptor,
	options *descriptorpb.MethodOptions,
	routes map[string]string,
) {
	t.Helper()
	if !proto.HasExtension(options, annotations.E_Http) {
		t.Errorf("RPC %s has no google.api.http option", method.FullName())
		return
	}
	rule, ok := proto.GetExtension(options, annotations.E_Http).(*annotations.HttpRule)
	if !ok || rule == nil {
		t.Errorf("RPC %s has invalid google.api.http option %T", method.FullName(), proto.GetExtension(options, annotations.E_Http))
		return
	}

	var visit func(*annotations.HttpRule, bool)
	visit = func(candidate *annotations.HttpRule, additional bool) {
		if candidate == nil {
			t.Errorf("RPC %s has a nil HTTP binding", method.FullName())
			return
		}
		verb, path := executableHTTPPattern(candidate)
		if verb == "" || path == "" {
			t.Errorf("RPC %s has an incomplete HTTP binding: %v", method.FullName(), candidate)
			return
		}
		key := verb + " " + path
		if owner, duplicate := routes[key]; duplicate {
			t.Errorf("RPC %s duplicates HTTP route %q already owned by %s", method.FullName(), key, owner)
		} else {
			routes[key] = string(method.FullName())
		}

		for _, match := range executableHTTPPathVariable.FindAllStringSubmatch(path, -1) {
			if !executableFieldPathExists(method.Input(), match[1]) {
				t.Errorf("RPC %s HTTP path %q references missing request field %q", method.FullName(), path, match[1])
			}
		}
		if body := candidate.GetBody(); body != "" && body != "*" && !executableFieldPathExists(method.Input(), body) {
			t.Errorf("RPC %s HTTP body references missing request field %q", method.FullName(), body)
		}
		if additional && len(candidate.GetAdditionalBindings()) != 0 {
			t.Errorf("RPC %s has nested additional HTTP bindings", method.FullName())
		}
		for _, binding := range candidate.GetAdditionalBindings() {
			visit(binding, true)
		}
	}
	visit(rule, false)
}

func executableHTTPPattern(rule *annotations.HttpRule) (string, string) {
	switch pattern := rule.Pattern.(type) {
	case *annotations.HttpRule_Get:
		return "GET", pattern.Get
	case *annotations.HttpRule_Put:
		return "PUT", pattern.Put
	case *annotations.HttpRule_Post:
		return "POST", pattern.Post
	case *annotations.HttpRule_Delete:
		return "DELETE", pattern.Delete
	case *annotations.HttpRule_Patch:
		return "PATCH", pattern.Patch
	case *annotations.HttpRule_Custom:
		if pattern.Custom == nil {
			return "", ""
		}
		return strings.ToUpper(pattern.Custom.Kind), pattern.Custom.Path
	default:
		return "", ""
	}
}

func assertExecutableMethodSignatures(t *testing.T, method protoreflect.MethodDescriptor, options *descriptorpb.MethodOptions) {
	t.Helper()
	if !proto.HasExtension(options, annotations.E_MethodSignature) {
		return
	}
	signatures, ok := proto.GetExtension(options, annotations.E_MethodSignature).([]string)
	if !ok {
		t.Errorf("RPC %s has invalid google.api.method_signature option %T", method.FullName(), proto.GetExtension(options, annotations.E_MethodSignature))
		return
	}
	for _, signature := range signatures {
		if signature == "" {
			continue
		}
		for fieldPath := range strings.SplitSeq(signature, ",") {
			if !executableFieldPathExists(method.Input(), fieldPath) {
				t.Errorf("RPC %s method signature references missing request field %q", method.FullName(), fieldPath)
			}
		}
	}
}

func assertExecutableLROMetadata(t *testing.T, method protoreflect.MethodDescriptor, options *descriptorpb.MethodOptions) {
	t.Helper()
	isOperation := method.Output().FullName() == "google.longrunning.Operation"
	hasInfo := proto.HasExtension(options, longrunningpb.E_OperationInfo)
	if isOperation != hasInfo {
		t.Errorf("RPC %s operation output=%t but operation_info present=%t", method.FullName(), isOperation, hasInfo)
		return
	}
	if !hasInfo {
		return
	}
	info, ok := proto.GetExtension(options, longrunningpb.E_OperationInfo).(*longrunningpb.OperationInfo)
	if !ok || info == nil {
		t.Errorf("RPC %s has invalid operation_info option %T", method.FullName(), proto.GetExtension(options, longrunningpb.E_OperationInfo))
		return
	}
	for label, typeName := range map[string]string{"response_type": info.GetResponseType(), "metadata_type": info.GetMetadataType()} {
		if typeName == "" || !executableMessageTypeExists(method.ParentFile().Package(), typeName) {
			t.Errorf("RPC %s operation_info %s references missing message %q", method.FullName(), label, typeName)
		}
	}
}

func executableMessageTypeExists(packageName protoreflect.FullName, typeName string) bool {
	typeName = strings.TrimPrefix(typeName, ".")
	candidates := []protoreflect.FullName{protoreflect.FullName(typeName)}
	if !strings.Contains(typeName, ".") {
		candidates = append(candidates, packageName+"."+protoreflect.FullName(typeName))
	}
	for _, candidate := range candidates {
		if _, err := protoregistry.GlobalTypes.FindMessageByName(candidate); err == nil {
			return true
		}
	}
	return false
}

func assertExecutablePaginationShape(t *testing.T, method protoreflect.MethodDescriptor) {
	t.Helper()
	assertExecutableFieldKind(t, method, method.Input(), "page_size", protoreflect.Int32Kind)
	assertExecutableFieldKind(t, method, method.Input(), "page_token", protoreflect.StringKind)
	assertExecutableFieldKind(t, method, method.Output(), "next_page_token", protoreflect.StringKind)
}

func assertExecutableFieldKind(
	t *testing.T,
	method protoreflect.MethodDescriptor,
	message protoreflect.MessageDescriptor,
	fieldName protoreflect.Name,
	want protoreflect.Kind,
) {
	t.Helper()
	field := message.Fields().ByName(fieldName)
	if field == nil {
		t.Errorf("RPC %s message %s is missing %s", method.FullName(), message.FullName(), fieldName)
		return
	}
	if field.Kind() != want || field.Cardinality() == protoreflect.Repeated {
		t.Errorf("RPC %s field %s.%s has kind/cardinality %s/%s, want singular %s", method.FullName(), message.FullName(), fieldName, field.Kind(), field.Cardinality(), want)
	}
}

func executableFieldPathExists(message protoreflect.MessageDescriptor, path string) bool {
	if path == "" {
		return false
	}
	current := message
	parts := strings.Split(path, ".")
	for index, part := range parts {
		field := current.Fields().ByName(protoreflect.Name(part))
		if field == nil {
			return false
		}
		if index == len(parts)-1 {
			return true
		}
		if field.Message() == nil {
			return false
		}
		current = field.Message()
	}
	return false
}

func executableResourceTypes(t *testing.T) map[string]protoreflect.MessageDescriptor {
	t.Helper()
	resources := make(map[string]protoreflect.MessageDescriptor)
	forEachExecutableMessage(func(message protoreflect.MessageDescriptor) {
		options, ok := message.Options().(*descriptorpb.MessageOptions)
		if !ok || !proto.HasExtension(options, annotations.E_Resource) {
			return
		}
		descriptor, ok := proto.GetExtension(options, annotations.E_Resource).(*annotations.ResourceDescriptor)
		if !ok || descriptor == nil || descriptor.GetType() == "" {
			t.Errorf("message %s has an invalid google.api.resource option", message.FullName())
			return
		}
		if prior, duplicate := resources[descriptor.GetType()]; duplicate {
			t.Errorf("resource type %q is declared by both %s and %s", descriptor.GetType(), prior.FullName(), message.FullName())
			return
		}
		resources[descriptor.GetType()] = message
	})
	if len(resources) == 0 {
		t.Fatal("no exactmac resource types are registered")
	}
	return resources
}

func assertExecutableResourceReferences(t *testing.T, resources map[string]protoreflect.MessageDescriptor) {
	t.Helper()
	forEachExecutableMessage(func(message protoreflect.MessageDescriptor) {
		fields := message.Fields()
		for index := 0; index < fields.Len(); index++ {
			field := fields.Get(index)
			options, ok := field.Options().(*descriptorpb.FieldOptions)
			if !ok || !proto.HasExtension(options, annotations.E_ResourceReference) {
				continue
			}
			reference, ok := proto.GetExtension(options, annotations.E_ResourceReference).(*annotations.ResourceReference)
			if !ok || reference == nil {
				t.Errorf("field %s has an invalid google.api.resource_reference option", field.FullName())
				continue
			}
			if reference.GetType() != "" && reference.GetChildType() != "" {
				t.Errorf("field %s declares both resource type %q and child type %q", field.FullName(), reference.GetType(), reference.GetChildType())
				continue
			}
			typeName := reference.GetType()
			if typeName == "" {
				typeName = reference.GetChildType()
			}
			if typeName == "" {
				t.Errorf("field %s has an empty resource reference", field.FullName())
				continue
			}
			if typeName != "*" {
				if _, exists := resources[typeName]; !exists {
					t.Errorf("field %s references undeclared resource type %q", field.FullName(), typeName)
				}
			}
		}
	})
}

func forEachExecutableMessage(visit func(protoreflect.MessageDescriptor)) {
	protoregistry.GlobalFiles.RangeFiles(func(file protoreflect.FileDescriptor) bool {
		if !strings.HasPrefix(string(file.Package()), "exactmac.") {
			return true
		}
		var walk func(protoreflect.MessageDescriptors)
		walk = func(messages protoreflect.MessageDescriptors) {
			for index := 0; index < messages.Len(); index++ {
				message := messages.Get(index)
				visit(message)
				walk(message.Messages())
			}
		}
		walk(file.Messages())
		return true
	})
}

func TestExecutableContractInventoryMutationSensitivity(t *testing.T) {
	t.Run("MCP", func(t *testing.T) {
		live := keySet(executableToolContracts)
		mutated := cloneSet(live)
		delete(mutated, "screenshot")
		mutated["__sentinel_tool__"] = struct{}{}
		missing, unexpected := inventoryDelta(mutated, live)
		if !reflect.DeepEqual(missing, []string{"__sentinel_tool__"}) || !reflect.DeepEqual(unexpected, []string{"screenshot"}) {
			t.Fatalf("equal-cardinality MCP mutation escaped inventory comparison: missing=%v unexpected=%v", missing, unexpected)
		}
	})

	t.Run("gRPC", func(t *testing.T) {
		live := keySet(flattenRPCContracts(t))
		mutated := cloneSet(live)
		delete(mutated, "OpenApplication")
		mutated["SentinelRPC"] = struct{}{}
		missing, unexpected := inventoryDelta(mutated, live)
		if !reflect.DeepEqual(missing, []string{"SentinelRPC"}) || !reflect.DeepEqual(unexpected, []string{"OpenApplication"}) {
			t.Fatalf("equal-cardinality gRPC mutation escaped inventory comparison: missing=%v unexpected=%v", missing, unexpected)
		}
	})
}

func flattenRPCContracts(t *testing.T) map[string]rpcContract {
	t.Helper()
	contracts := make(map[string]rpcContract)
	for _, family := range rpcFamilyContracts {
		if family.provider == "" || family.effect == "" || family.proof == "" || len(family.methods) == 0 {
			t.Fatalf("incomplete RPC family contract: %+v", family)
		}
		for _, method := range family.methods {
			if _, exists := contracts[method]; exists {
				t.Fatalf("duplicate RPC contract for %q", method)
			}
			contracts[method] = rpcContract{provider: family.provider, effect: family.effect, proof: family.proof}
		}
	}
	return contracts
}

func descriptorMethodSet(t *testing.T) map[string]struct{} {
	t.Helper()
	service := pb.File_exactmac_v1_exact_mac_proto.Services().ByName("ExactMac")
	if service == nil {
		t.Fatal("live protobuf descriptor has no ExactMac service")
	}
	methods := service.Methods()
	result := make(map[string]struct{}, methods.Len())
	for index := 0; index < methods.Len(); index++ {
		name := string(methods.Get(index).Name())
		if _, exists := result[name]; exists {
			t.Fatalf("duplicate method %q in live protobuf descriptor", name)
		}
		result[name] = struct{}{}
	}
	return result
}

func assertGoClientMethod(t *testing.T, clientType reflect.Type, descriptor protoreflect.MethodDescriptor) {
	t.Helper()
	name := string(descriptor.Name())
	method, ok := clientType.MethodByName(name)
	if !ok {
		t.Errorf("generated Go ExactMacClient is missing %s", name)
		return
	}
	if !method.Type.IsVariadic() || method.Type.NumIn() != 3 || method.Type.NumOut() != 2 {
		t.Errorf("generated Go client method %s has unexpected signature %s", name, method.Type)
		return
	}
	contextType := reflect.TypeFor[context.Context]()
	if !method.Type.In(0).Implements(contextType) {
		t.Errorf("generated Go client method %s first parameter is %s, want context.Context", name, method.Type.In(0))
	}
	assertProtoType(t, name+" request", method.Type.In(1), descriptor.Input().FullName())
	if descriptor.IsStreamingServer() {
		if !strings.Contains(method.Type.Out(0).String(), string(descriptor.Output().Name())) {
			t.Errorf("generated Go streaming client method %s output %s does not reference %s", name, method.Type.Out(0), descriptor.Output().FullName())
		}
	} else {
		assertProtoType(t, name+" response", method.Type.Out(0), descriptor.Output().FullName())
	}
	errorType := reflect.TypeFor[error]()
	if !method.Type.Out(1).Implements(errorType) {
		t.Errorf("generated Go client method %s second result is %s, want error", name, method.Type.Out(1))
	}
}

func assertProtoType(t *testing.T, label string, valueType reflect.Type, expected protoreflect.FullName) {
	t.Helper()
	if valueType.Kind() != reflect.Pointer {
		t.Errorf("%s type = %s, want pointer protobuf message", label, valueType)
		return
	}
	message, ok := reflect.New(valueType.Elem()).Interface().(proto.Message)
	if !ok {
		t.Errorf("%s type = %s, want protobuf message", label, valueType)
		return
	}
	if got := message.ProtoReflect().Descriptor().FullName(); got != expected {
		t.Errorf("%s descriptor = %s, want %s", label, got, expected)
	}
}

func listedToolsFromRegistry(t *testing.T, tools map[string]*Tool) map[string]string {
	t.Helper()
	result := make(map[string]string, len(tools))
	for key, tool := range tools {
		if tool == nil {
			t.Fatalf("registry contains nil tool %q", key)
		}
		result[key] = canonicalTool(t, listedTool{Name: tool.Name, Description: tool.Description, InputSchema: tool.InputSchema})
	}
	return result
}

func listedToolsFromHTTP(t *testing.T, server *MCPServer) map[string]string {
	t.Helper()
	response, err := server.handleHTTPMessage(&transport.Message{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "tools/list"})
	if err != nil {
		t.Fatalf("HTTP tools/list failed: %v", err)
	}
	if response == nil || response.Error != nil {
		t.Fatalf("HTTP tools/list returned invalid response: %+v", response)
	}
	return parseToolList(t, response.Result)
}

func listedToolsFromStdio(t *testing.T, server *MCPServer) map[string]string {
	t.Helper()
	var output bytes.Buffer
	stdio := transport.NewStdioTransport(strings.NewReader(""), &output)
	server.handleMessage(stdio, &transport.Message{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "tools/list"})
	var response transport.Message
	if err := json.Unmarshal(bytes.TrimSpace(output.Bytes()), &response); err != nil {
		t.Fatalf("decode stdio tools/list response %q: %v", output.String(), err)
	}
	if response.Error != nil {
		t.Fatalf("stdio tools/list returned error: %+v", response.Error)
	}
	return parseToolList(t, response.Result)
}

func parseToolList(t *testing.T, raw json.RawMessage) map[string]string {
	t.Helper()
	var result toolListResult
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatalf("decode tools/list result: %v", err)
	}
	tools := make(map[string]string, len(result.Tools))
	for index, tool := range result.Tools {
		if tool.Name == "" {
			t.Fatal("tools/list exposed an empty tool name")
		}
		if index > 0 && result.Tools[index-1].Name >= tool.Name {
			t.Fatalf("tools/list is not strictly sorted: %q before %q", result.Tools[index-1].Name, tool.Name)
		}
		if _, duplicate := tools[tool.Name]; duplicate {
			t.Fatalf("tools/list exposed duplicate tool %q", tool.Name)
		}
		tools[tool.Name] = canonicalTool(t, tool)
	}
	return tools
}

func canonicalTool(t *testing.T, tool listedTool) string {
	t.Helper()
	encoded, err := json.Marshal(tool)
	if err != nil {
		t.Fatalf("encode tool %q: %v", tool.Name, err)
	}
	return string(encoded)
}

func assertToolSurfacesEqual(t *testing.T, label string, expected, actual map[string]string) {
	t.Helper()
	assertInventoryEqual(t, label, keySet(expected), keySet(actual))
	for name, expectedTool := range expected {
		if actualTool, ok := actual[name]; ok && actualTool != expectedTool {
			t.Errorf("%s metadata mismatch for %q\nexpected: %s\nactual:   %s", label, name, expectedTool, actualTool)
		}
	}
}

func assertInventoryEqual(t *testing.T, label string, expected, actual map[string]struct{}) {
	t.Helper()
	missing, unexpected := inventoryDelta(expected, actual)
	if len(missing) != 0 || len(unexpected) != 0 {
		t.Errorf("%s inventory mismatch: missing=%v unexpected=%v", label, missing, unexpected)
	}
}

func inventoryDelta(expected, actual map[string]struct{}) (missing, unexpected []string) {
	for name := range expected {
		if _, ok := actual[name]; !ok {
			missing = append(missing, name)
		}
	}
	for name := range actual {
		if _, ok := expected[name]; !ok {
			unexpected = append(unexpected, name)
		}
	}
	sort.Strings(missing)
	sort.Strings(unexpected)
	return missing, unexpected
}

func keySet[T any](values map[string]T) map[string]struct{} {
	result := make(map[string]struct{}, len(values))
	for name := range values {
		result[name] = struct{}{}
	}
	return result
}

func cloneSet(values map[string]struct{}) map[string]struct{} {
	return keySet(values)
}

func providerSet(contracts map[string]rpcContract) map[string]struct{} {
	providers := make(map[string]struct{})
	for _, contract := range contracts {
		providers[contract.provider] = struct{}{}
	}
	return providers
}

func handlerName(handler func(*ToolCall) (*ToolResult, error)) string {
	function := runtime.FuncForPC(reflect.ValueOf(handler).Pointer())
	if function == nil {
		return ""
	}
	name := strings.TrimSuffix(function.Name(), "-fm")
	if separator := strings.LastIndexByte(name, '.'); separator >= 0 {
		return name[separator+1:]
	}
	return name
}

func lowerCamel(name string) string {
	if name == "" {
		return ""
	}
	return strings.ToLower(name[:1]) + name[1:]
}

func swiftServiceProtocol(t *testing.T, source string) string {
	t.Helper()
	start := strings.Index(source, "public protocol ServiceProtocol:")
	if start < 0 {
		t.Fatal("generated Swift source has no ServiceProtocol declaration")
	}
	end := strings.Index(source[start:], "public protocol SimpleServiceProtocol:")
	if end < 0 {
		t.Fatal("generated Swift source has no SimpleServiceProtocol declaration after ServiceProtocol")
	}
	return source[start : start+end]
}

func repositoryRoot(t *testing.T) string {
	t.Helper()
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve executable contract test source path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(filename), "..", ".."))
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func (contract executableToolContract) String() string {
	return fmt.Sprintf("source=%s handler=%s effect=%s proof=%s", contract.source, contract.handler, contract.effect, contract.proof)
}
