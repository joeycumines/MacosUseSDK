module github.com/joeycumines/MacosUseSDK

go 1.25.4

require (
	cloud.google.com/go/longrunning v0.8.0
	google.golang.org/genproto/googleapis/api v0.0.0-20260203192932-546029d2fa20
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260203192932-546029d2fa20
	google.golang.org/grpc v1.79.1
	google.golang.org/protobuf v1.36.11
)

require (
	github.com/BurntSushi/toml v1.6.0 // indirect
	github.com/KimMachineGun/automemlimit v0.7.5 // indirect
	github.com/dkorunic/betteralign v0.8.3 // indirect
	github.com/google/renameio/v2 v2.0.2 // indirect
	github.com/grailbio/base v0.0.11 // indirect
	github.com/grailbio/grit v0.0.0-20230416231552-d3b81e617b57 // indirect
	github.com/pbnjay/memory v0.0.0-20210728143218-7b4eea64cf58 // indirect
	github.com/sirkon/dst v0.26.4 // indirect
	github.com/yuin/goldmark v1.7.16 // indirect
	go.uber.org/automaxprocs v1.6.0 // indirect
	golang.org/x/exp/typeparams v0.0.0-20260112195511-716be5621a96 // indirect
	golang.org/x/mod v0.32.0 // indirect
	golang.org/x/net v0.49.0 // indirect
	golang.org/x/sync v0.19.0 // indirect
	golang.org/x/sys v0.40.0 // indirect
	golang.org/x/text v0.33.0 // indirect
	golang.org/x/tools v0.41.0 // indirect
	golang.org/x/tools/cmd/godoc v0.1.0-deprecated // indirect
	golang.org/x/tools/go/expect v0.1.1-deprecated // indirect
	golang.org/x/tools/godoc v0.1.0-deprecated // indirect
	honnef.co/go/tools v0.6.1 // indirect
)

tool (
	github.com/dkorunic/betteralign/cmd/betteralign
	github.com/grailbio/grit
	golang.org/x/tools/cmd/godoc
	honnef.co/go/tools/cmd/staticcheck
)
