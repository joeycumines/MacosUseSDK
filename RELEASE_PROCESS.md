# Release process

This document defines how an ExactMac release is prepared and identified. It does not create a release, a Git tag, or a GitHub release.

## Version policy

ExactMac uses one product SemVer and one root Git tag:

- Product version: `X.Y.Z`
- Git tag: `vX.Y.Z`
- Go module: `github.com/joeycumines/ExactMac`

The root `go.mod` declares that module and has no separate product-version field; the root Git tag supplies the module version.

The root tag must use the `vX.Y.Z` form required by Go modules. It supports commands such as:

```sh
go install github.com/joeycumines/ExactMac/cmd/exactmac@vX.Y.Z
```

The product version is kept in the same value in:

- `CHANGELOG.md`
- the `exactmac` CLI version output
- the MCP `serverInfo.version` value
- `EXACTMAC_VERSION` in `make/exactmac.mk`
- `skills/exactmac/claude-plugin.json`
- the version metadata in `skills/exactmac/SKILL.md`
- tests and fixtures that assert the product version

The Claude plugin and skill are one coupled distribution. They use the product version and do not receive separate Git tags.

These versions remain independent and must not be changed to match the product version:

- `CFBundleVersion` and `EXACTMAC_BUILD_VERSION`
- MCP protocol and HTTP compatibility versions
- the protobuf API package version (`exactmac.v1`)
- Go and Swift toolchain requirements
- page-token, persistence, and other schema versions
- dependency and CI action versions

The nested `integration` Go module is not published as part of the product release. If it is published later, it receives its own `integration/vX.Y.Z` tag; its independent versioning policy must be reviewed at that time.

A future `v2.0.0` product release also requires a decision about the root Go module path, because Go modules at major version 2 and later normally require a `/v2` path suffix.

## Release steps

1. Add the release notes to the `Unreleased` section of `CHANGELOG.md`.
2. Run `gmake release.update RELEASE_VERSION=X.Y.Z`. It updates the product version surfaces listed above, promotes the `Unreleased` notes into a dated release section, and leaves independent versions unchanged.
3. Review the complete diff and run the project checks with `gmake`: formatting, linting, generation where required, the full build, and the applicable integration tests.
4. Commit the reviewed version and changelog changes. Do not tag an unverified or dirty tree.
5. Push the release commit to `main` and run the manually dispatched CI workflow. Wait for it to finish successfully.
6. Run `gmake release.tag RELEASE_VERSION=X.Y.Z` against that exact green commit. The script creates one annotated local `vX.Y.Z` tag; it does not push the tag.
7. Inspect the tag with `git show`, confirm it points at the expected `main` commit, and push the inspected tag.
8. After the tag is remote, verify the installation with `GOPROXY=direct go install github.com/joeycumines/ExactMac/cmd/exactmac@vX.Y.Z`.
9. Create the corresponding GitHub release, if the project chooses to publish one.

The normal commit and push in steps 4 and 5 are separate from tagging and publication. A commit on `main` is not itself a release.

## Release helper scripts

These two POSIX shell scripts live under `hack/release/` and are exposed through the composable `make/release.mk` targets. They are deliberately conservative and do not commit, push, or publish.

### `gmake release.update RELEASE_VERSION=X.Y.Z`

The update script:

- requires and validates one supplied `X.Y.Z` argument;
- reads the current product version from `make/exactmac.mk` and verifies the known product surfaces agree;
- updates the CLI output, MCP `serverInfo.version`, `EXACTMAC_VERSION`, plugin and skill metadata, product-version test fixtures, and `CHANGELOG.md`;
- promotes non-empty `Unreleased` notes to a UTC-dated release section and updates the comparison links;
- leaves protocol, API, build, toolchain, dependency, schema, and `go.mod` versions unchanged; and
- refuses malformed or non-increasing versions, missing surfaces, an existing target release, an empty `Unreleased` section, or an incomplete edit rather than guessing.

The resulting diff is reviewed and committed manually.

### `gmake release.tag RELEASE_VERSION=X.Y.Z`

The tag script requires GitHub CLI (`gh`) and:

- requires a clean working tree, including non-ignored untracked files;
- requires the current branch to be `main` and `HEAD` to equal `origin/main`;
- requires the supplied version to match every product version surface and the changelog;
- requires `vX.Y.Z` not to exist;
- requires a successful `ci.yaml` run for the exact `HEAD` SHA; and
- creates one annotated local root tag, `vX.Y.Z`, at that commit.

The script never pushes the tag or creates a GitHub release. Pushing and publication remain deliberate manual actions after inspection.

### Script verification

Run the disposable-fixture harness before using either script in a release:

```sh
gmake release.test
```

The harness exercises successful updates, malformed and incomplete input, dirty and divergent trees, wrong branches, failed or mismatched CI results, existing tags, and the annotated-tag success path without touching the source checkout.
