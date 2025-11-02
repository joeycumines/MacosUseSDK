# Buf CLI Documentation

## Condensed

### Global
- Usage: buf [flags] [command]
- Global flags:
  - --debug
  - --help, -h
  - --help-tree
  - --log-format string (text,color,json) — default "color"
  - --timeout duration (default 2m0s)
  - --version

Error/format flags (used across commands): --error-format string (text,json,msvs,junit,github-actions,gitlab-code-quality,config-ignore-yaml where applicable)

---

### Top-level commands
- beta — unstable subcommands
- breaking — verify no breaking changes
- build — build Protobuf into a Buf image or file descriptor set
- completion — generate shell completion
- config — work with buf.yaml
- convert — convert message binary/text/JSON/yaml
- curl — invoke RPC method (like curl)
- dep — dependencies (graph/prune/update)
- export — export .proto files from an input
- format — format Protobuf files
- generate — generate code with protoc plugins (detailed below)
- help — help about commands
- lint — lint Protobuf files
- ls-files — list Protobuf files
- lsp — language server (serve)
- plugin — check-plugin management (prune/update)
- stats — get statistics for a source/module

(Commands related to registries, pushing to remote registries, login/logout, organization/module/plugin management, SDK resolution, and pricing were removed.)

---

### beta (subset of subcommands)
- Usage: buf beta [flags] [command]
- Kept commands:
  - buf-plugin-v1, buf-plugin-v1beta1, buf-plugin-v2 — run buf as a check plugin
    - Flags: --format string (default "binary"), --protocol, --spec
  - studio-agent — run an HTTP(S) server as the Studio agent
    - Key flags:
      - --bind string (default "127.0.0.1")
      - --port string (default "8080")
      - --origin string (default "https://buf.build")
      - --private-network
      - TLS: --ca-cert, --server-cert, --server-key, --client-cert, --client-key
      - --disallowed-header strings, --forward-header key=val pairs

---

### breaking
- Purpose: ensure input has no breaking changes versus --against input
- Usage: buf breaking <input> --against <against-input> [flags]
- Input formats: binpb, dir, git, json, mod, protofile, tar, txtpb, yaml, zip
- Key flags:
  - --against string (required unless --against-registry set — registry options were removed)
  - --config string
  - --disable-symlinks
  - --error-format string
  - --exclude-imports
  - --exclude-path strings (multiple allowed)
  - --limit-to-input-files
  - --path strings (limit)
  - --help, -h

---

### build
- Purpose: build Protobuf files into a Buf image (or FileDescriptorSet)
- Usage: buf build <input> [flags]
- Input formats: dir, git, json, mod, protofile, tar, zip
- Key flags:
  - --as-file-descriptor-set
  - --config string
  - --disable-symlinks
  - --error-format string
  - --exclude-path strings
  - --output string (defaults stdout)
  - --path strings
  - --help, -h

---

### completion
- Usage: buf completion <shell> [flags]
- Shells: bash, fish, powershell, zsh
- Flags: --no-descriptions, -h

---

### config
Subcommands: init, ls-breaking-rules, ls-lint-rules, ls-modules, migrate
- buf config init
  - Usage: buf config init [flags]
  - Flags: --doc
- buf config ls-breaking-rules
  - Usage: buf config ls-breaking-rules [flags]
  - Flags: --config, --version (default v1)
- buf config ls-lint-rules
  - Usage: buf config ls-lint-rules [flags]
  - Flags: --config, --version (default v1)
- buf config ls-modules
  - Usage: buf config ls-modules [flags]
  - Flags: --config
- buf config migrate
  - Usage: buf config migrate [flags]
  - Flags: --config

(All subcommands accept global flags.)

---

### convert
- Purpose: convert message between binpb, json, txtpb, yaml
- Usage: buf convert <input> [flags]
- Key flags:
  - --from string (binpb,json,txtpb,yaml) — default "json"
  - --to string (binpb,json,txtpb,yaml) — default "json"
  - --type string (fully qualified message type)
  - --config string
  - --disable-symlinks
  - --error-format string
  - --exclude-path strings
  - --path strings

---

### curl
- Purpose: invoke an RPC method
- Usage: buf curl <method> [flags]
- Key flags (summary):
  - Networking/TLS: --cacert, --cert, --key, --insecure, --unix-socket
  - Timeouts: --connect-timeout, --max-time
  - Request: --data (binary file), --data-format (binpb,json,txtpb,yaml), --get, --header strings
  - Protocols: --protocol (grpc,grpc-web,connect) — default "grpc"
  - Reflection: --reflect (use server reflection), --reflect-header strings, --reflect-timeout
  - Schema/Server: --schema string (module for schema; required if method not fully-qualified), --server string
  - Output: --output string, --emit-defaults, --verbosity (none,verbose)
  - TLS versions: --tls-min-version, --tls-max-version (1.0..1.3)
  - --user-agent

---

### dep
- Subcommands: graph, prune, update
- Usage: buf dep [command] [flags]
- buf dep graph <directory> — prints dependency graph; flags: --config
- buf dep prune <directory> — prune unused dependencies; flags: --config
- buf dep update <directory> — update dependencies; flags: --config

---

### export
- Purpose: export .proto files from an input
- Usage: buf export <input> [flags]
- Key flags:
  - --all (include imports)
  - --config string
  - --disable-symlinks
  - --error-format string
  - --exclude-path strings
  - --output string (default ".")
  - --path strings

---

### format
- Purpose: format Protobuf files
- Usage: buf format <input> [flags]
- Key flags:
  - --config string
  - --diff (display diffs instead of rewriting)
  - --disable-symlinks
  - --error-format string
  - --exclude-path strings
  - --exit-code (non-zero if files not formatted)
  - --path strings
  - --write (apply changes to files)

---

### generate (condensed complete spec)
- Purpose: generate code using generation template (buf.gen.yaml or provided template)
- Usage: buf generate <input> [flags]
- Template core shape (minimal):
  - version: v1beta1 | v1 | v2 (required)
  - clean: true|false (optional) — delete outputs before running
  - plugins: list of plugin entries. Each plugin entry may be:
    - remote: "<remote/owner/plugin[:version]>" (remote plugin; uses "all" or remote-specific invocation)
      - out: relative output dir
      - revision: integer (optional)
      - opt: string or list of strings (options)
      - include_imports: bool
      - include_wkt: bool
      - types / exclude_types: lists (optional)
      - strategy: "directory" | "all" (default "directory")
    - local: name or path (string or list for full invocation)
      - out, opt, include_imports, include_wkt, types, exclude_types, strategy
    - protoc_builtin: plugin name (e.g., java)
      - out, protoc_path (optional)
  - managed: (optional)
    - enabled: true|false
    - override: list of override rules:
      - file_option: <option-name> and value (file options list: java_package, go_package, optimize_for, csharp_namespace, etc.)
      - field_option: <field-option> and value (e.g., jstype)
      - module/path can narrow scope; last matching rule wins
    - disable: list of conditions to disable managed mode (module, path, or file_option)
  - inputs: optional list — directory, git_repo (url, branch, subdir, depth), module (module ref with types, exclude_types, paths, exclude_paths), tarball/zip_archive (strip_components, compression), proto_file (include_package_files), binary_image/json_image/text_image/yaml_image (compression)
- Notes:
  - Default behavior: buf generate reads `buf.gen.yaml` in current dir and uses current directory as input
  - --template accepts a file or inline YAML/JSON data
  - Plugins invoked per-template order; invocation is per-directory in parallel (strategy "directory") unless "all"
  - Insertion points: processed in template order
- Important flags:
  - --clean
  - --config string
  - --disable-symlinks
  - --error-format string
  - --exclude-path strings
  - --exclude-type strings (package,message,enum,extension,service,method)
  - --include-imports (also required for --include-wkt)
  - --include-wkt
  - -o, --output string (base directory prepended to plugin outs)
  - --path strings
  - --template string (file or inline YAML/JSON)
  - --type strings (types to include)
  - --help, -h

Examples (concise):
- Default: uses buf.gen.yaml and current dir:
  - buf generate
- Inline template:
  - buf generate --template '{"version":"v2","plugins":[{"local":"protoc-gen-go","out":"gen/go"}]}'
