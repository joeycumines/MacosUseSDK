module github.com/joeycumines/MacosUseSDK/integration

go 1.26.3

replace github.com/joeycumines/MacosUseSDK => ../

require (
	cloud.google.com/go/longrunning v1.2.0
	github.com/joeycumines/MacosUseSDK v0.0.0-20260725215237-e90e731995ba
	github.com/rivo/uniseg v0.4.7
	google.golang.org/grpc v1.83.2
	google.golang.org/protobuf v1.36.11
)

require (
	golang.org/x/net v0.58.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.41.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260803160001-6ac0973c030d // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260803160001-6ac0973c030d // indirect
)
