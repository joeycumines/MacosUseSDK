module github.com/joeycumines/MacosUseSDK

go 1.26.0

require (
	cloud.google.com/go/longrunning v1.0.0
	google.golang.org/genproto/googleapis/api v0.0.0-20260522162733-96412231522c
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260522162733-96412231522c
	google.golang.org/grpc v1.81.1
	google.golang.org/protobuf v1.36.11
)

require (
	github.com/BurntSushi/toml v1.6.0 // indirect
	github.com/KimMachineGun/automemlimit v0.7.5 // indirect
	github.com/dkorunic/betteralign v0.11.0 // indirect
	github.com/google/renameio/v2 v2.0.2 // indirect
	github.com/grailbio/base v0.0.11 // indirect
	github.com/grailbio/grit v0.0.0-20230416231552-d3b81e617b57 // indirect
	github.com/pbnjay/memory v0.0.0-20210728143218-7b4eea64cf58 // indirect
	github.com/sirkon/dst v0.26.4 // indirect
	go.uber.org/automaxprocs v1.6.0 // indirect
	golang.org/x/exp/typeparams v0.0.0-20260508232706-74f9aab9d74a // indirect
	golang.org/x/mod v0.36.0 // indirect
	golang.org/x/net v0.55.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/sys v0.45.0 // indirect
	golang.org/x/text v0.37.0 // indirect
	golang.org/x/tools v0.45.0 // indirect
	honnef.co/go/tools v0.7.0 // indirect
)

tool (
	github.com/dkorunic/betteralign/cmd/betteralign
	github.com/grailbio/grit
	honnef.co/go/tools/cmd/staticcheck
)
