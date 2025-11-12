module github.com/joeycumines/MacosUseSDK/integration_test

go 1.25.4

replace github.com/joeycumines/MacosUseSDK => ../

require (
	cloud.google.com/go/longrunning v0.7.0
	github.com/joeycumines/MacosUseSDK v0.0.0-20251027002716-8da1ef8cb816
	google.golang.org/grpc v1.76.0
)

require (
	golang.org/x/net v0.47.0 // indirect
	golang.org/x/sys v0.38.0 // indirect
	golang.org/x/text v0.31.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20251111163417-95abcf5c77ba // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20251111163417-95abcf5c77ba // indirect
	google.golang.org/protobuf v1.36.10 // indirect
)
