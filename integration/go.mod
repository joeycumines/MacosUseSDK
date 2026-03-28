module github.com/joeycumines/MacosUseSDK/integration

go 1.26.0

replace github.com/joeycumines/MacosUseSDK => ../

require (
	cloud.google.com/go/longrunning v0.8.0
	github.com/joeycumines/MacosUseSDK v0.0.0-20260207213640-a73a7a9440c4
	google.golang.org/grpc v1.79.1
)

require (
	golang.org/x/net v0.51.0 // indirect
	golang.org/x/sys v0.41.0 // indirect
	golang.org/x/text v0.34.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260226221140-a57be14db171 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260226221140-a57be14db171 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