- Generate to directory with template:
  - buf generate --template bar.yaml -o bar https://github.com/foo/bar.git

---

### help
- Usage: buf help [command] [flags]

---

### lint
- Purpose: run lint rules on Protobuf
- Usage: buf lint <input> [flags]
- Key flags:
  - --config string
  - --disable-symlinks
  - --error-format string (adds config-ignore-yaml option)
  - --exclude-path strings
  - --path strings

---

### ls-files
- Purpose: list .proto files from an input
- Usage: buf ls-files <input> [flags]
- Key flags:
  - --config string
  - --disable-symlinks
  - --exclude-path strings
  - --format string (text,json,import) — default "text"
  - --include-importable (include all importable files)
  - --include-imports
  - --path strings

---

### lsp
- Purpose: Buf Language Server
- Subcommand:
  - serve — start language server
    - Usage: buf lsp serve [flags]
    - Flags: --pipe string (path to UNIX socket; uses stdio if unset)

---

### plugin (check plugins, local management)
- Purpose: manage check plugins configured in `buf.yaml` / `buf.lock`
- Kept subcommands:
  - prune <directory> — remove unused plugins from buf.lock
  - update <directory> — update pinned remote plugin digests in buf.lock
- Removed: any push-to-registry plugin operations
- Flags: -h, --help

---

### stats
- Purpose: get statistics for a source/module
- Usage: buf stats <source> [flags]
- Input formats: dir, git, mod, protofile, tar, zip
- Key flags:
  - --disable-symlinks
  - --format string (text,json) — default "text"

---

### Examples / common usage patterns
- Build module/image: buf build .
- Format files in-place: buf format --write .
- Lint: buf lint .
- Generate with template file: buf generate --template buf.gen.yaml .
- Convert JSON message to binary: buf convert --from json --to binpb --type foo.v1.Msg
- Call RPC (with reflection): buf curl --reflect //package.Service/Method --server localhost:50051
- Show dependency graph: buf dep graph .
- List proto files including imports: buf ls-files . --include-imports

## Main Help

```
buf help
The Buf CLI

A tool for working with Protocol Buffers and managing resources on the Buf Schema Registry (BSR)

Usage:
  buf [flags]
  buf [command]

Available Commands:
  beta        Beta commands. Unstable and likely to change
  breaking    Verify no breaking changes have been made
  build       Build Protobuf files into a Buf image
  completion  Generate auto-completion scripts for commonly used shells
  config      Work with configuration files
  convert     Convert a message between binary, text, or JSON
  curl        Invoke an RPC endpoint, a la 'cURL'
  dep         Work with dependencies
  export      Export proto files from one location to another
  format      Format Protobuf files
  generate    Generate code with protoc plugins
  help        Help about any command
  lint        Run linting on Protobuf files
  ls-files    List Protobuf files
  lsp         Work with Buf Language Server
  plugin      Work with check plugins
  push        Push to a registry
  registry    Manage assets on the Buf Schema Registry
  stats       Get statistics for a given source or module

Flags:
      --debug               Turn on debug logging
  -h, --help                help for buf
      --help-tree           Print the entire sub-command tree
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
      --version             Print the version

Use "buf [command] --help" for more information about a command.
```

## beta

```
buf beta --help
Beta commands. Unstable and likely to change

Usage:
  buf beta [flags]
  buf beta [command]

Available Commands:
  buf-plugin-v1      Run buf as a check plugin.
  buf-plugin-v1beta1 Run buf as a check plugin.
  buf-plugin-v2      Run buf as a check plugin.
  price              Get the price for BSR paid plans for a given source or module
  registry           Manage assets on the Buf Schema Registry
  studio-agent       Run an HTTP(S) server as the Studio agent

Flags:
  -h, --help        help for beta
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf beta [command] --help" for more information about a command.
```

### buf-plugin-v1

```
buf beta buf-plugin-v1 --help
Run buf as a check plugin.

Usage:
  buf beta buf-plugin-v1 [flags]

Flags:
      --format string   Passed through to plugin. (default "binary")
  -h, --help            help for buf-plugin-v1
      --protocol        Passed through to plugin.
      --spec            Passed through to plugin.

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### buf-plugin-v1beta1

```
buf beta buf-plugin-v1beta1 --help
Run buf as a check plugin.

Usage:
  buf beta buf-plugin-v1beta1 [flags]

Flags:
      --format string   Passed through to plugin. (default "binary")
  -h, --help            help for buf-plugin-v1beta1
      --protocol        Passed through to plugin.
      --spec            Passed through to plugin.

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### buf-plugin-v2

```
buf beta buf-plugin-v2 --help
Run buf as a check plugin.

Usage:
  buf beta buf-plugin-v2 [flags]

Flags:
      --format string   Passed through to plugin. (default "binary")
  -h, --help            help for buf-plugin-v2
      --protocol        Passed through to plugin.
      --spec            Passed through to plugin.

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### price

```
buf beta price --help
Get the price for BSR paid plans for a given source or module

The first argument is the source or module to get a price for, which must be one of format [dir,git,mod,protofile,tar,zip].
This defaults to "." if no argument is specified.

Usage:
  buf beta price <source> [flags]

Flags:
      --disable-symlinks   Do not follow symlinks when reading sources or configuration from the local filesystem
                           By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
  -h, --help               help for price

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### registry

```
buf beta registry --help
Manage assets on the Buf Schema Registry

Usage:
  buf beta registry [flags]
  buf beta registry [command]

Available Commands:
  plugin      Manage plugins on the Buf Schema Registry
  webhook     Manage webhooks for a repository on the Buf Schema Registry

Flags:
  -h, --help        help for registry
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf beta registry [command] --help" for more information about a command.
```

#### plugin

```
buf beta registry plugin --help
Manage plugins on the Buf Schema Registry

Usage:
  buf beta registry plugin [flags]
  buf beta registry plugin [command]

Available Commands:
  delete          Delete a plugin from the registry
  push            Push a plugin to a registry

Flags:
  -h, --help        help for plugin
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf beta registry plugin [command] --help" for more information about a command.
```

##### delete

```
buf beta registry plugin delete --help
Delete a plugin from the registry

Usage:
  buf beta registry plugin delete <buf.build/owner/plugin[:version]> [flags]

Flags:
  -h, --help   help for delete

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### push

```
buf beta registry plugin push --help
Push a plugin to a registry

The first argument is the source to push (directory containing buf.plugin.yaml or plugin release zip), which must be a directory.
This defaults to "." if no argument is specified.

Usage:
  buf beta registry plugin push <source> [flags]

Flags:
      --disable-symlinks         Do not follow symlinks when reading sources or configuration from the local filesystem
                                 By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --format string            The output format to use. Must be one of [text,json] (default "text")
  -h, --help                     help for push
      --image string             Existing image to push
      --override-remote string   Override the default remote found in buf.plugin.yaml name and dependencies
      --visibility string        The plugin's visibility setting. Must be one of [public,private]

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### webhook

```
buf beta registry webhook --help
Manage webhooks for a repository on the Buf Schema Registry

Usage:
  buf beta registry webhook [flags]
  buf beta registry webhook [command]

Available Commands:
  create      Create a repository webhook
  delete      Delete a repository webhook
  list        List repository webhooks

Flags:
  -h, --help        help for webhook
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf beta registry webhook [command] --help" for more information about a command.
```

##### create

```
buf beta registry webhook create --help
Create a repository webhook

Usage:
  buf beta registry webhook create [flags]

Flags:
      --callback-url string   The url for the webhook to callback to on a given event
      --event string          The event type to create a webhook for. The proto enum string value is used for this input (e.g. 'WEBHOOK_EVENT_REPOSITORY_PUSH')
  -h, --help                  help for create
      --owner string          The owner name of the repository to create a webhook for
      --remote string         The remote of the repository the created webhook will belong to
      --repository string     The repository name to create a webhook for

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### delete

```
buf beta registry webhook delete --help
Delete a repository webhook

Usage:
  buf beta registry webhook delete [flags]

Flags:
  -h, --help            help for delete
      --id string       The webhook ID to delete
      --remote string   The remote of the repository the webhook ID belongs to

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### list

