module github.com/joeycumines/MacosUseSDK/examples/go-client

go 1.23

require (
	github.com/joeycumines/MacosUseSDK v0.0.0
	google.golang.org/grpc v1.68.1
	google.golang.org/protobuf v1.36.1
)

// Use local generated stubs during development
replace github.com/joeycumines/MacosUseSDK => ../../
