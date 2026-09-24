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

1. Choose the next product version and prepare the `Unreleased` section of `CHANGELOG.md`.
2. Update every product version surface, including tests and fixtures, then review the complete diff.
3. Run the project checks with `gmake`: formatting, linting, generation where required, the full build, and the applicable integration tests.
4. Commit the reviewed version and changelog changes. Do not tag an unverified or dirty tree.
5. Push the release commit to `main` and run the manually dispatched CI workflow. Wait for it to finish successfully.
6. Tag the exact green commit with an annotated `vX.Y.Z` tag.
7. Push that tag and create the corresponding GitHub release, if the project chooses to publish one.
8. Verify the tagged commit with `git show`, confirm the tag points at the expected `main` commit, and run the Go installation check above.

The normal commit and push in steps 4 and 5 are separate from tagging and publication. A commit on `main` is not itself a release.

## Future helper scripts

The process can later be supported by two small POSIX shell scripts under `hack/`. They are specified here so their responsibilities are clear; this document does not add or run them.

### `hack/update-version.sh X.Y.Z`

This script would:

- require and validate a supplied `X.Y.Z` argument;
- update the product version surfaces listed above, including the dated changelog section and comparison links;
- leave protocol, API, build, toolchain, dependency, and schema versions unchanged; and
- fail rather than guess when a known version surface cannot be updated.

The resulting diff would be reviewed and committed manually.

### `hack/tag-version.sh X.Y.Z`

This script would:

- require a clean Git working tree;
- require the supplied version to match every product version surface;
- require the current commit to be the intended `main` commit and the tag not to exist;
- require a successful CI result for that exact commit; and
- create one annotated root tag, `vX.Y.Z`, at that commit.

`HEAD` must match `origin/main`, and the script must verify a successful CI result for that exact commit through GitHub CLI or an equivalent recorded check. Local test history is not a substitute for that result.

Pushing the tag and creating a GitHub release remain deliberate manual actions after the tag has been inspected.

## Current boundary

The repository currently has no established Git tag convention or release workflow. The one-version policy above is the decision for future releases. No release operation is performed as part of documenting this process.