```
buf beta registry webhook list --help
List repository webhooks

Usage:
  buf beta registry webhook list [flags]

Flags:
  -h, --help                help for list
      --owner string        The owner name of the repository to list webhooks for
      --remote string       The remote of the owner and repository to list webhooks for
      --repository string   The repository name to list webhooks for.

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### studio-agent

```
buf beta studio-agent --help
Run an HTTP(S) server as the Studio agent

Usage:
  buf beta studio-agent [flags]

Flags:
      --bind string                     The address to be exposed to accept HTTP requests (default "127.0.0.1")
      --ca-cert string                  The CA cert to be used in the client and server TLS configuration
      --client-cert string              The cert to be used in the client TLS configuration
      --client-key string               The key to be used in the client TLS configuration
      --disallowed-header strings       The header names that are disallowed by this agent. When the agent receives an enveloped request with these headers set, it will return an error rather than forward the request to the target server. Multiple headers are appended if specified multiple times
      --forward-header stringToString   The headers to be forwarded via the agent to the target server. Must be an equals sign separated key-value pair (like --forward-header=fromHeader1=toHeader1). Multiple header pairs are appended if specified multiple times (default [])
  -h, --help                            help for studio-agent
      --origin string                   The allowed origin for CORS options (default "https://buf.build")
      --port string                     The port to be exposed to accept HTTP requests (default "8080")
      --private-network                 Use the agent with private network CORS
      --server-cert string              The cert to be used in the server TLS configuration
      --server-key string               The key to be used in the server TLS configuration

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## breaking

Verify no breaking changes have been made

This command makes sure that the <input> location has no breaking changes compared to the <against-input> location.

The first argument is the source, module, or image to check for breaking changes, which must be one of format [binpb,dir,git,json,mod,protofile,tar,txtpb,yaml,zip].
This defaults to "." if no argument is specified.

Usage:
  buf breaking <input> --against <against-input> [flags]

Flags:
      --against string          Required, except if --against-registry is set. The source, module, or image to check against. Must be one of format [binpb,dir,git,json,mod,protofile,tar,txtpb,yaml,zip]
      --against-config string   The buf.yaml file or data to use to configure the against source, module, or image
      --against-registry        Run breaking checks against the latest commit on the default branch in the registry. All modules in the input must have a name configured, otherwise this will fail.
                                If a remote module is not found with the configured name, then this will fail. This cannot be set with --against.
      --config string           The buf.yaml file or data to use for configuration
      --disable-symlinks        Do not follow symlinks when reading sources or configuration from the local filesystem
                                By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --error-format string     The format for build errors or check violations printed to stdout. Must be one of [text,json,msvs,junit,github-actions,gitlab-code-quality] (default "text")
      --exclude-imports         Exclude imports from breaking change detection.
      --exclude-path strings    Exclude specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                                If specified multiple times, the union is taken
  -h, --help                    help for breaking
      --limit-to-input-files    Only run breaking checks against the files in the input
                                When set, the against input contains only the files in the input
                                Overrides --path
      --path strings            Limit to specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                                If specified multiple times, the union is taken

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)




## build

```
buf build --help
Build Protobuf files into a Buf image

The first argument is the source, module, or image to build, which must be one of format [dir,git,json,mod,protofile,tar,zip].
This defaults to "." if no argument is specified.

Usage:
  buf build <input> [flags]

Flags:
      --as-file-descriptor-set   Output as a google.protobuf.FileDescriptorSet instead of a Buf image
      --config string           The buf.yaml file or data to use for configuration
      --disable-symlinks        Do not follow symlinks when reading sources or configuration from the local filesystem
                                By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --error-format string     The format for build errors or check violations printed to stdout. Must be one of [text,json,msvs,junit,github-actions,gitlab-code-quality] (default "text")
      --exclude-path strings    Exclude specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                                If specified multiple times, the union is taken
  -h, --help                    help for build
      --output string           The output location for the built image. Defaults to stdout if not specified
      --path strings            Limit to specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                                If specified multiple times, the union is taken

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## completion

### bash

```
buf completion bash --help
Generate the autocompletion script for bash

Usage:
  buf completion bash [flags]

Flags:
  -h, --help              help for bash
      --no-descriptions   disable completion descriptions

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### fish

```
buf completion fish --help
Generate the autocompletion script for fish

Usage:
  buf completion fish [flags]

Flags:
  -h, --help              help for fish
      --no-descriptions   disable completion descriptions

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### powershell

```
buf completion powershell --help
Generate the autocompletion script for powershell

Usage:
  buf completion powershell [flags]

Flags:
  -h, --help              help for powershell
      --no-descriptions   disable completion descriptions

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### zsh

```
buf completion zsh --help
Generate the autocompletion script for zsh

Usage:
  buf completion zsh [flags]

Flags:
  -h, --help              help for zsh
      --no-descriptions   disable completion descriptions

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## config

### init

```
buf config init --help
Initializes a buf.yaml configuration file in the current directory

Usage:
  buf config init [flags]

Flags:
      --doc         Include documentation in the generated buf.yaml
  -h, --help        help for init

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### ls-breaking-rules

```
buf config ls-breaking-rules --help
List all breaking rules

Usage:
  buf config ls-breaking-rules [flags]

Flags:
      --config string   The buf.yaml file or data to use for configuration
  -h, --help            help for ls-breaking-rules
      --version string  The version of rules to list (default "v1")

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### ls-lint-rules

```
buf config ls-lint-rules --help
List all lint rules

Usage:
  buf config ls-lint-rules [flags]

Flags:
      --config string   The buf.yaml file or data to use for configuration
  -h, --help            help for ls-lint-rules
      --version string  The version of rules to list (default "v1")

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### ls-modules

```
buf config ls-modules --help
List all modules in the configuration

Usage:
  buf config ls-modules [flags]

Flags:
      --config string   The buf.yaml file or data to use for configuration
  -h, --help            help for ls-modules

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### migrate

```
buf config migrate --help
Migrate a buf.yaml configuration file to the latest version

Usage:
  buf config migrate [flags]

Flags:
      --config string   The buf.yaml file or data to use for configuration
  -h, --help            help for migrate

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## convert

```
buf convert --help
Convert a message between binary, text, or JSON

The first argument is the source, module, or image to convert, which must be one of format [binpb,dir,git,json,mod,protofile,tar,txtpb,yaml,zip].
This defaults to "." if no argument is specified.

Usage:
  buf convert <input> [flags]

Flags:
      --config string           The buf.yaml file or data to use for configuration
      --disable-symlinks        Do not follow symlinks when reading sources or configuration from the local filesystem
                                By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --error-format string     The format for build errors or check violations printed to stdout. Must be one of [text,json,msvs,junit,github-actions,gitlab-code-quality] (default "text")
      --exclude-path strings    Exclude specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                                If specified multiple times, the union is taken
  -h, --help                    help for convert
      --from string             The input format. Must be one of [binpb,json,txtpb,yaml] (default "json")
      --path strings            Limit to specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                                If specified multiple times, the union is taken
      --to string               The output format. Must be one of [binpb,json,txtpb,yaml] (default "json")
      --type string             The fully qualified name of the message type to convert

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## curl

```
buf curl --help
Invoke an RPC endpoint, a la 'cURL'

The first argument is the RPC method to invoke.

Usage:
  buf curl <method> [flags]

