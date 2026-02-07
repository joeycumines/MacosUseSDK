module github.com/joeycumines/MacosUseSDK/integration

go 1.25.4

replace github.com/joeycumines/MacosUseSDK => ../

require (
	cloud.google.com/go/longrunning v0.8.0
	github.com/joeycumines/MacosUseSDK v0.0.0-20251207071216-f5477f73fb25
	google.golang.org/grpc v1.78.0
)

require (
	golang.org/x/net v0.49.0 // indirect
	golang.org/x/sys v0.40.0 // indirect
	golang.org/x/text v0.33.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260203192932-546029d2fa20 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260203192932-546029d2fa20 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
