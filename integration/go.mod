module github.com/joeycumines/MacosUseSDK/integration

go 1.26.3

replace github.com/joeycumines/MacosUseSDK => ../

require (
	cloud.google.com/go/longrunning v1.1.0
	github.com/joeycumines/MacosUseSDK v0.0.0-20260522170526-8bd167fa7a3e
	google.golang.org/grpc v1.81.1
)

require (
	golang.org/x/net v0.56.0 // indirect
	golang.org/x/sys v0.46.0 // indirect
	golang.org/x/text v0.38.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260615183401-62b3387ff324 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260615183401-62b3387ff324 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