Flags:
      --cacert string                 The CA certificate file to use for server verification
      --cert string                   The client certificate file to use for client authentication
      --connect-timeout duration      The maximum time allowed for a connection to be established (default 10s)
      --data string                   The request data file in binary format
      --data-format string            The format of the request data. Must be one of [binpb,json,txtpb,yaml] (default "json")
      --emit-defaults                 Emit default values for JSON output
      --get                           Use GET instead of POST
      --header strings                Additional request headers, e.g. "Authorization: Bearer <token>"
      --http2-prior-knowledge         Use HTTP/2 without TLS
      --insecure                      Skip server certificate and domain verification
      --keepalive-time duration       The keepalive time period (default 30s)
      --key string                    The client key file to use for client authentication
      --max-time duration             The maximum time allowed for the entire request (default 2m0s)
      --output string                 The output file for the response
      --protocol string               The protocol to use. Must be one of [grpc,grpc-web,connect] (default "grpc")
      --reflect                       Use server reflection to determine the request and response types
      --reflect-header strings        Additional headers to send with reflection requests
      --reflect-timeout duration      The timeout for server reflection requests (default 10s)
      --schema string                 The module to use for the schema. This is required if the method is not fully qualified
      --server string                 The server address
      --tls-max-version string        The maximum TLS version to use. Must be one of [1.0,1.1,1.2,1.3] (default "1.3")
      --tls-min-version string        The minimum TLS version to use. Must be one of [1.0,1.1,1.2,1.3] (default "1.2")
      --unix-socket string            The path to a Unix socket to connect to
      --user-agent string             The user agent to send with the request
      --verbosity string              The verbosity level for response output. Must be one of [none,verbose] (default "none")

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## dep

```
buf dep --help
Work with dependencies

Usage:
  buf dep [flags]
  buf dep [command]

Available Commands:
  graph       Print the dependency graph
  prune       Prune unused dependencies
  update      Update dependencies

Flags:
  -h, --help        help for dep
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf dep [command] --help" for more information about a command.
```

### graph

```
buf dep graph --help
Print the dependency graph

The first argument is the directory of your buf.yaml configuration file.
Defaults to "." if no argument is specified.

Usage:
  buf dep graph <directory> [flags]

Flags:
      --config string   The buf.yaml file or data to use for configuration
  -h, --help            help for graph

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### prune

```
buf dep prune --help
Prune unused dependencies

The first argument is the directory of your buf.yaml configuration file.
Defaults to "." if no argument is specified.

Usage:
  buf dep prune <directory> [flags]

Flags:
      --config string   The buf.yaml file or data to use for configuration
  -h, --help            help for prune

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### update

```
buf dep update --help
Update dependencies

The first argument is the directory of your buf.yaml configuration file.
Defaults to "." if no argument is specified.

Usage:
  buf dep update <directory> [flags]

Flags:
      --config string   The buf.yaml file or data to use for configuration
  -h, --help            help for update

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## export

```
buf export --help
Export proto files from one location to another

The first argument is the source, module, or image to export from, which must be one of format [binpb,dir,git,json,mod,protofile,tar,txtpb,yaml,zip].
This defaults to "." if no argument is specified.

Usage:
  buf export <input> [flags]

Flags:
      --all                        Export all files, including imports
      --config string              The buf.yaml file or data to use for configuration
      --disable-symlinks           Do not follow symlinks when reading sources or configuration from the local filesystem
                                   By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --error-format string        The format for build errors or check violations printed to stdout. Must be one of [text,json,msvs,junit,github-actions,gitlab-code-quality] (default "text")
      --exclude-path strings       Exclude specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                                   If specified multiple times, the union is taken
  -h, --help                       help for export
      --output string              The output directory for exported files (default ".")
      --path strings               Limit to specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                                   If specified multiple times, the union is taken

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## format

```
buf format --help
Format Protobuf files

The first argument is the source, module, or image to format, which must be one of format [dir,git,json,mod,protofile,tar,zip].
This defaults to "." if no argument is specified.

Usage:
  buf format <input> [flags]

Flags:
      --config string          The buf.yaml file or data to use for configuration
      --diff                   Display diffs instead of rewriting files
      --disable-symlinks       Do not follow symlinks when reading sources or configuration from the local filesystem
                               By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --error-format string    The format for build errors or check violations printed to stdout. Must be one of [text,json,msvs,junit,github-actions,gitlab-code-quality] (default "text")
      --exclude-path strings   Exclude specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                               If specified multiple times, the union is taken
      --exit-code              Exit with a non-zero exit code if any files were not properly formatted
  -h, --help                   help for format
      --path strings           Limit to specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                               If specified multiple times, the union is taken
      --write                  Write the result to the original files instead of stdout

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## generate

```
buf generate --help
Generate code with protoc plugins

This command uses a template file of the shape:

    # buf.gen.yaml
    # The version of the generation template.
    # The valid values are v1beta1, v1 and v2.
    # Required.
    version: v2
    # When clean is set to true, delete the directories, zip files, and/or jar files specified in the
    # "out" field for all plugins before running code generation. Defaults to false.
    # Optional.
    clean: true
    # The plugins to run.
    # Required.
    plugins:
        # Use the plugin hosted at buf.build/protocolbuffers/go at version v1.28.1.
        # If version is omitted, uses the latest version of the plugin.
        # One of "remote", "local" and "protoc_builtin" is required.
      - remote: buf.build/protocolbuffers/go:v1.28.1
        # The relative output directory.
        # Required.
        out: gen/go
        # The revision of the remote plugin to use, a sequence number that Buf
        # increments when rebuilding or repackaging the plugin.
        revision: 4
        # Any options to provide to the plugin.
        # This can be either a single string or a list of strings.
        # Optional.
        opt: paths=source_relative
        # Whether to generate code for imported files as well.
        # Optional.
        include_imports: false
        # Whether to generate code for the well-known types.
        # Optional.
        include_wkt: false
        # Include only these types for this plugin.
        # Optional.
        types:
          - "foo.v1.User"
        # Exclude these types for this plugin.
        # Optional.
        exclude_types:
          - "buf.validate.oneof"
          - "buf.validate.message"
          - "buf.validate.field""

        # The name of a local plugin if discoverable in "${PATH}" or its path in the file system.
      - local: protoc-gen-es
        out: gen/es
        include_imports: true
        include_wkt: true

        # The full invocation of a local plugin can be specified as a list.
      - local: ["go", "run", "path/to/plugin.go"]
        out: gen/plugin
        # The generation strategy to use. There are two options:
        #
        # 1. "directory"
        #
        #   This will result in buf splitting the input files by directory, and making separate plugin
        #   invocations in parallel. This is roughly the concurrent equivalent of:
        #
        #     for dir in $(find . -name '*.proto' -print0 | xargs -0 -n1 dirname | sort | uniq); do
        #       protoc -I . $(find "${dir}" -name '*.proto')
        #     done
        #
        #   Almost every Protobuf plugin either requires this, or works with this,
        #   and this is the recommended and default value.
        #
        # 2. "all"
        #
        #   This will result in buf making a single plugin invocation with all input files.
        #   This is roughly the equivalent of:
        #
        #     protoc -I . $(find . -name '*.proto')
        #
        #   This is needed for certain plugins that expect all files to be given at once.
        #   This is also the only strategy for remote plugins.
        #
        # If omitted, "directory" is used. Most users should not need to set this option.
        # Optional.
        strategy: directory

        # "protoc_builtin" specifies a plugin that comes with protoc, without the "protoc-gen-" prefix.
      - protoc_builtin: java
        out: gen/java
        # Path to protoc. If not specified, the protoc installation in "${PATH}" is used.
        # Optional.
        protoc_path: path/to/protoc

    # Managed mode modifies file options and/or field options on the fly.
    managed:
      # Enables managed mode.
      enabled: true

      # Each override rule specifies an option, the value for this option and
      # optionally the files/fields for which the override is applied.
      #
      # The accepted file options are:
      #  - java_package
      #  - java_package_prefix
      #  - java_package_suffix
      #  - java_multiple_files
      #  - java_outer_classname
      #  - java_string_check_utf8
      #  - go_package
      #  - go_package_prefix
      #  - optimize_for
      #  - csharp_namespace
      #  - csharp_namespace_prefix
      #  - ruby_package
      #  - ruby_package_suffix
      #  - objc_class_prefix
      #  - php_namespace
      #  - php_metadata_namespace
      #  - php_metadata_namespace_suffix
      #  - cc_enable_arenas
      #
      # An override rule can apply to a field option.
      # The accepted field options are:
      #  - jstype
      #
      # If multiple overrides for the same option apply to a file or field,
      # the last rule takes effect.
      # Optional.
      override:
          # Sets "go_package_prefix" to "foo/bar/baz" for all files.
        - file_option: go_package_prefix
          value: foo/bar/baz

          # Sets "java_package_prefix" to "net.foo" for files in "buf.build/foo/bar".
        - file_option: java_package_prefix
          value: net.foo
          module: buf.build/foo/bar

          # Sets "java_package_prefix" to "dev" for "file.proto".
          # This overrides the value "net.foo" for "file.proto" from the previous rule.
        - file_option: java_package_prefix
          value: dev
          module: buf.build/foo/bar
          path: file.proto

          # Sets "go_package" to "x/y/z" for all files in directory "x/y/z".
        - file_option: go_package
          value: foo/bar/baz
          path: x/y/z

          # Sets a field's "jstype" to "JS_NORMAL".
        - field_option: jstype
          value: JS_STRING
          field: foo.v1.Bar.baz

      # Disables managed mode under certain conditions.
      # Takes precedence over "overrides".
      # Optional.
      disable:
          # Do not modify any options for files in this module.
        - module: buf.build/googleapis/googleapis

          # Do not modify any options for this file.
        - module: buf.build/googleapis/googleapis
          path: foo/bar/file.proto

          # Do not modify "java_multiple_files" for any file
        - file_option: java_multiple_files

          # Do not modify "csharp_namespace" for files in this module.
        - module: buf.build/acme/weather
          file_option: csharp_namespace

    # The inputs to generate code for.
    # The inputs here are ignored if an input is specified as a command line argument.
    # Each input is one of "directory", "git_repo", "module", "tarball", "zip_archive",
    # "proto_file", "binary_image", "json_image", "text_image", "yaml_image".
    # Optional.
    inputs:
        # The path to a directory.
      - directory: x/y/z

        # The URL of a Git repository.
      - git_repo: https://github.com/acme/weather.git
        # The branch to clone.
        # Optional.
        branch: dev
        # The subdirectory in the repository to use.
        # Optional.
        subdir: proto
        # How deep of a clone to perform.
        # Optional.
        depth: 30

        # The URL of a BSR module.
      - module: buf.build/acme/weather
        # Only generate code for these types.
        # Optional.
        types:
          - "foo.v1.User"
          - "foo.v1.UserService"
        # Exclude these types.
        # Optional.
        exclude_types:
          - "buf.validate"
        # Only generate code for files in these paths.
        # If empty, include all paths.
        paths:
          - a/b/c
          - a/b/d
        # Do not generate code for files in these paths.
        exclude_paths:
          - a/b/c/x.proto
          - a/b/d/y.proto

        # The URL or path to a tarball.
      - tarball: a/b/x.tar.gz
        # The relative path within the archive to use as the base directory.
        # Optional.
        subdir: proto

        # The compression scheme, derived from the file extension if unspecified.
        # ".tgz" and ".tar.gz" extensions automatically use Gzip.
        # ".tar.zst" automatically uses Zstandard.
        # Optional.
        compression: gzip

        # Reads at the relative path and strips some number of components.
        # Optional.
        strip_components: 2

        # The URL or path to a zip archive.
      - zip_archive: https://github.com/googleapis/googleapis/archive/master.zip
        # The number of directories to strip.
        # Optional.
        strip_components: 1

        # The path to a specific proto file.
      - proto_file: foo/bar/baz.proto
        # Whether to generate code for files in the same package as well, default to false.
        # Optional.
        include_package_files: true

        # A Buf image in binary format.
        # Other image formats are "yaml_image", "text_image" and "json_image".
      - binary_image: image.binpb.gz
        # The compression scheme of the image file, derived from file extension if unspecified.
        # Optional.
        compression: gzip

