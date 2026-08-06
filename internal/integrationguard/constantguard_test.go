package integrationguard

import (
	"go/ast"
	"go/constant"
	"go/importer"
	"go/token"
	"go/types"
	"sort"
)

type constantResolver struct {
	strings map[ast.Expr]string
}

func newConstantResolver(parsed map[string]parsedSource) constantResolver {
	filenames := make([]string, 0, len(parsed))
	for filename := range parsed {
		filenames = append(filenames, filename)
	}
	sort.Strings(filenames)

	files := make([]*ast.File, 0, len(filenames))
	var fileSet *token.FileSet
	for _, filename := range filenames {
		source := parsed[filename]
		if fileSet == nil {
			fileSet = source.fileSet
		}
		files = append(files, source.file)
	}
	info := &types.Info{Types: make(map[ast.Expr]types.TypeAndValue)}
	configuration := types.Config{
		GoVersion: "go1.26",
		Importer:  importer.Default(),
		Error:     func(error) {},
	}
	_, _ = configuration.Check("integrationguard.invalid-fixture", fileSet, files, info)
	return constantResolverFromTypesInfo(info)
}

func constantResolverFromTypesInfo(info *types.Info) constantResolver {
	resolver := constantResolver{strings: make(map[ast.Expr]string)}
	for expression, typeAndValue := range info.Types {
		if typeAndValue.Value == nil || typeAndValue.Value.Kind() != constant.String {
			continue
		}
		resolver.strings[expression] = constant.StringVal(typeAndValue.Value)
	}
	return resolver
}

func constantStringValue(expression ast.Expr, resolver constantResolver) (string, bool) {
	value, ok := resolver.strings[expression]
	return value, ok
}
