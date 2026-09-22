module github.com/joeycumines/ExactMac

go 1.26.3

require (
	cloud.google.com/go/longrunning v1.2.0
	github.com/rivo/uniseg v0.4.7
	golang.org/x/image v0.44.0
	golang.org/x/sys v0.47.0
	golang.org/x/tools v0.48.0
	google.golang.org/genproto/googleapis/api v0.0.0-20260803160001-6ac0973c030d
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260803160001-6ac0973c030d
	google.golang.org/grpc v1.83.0
	google.golang.org/protobuf v1.36.11
)

require (
	github.com/BurntSushi/toml v1.6.0 // indirect
	github.com/KimMachineGun/automemlimit v0.7.5 // indirect
	github.com/dkorunic/betteralign v0.14.3 // indirect
	github.com/google/renameio/v2 v2.0.2 // indirect
	github.com/grailbio/base v0.0.11 // indirect
	github.com/grailbio/grit v0.0.0-20230416231552-d3b81e617b57 // indirect
	github.com/pbnjay/memory v0.0.0-20210728143218-7b4eea64cf58 // indirect
	golang.org/x/exp/typeparams v0.0.0-20260727155853-b88d891fe743 // indirect
	golang.org/x/mod v0.38.0 // indirect
	golang.org/x/net v0.57.0 // indirect
	golang.org/x/sync v0.22.0 // indirect
	golang.org/x/text v0.40.0 // indirect
	honnef.co/go/tools v0.7.0 // indirect
)

tool (
	github.com/dkorunic/betteralign/cmd/betteralign
	github.com/grailbio/grit
	honnef.co/go/tools/cmd/staticcheck
)