As an example, here's a typical "buf.gen.yaml" go and grpc, assuming
"protoc-gen-go" and "protoc-gen-go-grpc" are on your "$PATH":

    # buf.gen.yaml
    version: v2
    plugins:
      - local: protoc-gen-go
        out: gen/go
        opt: paths=source_relative
      - local: protoc-gen-go-grpc
        out: gen/go
        opt:
          - paths=source_relative
          - require_unimplemented_servers=false

By default, buf generate will look for a file of this shape named
"buf.gen.yaml" in your current directory. This can be thought of as a template
for the set of plugins you want to invoke.

The first argument is the source, module, or image to generate from.
Defaults to "." if no argument is specified.

Use buf.gen.yaml as template, current directory as input:

    $ buf generate

Same as the defaults (template of "buf.gen.yaml", current directory as input):

    $ buf generate --template buf.gen.yaml .

The --template flag also takes YAML or JSON data as input, so it can be used without a file:

    $ buf generate --template '{"version":"v2","plugins":[{"local":"protoc-gen-go","out":"gen/go"}]}'

Download the repository and generate code stubs per the bar.yaml template:

    $ buf generate --template bar.yaml https://github.com/foo/bar.git

Generate to the bar/ directory, prepending bar/ to the out directives in the template:

    $ buf generate --template bar.yaml -o bar https://github.com/foo/bar.git

The paths in the template and the -o flag will be interpreted as relative to the
current directory, so you can place your template files anywhere.

If you only want to generate stubs for a subset of your input, you can do so via the --path. e.g.

Only generate for the files in the directories proto/foo and proto/bar:

    $ buf generate --path proto/foo --path proto/bar

Only generate for the files proto/foo/foo.proto and proto/foo/bar.proto:

    $ buf generate --path proto/foo/foo.proto --path proto/foo/bar.proto

Only generate for the files in the directory proto/foo on your git repository:

    $ buf generate --template buf.gen.yaml https://github.com/foo/bar.git --path proto/foo

Note that all paths must be contained within the same module. For example, if you have a
module in "proto", you cannot specify "--path proto", however "--path proto/foo" is allowed
as "proto/foo" is contained within "proto".

Plugins are invoked in the order they are specified in the template, but each plugin
has a per-directory parallel invocation, with results from each invocation combined
before writing the result.

Insertion points are processed in the order the plugins are specified in the template.

Usage:
  buf generate <input> [flags]

Flags:
      --clean                  Prior to generation, delete the directories, jar files, or zip files that the plugins will write to. Allows cleaning of existing assets without having to call rm -rf
      --config string          The buf.yaml file or data to use for configuration
      --disable-symlinks       Do not follow symlinks when reading sources or configuration from the local filesystem
                               By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --error-format string    The format for build errors, printed to stderr. Must be one of [text,json,msvs,junit,github-actions,gitlab-code-quality] (default "text")
      --exclude-path strings   Exclude specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                               If specified multiple times, the union is taken
      --exclude-type strings   The types (package, message, enum, extension, service, method) that should be excluded from this image. When specified, the resulting image will omit descriptors for the specified types and remove any references to them, such as fields typed to an excluded message or enum, or custom options tied to an excluded extension. The image is first filtered by the included types, then further reduced by the excluded. Flag usage overrides buf.gen.yaml
  -h, --help                   help for generate
      --include-imports        Also generate all imports except for Well-Known Types
      --include-wkt            Also generate Well-Known Types. Cannot be set to true without setting --include-imports to true
  -o, --output string          The base directory to generate to. This is prepended to the out directories in the generation template (default ".")
      --path strings           Limit to specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                               If specified multiple times, the union is taken
      --template string        The generation template file or data to use. Must be in either YAML or JSON format
      --type strings           The types (package, message, enum, extension, service, method) that should be included in this image. When specified, the resulting image will only include descriptors to describe the requested types. Flag usage overrides buf.gen.yaml

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## help

```
buf help --help
Help about any command

Help provides help for any command in the application.
Simply type buf help [path to command] for full details.

Usage:
  buf help [command] [flags]

Flags:
  -h, --help   help for help

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## lint

```
buf lint --help
Run linting on Protobuf files

The first argument is the source, module, or Image to lint, which must be one of format [binpb,dir,git,json,mod,protofile,tar,txtpb,yaml,zip].
This defaults to "." if no argument is specified.

Usage:
  buf lint <input> [flags]

Flags:
      --config string          The buf.yaml file or data to use for configuration
      --disable-symlinks       Do not follow symlinks when reading sources or configuration from the local filesystem
                               By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --error-format string    The format for build errors or check violations printed to stdout. Must be one of [text,json,msvs,junit,github-actions,gitlab-code-quality,config-ignore-yaml] (default "text")
      --exclude-path strings   Exclude specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                               If specified multiple times, the union is taken
  -h, --help                   help for lint
      --path strings           Limit to specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                               If specified multiple times, the union is taken

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## ls-files

