module github.com/joeycumines/MacosUseSDK/integration

go 1.25.4

replace github.com/joeycumines/MacosUseSDK => ../

require (
	cloud.google.com/go/longrunning v0.8.0
	github.com/joeycumines/MacosUseSDK v0.0.0-20251207071216-f5477f73fb25
	google.golang.org/grpc v1.81.0
)

require (
	golang.org/x/net v0.51.0 // indirect
	golang.org/x/sys v0.42.0 // indirect
	golang.org/x/text v0.34.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260226221140-a57be14db171 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260226221140-a57be14db171 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
