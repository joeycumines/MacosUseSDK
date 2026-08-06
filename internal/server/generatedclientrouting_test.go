// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"errors"
	"net"
	"reflect"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

func TestGeneratedGoClientRoutesEveryNonApplicationMethod(t *testing.T) {
	service := pb.File_macosusesdk_v1_macos_use_proto.Services().ByName("MacosUse")
	if service == nil {
		t.Fatal("live protobuf descriptor has no MacosUse service")
	}
	contracts := flattenRPCContracts(t)
	recordedMethods := make(chan string, service.Methods().Len())
	listener := bufconn.Listen(1024 * 1024)
	grpcServer := grpc.NewServer(grpc.UnknownServiceHandler(func(_ any, stream grpc.ServerStream) error {
		method, ok := grpc.MethodFromServerStream(stream)
		if !ok {
			return status.Error(codes.Internal, "routing sentinel could not resolve method")
		}
		recordedMethods <- method
		return status.Error(codes.Unavailable, "routing sentinel")
	}))
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- grpcServer.Serve(listener)
	}()
	t.Cleanup(func() {
		grpcServer.Stop()
		if err := <-serveResult; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			t.Errorf("stop routing sentinel: %v", err)
		}
	})

	connection, err := grpc.NewClient(
		"passthrough:///func-004-w5-generated-routing",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return listener.DialContext(ctx)
		}),
	)
	if err != nil {
		t.Fatalf("create generated-client routing connection: %v", err)
	}
	t.Cleanup(func() {
		if err := connection.Close(); err != nil {
			t.Errorf("close generated-client routing connection: %v", err)
		}
	})

	client := reflect.ValueOf(pb.NewMacosUseClient(connection))
	applicationMethods := 0
	routedMethods := 0
	methods := service.Methods()
	for index := 0; index < methods.Len(); index++ {
		descriptor := methods.Get(index)
		name := string(descriptor.Name())
		contract, ok := contracts[name]
		if !ok {
			t.Errorf("live method %s has no executable contract", descriptor.FullName())
			continue
		}
		owner := behaviorCampaignForProvider(contract.provider)
		if owner == "FUNC-012" {
			applicationMethods++
			if contract.provider != "ApplicationMethods.swift" {
				t.Errorf("method %s is deferred to FUNC-012 by non-application provider %s", descriptor.FullName(), contract.provider)
			}
			continue
		}

		routedMethods++
		t.Run(name, func(t *testing.T) {
			if descriptor.IsStreamingClient() {
				t.Fatalf("generated-client routing harness does not classify client-streaming method %s", descriptor.FullName())
			}
			method := client.MethodByName(name)
			if !method.IsValid() {
				t.Fatalf("generated Go client has no %s method", name)
			}
			if method.Type().NumIn() != 3 || method.Type().NumOut() != 2 || !method.Type().IsVariadic() {
				t.Fatalf("generated Go client method %s has unexpected signature %s", name, method.Type())
			}
			if requestType := method.Type().In(1); requestType.Kind() != reflect.Pointer {
				t.Fatalf("generated Go client method %s request type = %s, want pointer", name, requestType)
			}
			errorType := reflect.TypeFor[error]()
			if !method.Type().Out(1).Implements(errorType) {
				t.Fatalf("generated Go client method %s error result = %s", name, method.Type().Out(1))
			}

			callContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			outputs := method.Call([]reflect.Value{
				reflect.ValueOf(callContext),
				reflect.New(method.Type().In(1).Elem()),
			})
			callErr := reflectedError(outputs[1])
			if descriptor.IsStreamingServer() && callErr == nil {
				if outputs[0].IsNil() {
					t.Fatalf("generated streaming client method %s returned nil stream without error", name)
				}
				receive := outputs[0].MethodByName("Recv")
				if !receive.IsValid() {
					t.Fatalf("generated streaming client method %s returned no Recv method", name)
				}
				receiveOutputs := receive.Call(nil)
				callErr = reflectedError(receiveOutputs[1])
			}
			expectedMethod := "/" + string(service.FullName()) + "/" + name
			select {
			case actualMethod := <-recordedMethods:
				if actualMethod != expectedMethod {
					t.Fatalf("generated client method %s routed to %q, want %q", name, actualMethod, expectedMethod)
				}
			case <-callContext.Done():
				t.Fatalf("generated client method %s did not reach routing sentinel: %v", name, callContext.Err())
			}
			sentinelStatus := status.Convert(callErr)
			if sentinelStatus.Code() != codes.Unavailable || sentinelStatus.Message() != "routing sentinel" {
				t.Fatalf(
					"generated client method %s error = %v (code %s message %q), want routing sentinel",
					name,
					callErr,
					sentinelStatus.Code(),
					sentinelStatus.Message(),
				)
			}
		})
	}

	if applicationMethods != 7 {
		t.Errorf("FUNC-012 application methods = %d, want 7", applicationMethods)
	}
	if routedMethods != methods.Len()-applicationMethods {
		t.Errorf("routed non-application methods = %d, want %d", routedMethods, methods.Len()-applicationMethods)
	}
	select {
	case unexpected := <-recordedMethods:
		t.Errorf("routing sentinel observed an extra method: %s", unexpected)
	default:
	}
}

func reflectedError(value reflect.Value) error {
	if !value.IsValid() || value.IsNil() {
		return nil
	}
	err, _ := value.Interface().(error)
	return err
}