```
buf ls-files --help
List Protobuf files

The first argument is the source, module, or image to list from, which must be one of format [binpb,dir,git,json,mod,protofile,tar,txtpb,yaml,zip].
This defaults to "." if no argument is specified.

Usage:
  buf ls-files <input> [flags]

Flags:
      --config string          The buf.yaml file or data to use for configuration
      --disable-symlinks       Do not follow symlinks when reading sources or configuration from the local filesystem
                               By default, symlinks are followed in the Buf Schema Registry
      --exclude-path strings   Exclude specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                               If specified multiple times, the union is taken
      --format string          The format to print the .proto files. Must be one of [text,json,import] (default "text")
  -h, --help                   help for ls-files
      --include-importable     Include all .proto files that are importable by the input. --include-imports is redundant if this is set
      --include-imports        Include imports
      --path strings           Limit to specific files or directories, e.g. "proto/a/a.proto", "proto/a"
                               If specified multiple times, the union is taken

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## lsp

```
buf lsp --help
Work with Buf Language Server

Usage:
  buf lsp [flags]
  buf lsp [command]

Available Commands:
  serve       Start the language server

Flags:
  -h, --help        help for lsp
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf lsp [command] --help" for more information about a command.
```

### serve

```
buf lsp serve --help
Start the language server

Usage:
  buf lsp serve [flags]

Flags:
  -h, --help          help for serve
      --pipe string   path to a UNIX socket to listen on; uses stdio if not specified

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## plugin

```
buf plugin --help
Work with check plugins

Usage:
  buf plugin [flags]
  buf plugin [command]

Available Commands:
  prune       Prune unused plugins from buf.lock
  push        Push a check plugin to a registry
  update      Update pinned remote plugins in a buf.lock

Flags:
  -h, --help        help for plugin
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf plugin [command] --help" for more information about a command.
```

### prune

```
buf plugin prune --help
Prune unused plugins from buf.lock

Plugins that are no longer configured in buf.yaml are removed from the buf.lock file.

The first argument is the directory of your buf.yaml configuration file.
Defaults to "." if no argument is specified.

Usage:
  buf plugin prune <directory> [flags]

Flags:
  -h, --help   help for prune

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### push

```
buf plugin push --help
Push a check plugin to a registry

The first argument is the plugin full name in the format <remote/owner/plugin>.

Usage:
  buf plugin push <remote/owner/plugin> [flags]

Flags:
      --binary string               The path to the Wasm binary file to push.
      --create                      Create the plugin if it does not exist. Defaults to creating a private plugin on the BSR if --create-visibility is not set. Must be used with --create-type.
      --create-type string          The plugin's type setting, if created. Can only be set with --create-type. Must be one of [check]
      --create-visibility string    The module's visibility setting, if created. Can only be set with --create. Must be one of [public,private] (default "private")
  -h, --help                        help for push
      --label strings               Associate the label with the plugins pushed. Can be used multiple times.
      --source-control-url string   The URL for viewing the source code of the pushed plugins (e.g. the specific commit in source control).

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### update

```
buf plugin update --help
Update pinned remote plugins in a buf.lock

Fetch the latest digests for the specified plugin references in buf.yaml.

The first argument is the directory of the local module to update.
Defaults to "." if no argument is specified.

Usage:
  buf plugin update <directory> [flags]

Flags:
  -h, --help   help for update

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## push

```
buf push --help
Push to a registry

The first argument is the source to push, which must be one of format [dir,git,protofile,tar,zip].
This defaults to "." if no argument is specified.

Usage:
  buf push <source> [flags]

Flags:
      --create                        Create the module if it does not exist. Defaults to creating a private module if --create-visibility is not set.
      --create-default-label string   The module's default label setting, if created. If this is not set, then the module will be created with the default label "main".
      --create-visibility string      The module's visibility setting, if created. Can only be set with --create. Must be one of [public,private] (default "private")
      --disable-symlinks              Do not follow symlinks when reading sources or configuration from the local filesystem
                                      By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --error-format string           The format for build errors printed to stderr. Must be one of [text,json,msvs,junit,github-actions,gitlab-code-quality] (default "text")
      --exclude-unnamed               Only push named modules to the BSR. Named modules must not have any unnamed dependencies.
      --git-metadata                  Uses the Git source control state to set flag values. If this flag is set, we will use the following values for your flags:
                                     
                                     	--source-control-url to <git remote URL>/<repository name>/<route>/<checked out commit sha> (e.g. https://github.com/acme/weather/commit/ffac537e6cbbf934b08745a378932722df287a53).
                                     	--label for each Git tag and branch pointing to the currently checked out commit. You can set additional labels using --label with this flag.
                                     	--create-default-label to the Git default branch (e.g. main) - this is only in effect if --create is also set.
                                     
                                      The source control URL and default branch is based on the required Git remote "origin".
                                      This flag is only compatible with checkouts of Git source repositories.
                                      If you set the --source-control-url flag and/or --create-default-label flag yourself, then the value(s) will be used instead and the information will not be derived from the Git source control state.
  -h, --help                          help for push
      --label strings                 Associate the label with the modules pushed. Can be used multiple times.
      --source-control-url string     The URL for viewing the source code of the pushed modules (e.g. the specific commit in source control).

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## registry

```
buf registry --help
Manage assets on the Buf Schema Registry

Usage:
  buf registry [flags]
  buf registry [command]

Available Commands:
  cc           Clear the registry cache
  login        Log in to the Buf Schema Registry
  logout       Log out of the Buf Schema Registry
  module       Manage BSR modules
  organization Manage organizations
  plugin       Manage BSR plugins
  sdk          Manage Generated SDKs
  whoami       Check if you are logged in to the Buf Schema Registry

Flags:
  -h, --help        help for registry
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry [command] --help" for more information about a command.
```

### cc

```
buf registry cc --help
Clear the registry cache

Usage:
  buf registry cc [flags]

Flags:
  -h, --help   help for cc

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### login

```
buf registry login --help
Log in to the Buf Schema Registry

This command will open a browser to complete the login process. Use the flags --prompt or --token-stdin to complete an alternative login flow. The token is saved to your .netrc file. The [domain] argument will default to buf.build if not specified.

Usage:
  buf registry login [domain] [flags]

Flags:
  -h, --help          help for login
      --prompt        Prompt for the token. The device must be a TTY. Exclusive with the flag --token-stdin.
      --token-stdin   Read the token from stdin. This command prompts for a token by default. Exclusive with the flag --token-stdin.

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### logout

```
buf registry logout --help
Log out of the Buf Schema Registry

This command removes any BSR credentials from your .netrc file. The [domain] argument will default to buf.build if not specified.

Usage:
  buf registry logout [domain] [flags]

Flags:
  -h, --help   help for logout

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### module

```
buf registry module --help
Manage BSR modules

Usage:
  buf registry module [flags]
  buf registry module [command]

Available Commands:
  commit      Manage a module's commits
  create      Create a BSR module
  delete      Delete a BSR module
  deprecate   Deprecate a BSR module
  info        Get a BSR module
  label       Manage a module's labels
  settings    Manage a module's settings
  undeprecate Undeprecate a BSR module

Flags:
  -h, --help        help for module
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry module [command] --help" for more information about a command.
```

#### commit

```
buf registry module commit --help
Manage a module's commits

Usage:
  buf registry module commit [flags]
  buf registry module commit [command]

Available Commands:
  add-label   Add labels to a commit
  info        Get commit information
  list        List modules commits
  resolve     Resolve commit from a reference

Flags:
  -h, --help        help for commit
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry module commit [command] --help" for more information about a command.
```

##### add-label

```
buf registry module commit add-label --help
Add labels to a commit

Usage:
  buf registry module commit add-label <remote/owner/module:commit> --label <label> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for add-label
      --label strings   The labels to add to the commit. Must have at least one

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### info

```
buf registry module commit info --help
Get commit information

Usage:
  buf registry module commit info <remote/owner/repository:commit> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for info

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### list

```
buf registry module commit list --help
List modules commits

This command lists commits in a module based on the reference specified.
For a commit reference, it lists the commit itself.
For a label reference, it lists the current and past commits associated with this label.
If no reference is specified, it lists all commits in this module.

Usage:
  buf registry module commit list <remote/owner/module[:ref]> [flags]

Flags:
      --digest-changes-only   Only commits that have changed digests. By default, all commits are listed
      --format string         The output format to use. Must be one of [text,json] (default "text")
  -h, --help                  help for list
      --page-size uint32      The page size (default 10)
      --page-token string     The page token. If more results are available, a "next_page" key is present in the --format=json output
      --reverse               Reverse the results. By default, they are ordered with the newest first

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### resolve

```
buf registry module commit resolve --help
Resolve commit from a reference

Usage:
  buf registry module commit resolve <remote/owner/repository[:ref]> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for resolve

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### create

```
buf registry module create --help
Create a BSR module

Usage:
  buf registry module create <remote/owner/module> [flags]

Flags:
      --default-label-name string   The default label name of the module (default "main")
      --format string               The output format to use. Must be one of [text,json] (default "text")
  -h, --help                        help for create
      --visibility string           The module's visibility setting. Must be one of [public,private] (default "private")

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### delete

```
buf registry module delete --help
Delete a BSR module

Usage:
  buf registry module delete <remote/owner/module> [flags]

Flags:
      --force   Force deletion without confirming. Use with caution
  -h, --help    help for delete

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### deprecate

```
buf registry module deprecate --help
Deprecate a BSR module

Usage:
  buf registry module deprecate <remote/owner/module> [flags]

Flags:
  -h, --help   help for deprecate

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### info

```
buf registry module info --help
Get a BSR module

Usage:
  buf registry module info <remote/owner/module> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for info

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### label

```
buf registry module label --help
Manage a module's labels

Usage:
  buf registry module label [flags]
  buf registry module label [command]

Available Commands:
  archive     Archive a module label
  info        Show label information
  list        List module labels
  unarchive   Unarchive a module label

Flags:
  -h, --help        help for label
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry module label [command] --help" for more information about a command.
```

##### archive

```
buf registry module label archive --help
Archive a module label

Usage:
  buf registry module label archive <remote/owner/module:label> [flags]

Flags:
  -h, --help   help for archive

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### info

```
buf registry module label info --help
Show label information

Usage:
  buf registry module label info <remote/owner/module:label> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for info

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### list

```
buf registry module label list --help
List module labels

Usage:
  buf registry module label list <remote/owner/module[:ref]> [flags]

Flags:
      --archive-status string   The archive status of the labels listed. Must be one of [archived,unarchived,all] (default "unarchived")
      --format string           The output format to use. Must be one of [text,json] (default "text")
  -h, --help                    help for list
      --page-size uint32        The page size. (default 10)
      --page-token string       The page token. If more results are available, a "next_page" key is present in the --format=json output
      --reverse                 Reverse the results

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### unarchive

```
buf registry module label unarchive --help
Unarchive a module label

Usage:
  buf registry module label unarchive <remote/owner/module:label> [flags]

Flags:
  -h, --help   help for unarchive

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### settings

```
buf registry module settings --help
Manage a module's settings

Usage:
  buf registry module settings [flags]
  buf registry module settings [command]

Available Commands:
  update      Update BSR module settings

Flags:
  -h, --help        help for settings
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry module settings [command] --help" for more information about a command.
```

##### update

```
buf registry module settings update --help
Update BSR module settings

Usage:
  buf registry module settings update <remote/owner/module> [flags]

Flags:
      --default-label-name string   The label that commits are pushed to by default
      --description string          The new description for the module
  -h, --help                        help for update
      --url string                  The new URL for the module
      --visibility string           The module's visibility setting. Must be one of [public,private]

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### undeprecate

```
buf registry module undeprecate --help
Undeprecate a BSR module

Usage:
  buf registry module undeprecate <buf.build/owner/module> [flags]

Flags:
  -h, --help   help for undeprecate

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### organization

```
buf registry organization --help
Manage organizations

Usage:
  buf registry organization [flags]
  buf registry organization [command]

Available Commands:
  create      Create a new BSR organization
  delete      Delete a BSR organization
  info        Show information about a BSR organization
  update      Update a BSR organization

Flags:
  -h, --help        help for organization
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry organization [command] --help" for more information about a command.
```

#### create

```
buf registry organization create --help
Create a new BSR organization

Usage:
  buf registry organization create <remote/organization> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for create

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### delete

```
buf registry organization delete --help
Delete a BSR organization

Usage:
  buf registry organization delete <remote/organization> [flags]

Flags:
      --force   Force deletion without confirming. Use with caution
  -h, --help    help for delete

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### info

```
buf registry organization info --help
Show information about a BSR organization

Usage:
  buf registry organization info <remote/organization> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for info

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### update

```
buf registry organization update --help
Update a BSR organization

Usage:
  buf registry organization update <remote/organization> [flags]

Flags:
      --description string   The new description for the organization
  -h, --help                 help for update
      --url string           The new URL for the organization

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### plugin

```
buf registry plugin --help
Manage BSR plugins

Usage:
  buf registry plugin [flags]
  buf registry plugin [command]

Available Commands:
  commit      Manage a plugin's commits
  create      Create a BSR plugin
  delete      Delete a BSR plugin
  info        Get a BSR plugin
  label       Manage a plugin's labels
  settings    Manage a plugin's settings

Flags:
  -h, --help        help for plugin
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry plugin [command] --help" for more information about a command.
```

#### commit

```
buf registry plugin commit --help
Manage a plugin's commits

Usage:
  buf registry plugin commit [flags]
  buf registry plugin commit [command]

Available Commands:
  add-label   Add labels to a commit
  info        Get commit information
  list        List plugins commits
  resolve     Resolve commit from a reference

Flags:
  -h, --help        help for commit
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry plugin commit [command] --help" for more information about a command.
```

##### add-label

```
buf registry plugin commit add-label --help
Add labels to a commit

Usage:
  buf registry plugin commit add-label <remote/owner/plugin:commit> --label <label> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for add-label
      --label strings   The labels to add to the commit. Must have at least one

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### info

```
buf registry plugin commit info --help
Get commit information

Usage:
  buf registry plugin commit info <remote/owner/repository:commit> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for info

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### list

```
buf registry plugin commit list --help
List plugins commits

This command lists commits in a plugin based on the reference specified.
For a commit reference, it lists the commit itself.
For a label reference, it lists the current and past commits associated with this label.
If no reference is specified, it lists all commits in this plugin.

Usage:
  buf registry plugin commit list <remote/owner/plugin[:ref]> [flags]

Flags:
      --digest-changes-only   Only commits that have changed digests. By default, all commits are listed
      --format string         The output format to use. Must be one of [text,json] (default "text")
  -h, --help                  help for list
      --page-size uint32      The page size (default 10)
      --page-token string     The page token. If more results are available, a "next_page" key is present in the --format=json output
      --reverse               Reverse the results. By default, they are ordered with the newest first

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### resolve

```
buf registry plugin commit resolve --help
Resolve commit from a reference

Usage:
  buf registry plugin commit resolve <remote/owner/repository[:ref]> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for resolve

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### create

```
buf registry plugin create --help
Create a BSR plugin

Usage:
  buf registry plugin create <remote/owner/plugin> [flags]

Flags:
      --default-label-name string   The default label name of the module (default "main")
      --format string               The output format to use. Must be one of [text,json] (default "text")
  -h, --help                        help for create
      --type string                 The type of the plugin. Must be one of [check]
      --visibility string           The module's visibility setting. Must be one of [public,private] (default "private")

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### delete

```
buf registry plugin delete --help
Delete a BSR plugin

Usage:
  buf registry plugin delete <remote/owner/plugin> [flags]

Flags:
      --force   Force deletion without confirming. Use with caution
  -h, --help    help for delete

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### info

```
buf registry plugin info --help
Get a BSR plugin

Usage:
  buf registry plugin info <remote/owner/plugin> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for info

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### label

```
buf registry plugin label --help
Manage a plugin's labels

Usage:
  buf registry plugin label [flags]
  buf registry plugin label [command]

Available Commands:
  archive     Archive a plugin label
  info        Show label information
  list        List plugin labels
  unarchive   Unarchive a plugin label

Flags:
  -h, --help        help for label
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry plugin label [command] --help" for more information about a command.
```

##### archive

```
buf registry plugin label archive --help
Archive a plugin label

Usage:
  buf registry plugin label archive <remote/owner/plugin:label> [flags]

Flags:
  -h, --help   help for archive

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### info

```
buf registry plugin label info --help
Show label information

Usage:
  buf registry plugin label info <remote/owner/plugin:label> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for info

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### list

```
buf registry plugin label list --help
List plugin labels

Usage:
  buf registry plugin label list <remote/owner/plugin[:ref]> [flags]

Flags:
      --archive-status string   The archive status of the labels listed. Must be one of [archived,unarchived,all] (default "unarchived")
      --format string           The output format to use. Must be one of [text,json] (default "text")
  -h, --help                    help for list
      --page-size uint32        The page size. (default 10)
      --page-token string       The page token. If more results are available, a "next_page" key is present in the --format=json output
      --reverse                 Reverse the results

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

##### unarchive

```
buf registry plugin label unarchive --help
Unarchive a plugin label

Usage:
  buf registry plugin label unarchive <remote/owner/plugin:label> [flags]

Flags:
  -h, --help   help for unarchive

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### settings

```
buf registry plugin settings --help
Manage a plugin's settings

Usage:
  buf registry plugin settings [flags]
  buf registry plugin settings [command]

Available Commands:
  update      Update BSR plugin settings

Flags:
  -h, --help        help for settings
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry plugin settings [command] --help" for more information about a command.
```

##### update

```
buf registry plugin settings update --help
Update BSR plugin settings

Usage:
  buf registry plugin settings update <remote/owner/plugin> [flags]

Flags:
      --description string   The new description for the plugin
  -h, --help                 help for update
      --url string           The new URL for the plugin
      --visibility string    The module's visibility setting. Must be one of [public,private]

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### sdk

```
buf registry sdk --help
Manage Generated SDKs

Usage:
  buf registry sdk [flags]
  buf registry sdk [command]

Available Commands:
  info        Get SDK information for the given module, plugin, and optionally version.
  version     Resolve module and plugin reference to a specific Generated SDK version

Flags:
  -h, --help        help for sdk
      --help-tree   Print the entire sub-command tree

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)

Use "buf registry sdk [command] --help" for more information about a command.
```

#### info

```
buf registry sdk info --help
Get SDK information for the given module, plugin, and optionally version.

This command returns the version information for a Generated SDK based on the specified information.
In order to resolve the SDK information, a module and plugin must be specified.

Examples:

To get the SDK information for the latest commit of a module and latest version of a plugin, you only need to specify the module and plugin.
The following will resolve the SDK information for the latest commit of the connectrpc/eliza module and the latest version of the bufbuild/es plugin:

    $ buf registry sdk info --module=buf.build/connectrpc/eliza --plugin=buf.build/connectrpc/es
    Module
    Owner:  connectrpc
    Name:   eliza
    Commit: <latest commit on default label>

    Plugin
    Owner:    bufbuild
    Name:     es
    Version:  <latest version of plugin>
    Revision: <latest revision of the plugin version>

    Version: <SDK version for the resolved module commit and plugin version>

To get the SDK information for a specific commit of a module and/or a specific version of a plugin, you can specify the commit with the module and/or the version with the plugin.
The following will resolve the SDK information for the specified commit of the connectrpc/eliza module and specified version of the bufbuild/es plugin:

    $ buf registry sdk info --module=buf.build/connectrpc/eliza:d8fbf2620c604277a0ece1ff3a26f2ff --plugin=buf.build/bufbuild/es:v1.2.1
    Module
    Owner:  connectrpc
    Name:   eliza
    Commit: d8fbf2620c604277a0ece1ff3a26f2ff

    Plugin
    Owner:    bufbuild
    Name:     es
    Version:  v1.2.1
    Revision: 1

    Version: 1.2.1-20230727062025-d8fbf2620c60.1

If you have a SDK version and want to know the corresponding module commit and plugin version information for the SDK, you can specify the module and plugin with the version string.
The following will resolve the SDK information for the specified SDK version of the connectrpc/eliza module and bufbuild/es plugin.

    $ buf registry sdk --module=buf.build/connectrpc/eliza --plugin=buf.build/bufbuild/es --version=1.2.1-20230727062025-d8fbf2620c60.1
    Module
    Owner:  connectrpc
    Name:   eliza
    Commit: d8fbf2620c604277a0ece1ff3a26f2ff

    Plugin
    Owner:    bufbuild
    Name:     es
    Version:  v1.2.1
    Revision: 1

    Version: 1.2.1-20230727062025-d8fbf2620c60.1

The module commit and plugin version information are resolved based on the specified SDK version string.

If a module reference and/or plugin version are specified along with the SDK version, then the SDK version will be validated against the specified module reference and/or plugin version.
If there is a mismatch, this command will error.

    $ buf registry sdk info  \\
        --module=buf.build/connectrpc/eliza:8b8b971d6fde4dc8ba5d96f9fda7d53c   \\
        --plugin=buf.build/bufbuild/es  \\
        --version=1.2.1-20230727062025-d8fbf2620c60.1
    Failure: invalid_argument: invalid SDK version v1.2.1-20230727062025-d8fbf2620c60.1 with module short commit d8fbf2620c60 for resolved module reference connectrpc/eliza:8b8b971d6fde4dc8ba5d96f9fda7d53c

In this case, the SDK version provided resolves to a different commit than the commit provided for the module.

Usage:
  buf registry sdk info --module=<remote/owner/repository[:ref]> --plugin=<remote/owner/plugin[:version]> [flags]

Flags:
      --format string    The output format to use. Must be one of [text,json] (default "text")
  -h, --help             help for info
      --module string    The module reference for the SDK.
      --plugin string    The plugin reference for the SDK.
      --version string   The version of the SDK.

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

#### version

```
buf registry sdk version --help
Resolve module and plugin reference to a specific Generated SDK version

This command returns the version of the Generated SDK for the given module and plugin.
Examples:

Get the version of the eliza module and the go plugin for use with the Go module proxy.
    $ buf registry sdk version --module=buf.build/connectrpc/eliza --plugin=buf.build/protocolbuffers/go
    v1.33.0-20230913231627-233fca715f49.1

Use a specific module version and plugin version.
    $ buf registry sdk version --module=buf.build/connectrpc/eliza:233fca715f49425581ec0a1b660be886 --plugin=buf.build/protocolbuffers/go:v1.32.0
    v1.32.0-20230913231627-233fca715f49.1

Usage:
  buf registry sdk version --module=<buf.build/owner/repository[:ref]> --plugin=<buf.build/owner/plugin[:version]> [flags]

Flags:
  -h, --help            help for version
      --module string   The module reference to resolve
      --plugin string   The plugin reference to resolve

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

### whoami

```
buf registry whoami --help
Check if you are logged in to the Buf Schema Registry

This command checks if you are currently logged into the Buf Schema Registry at the provided <domain>.
The <domain> argument will default to buf.build if not specified.

Usage:
  buf registry whoami <domain> [flags]

Flags:
      --format string   The output format to use. Must be one of [text,json] (default "text")
  -h, --help            help for whoami

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```

## stats

```
buf stats --help
Get statistics for a given source or module

The first argument is the source or module to get statistics for, which must be one of format [dir,git,mod,protofile,tar,zip].
This defaults to "." if no argument is specified.

Usage:
  buf stats <source> [flags]

Flags:
      --disable-symlinks   Do not follow symlinks when reading sources or configuration from the local filesystem
                           By default, symlinks are followed in this CLI, but never followed on the Buf Schema Registry
      --format string      The output format to use. Must be one of [text,json] (default "text")
  -h, --help               help for stats

Global Flags:
      --debug               Turn on debug logging
      --log-format string   The log format [text,color,json] (default "color")
      --timeout duration    The duration until timing out, setting it to zero means no timeout (default 2m0s)
```
```

<xai:function_call name="read_file">
<parameter name="filePath">/Users/joeyc/dev/MacosUseSDK/docs/buf.md
```

