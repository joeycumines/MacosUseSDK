#!/bin/sh

# Exercise release scripts only in disposable repositories. This harness never
# changes the source checkout and never creates a tag in the source checkout.

fail() {
  printf 'test-release-scripts.sh: %s\n' "$1" >&2
  exit 1
}

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
repo_root=$(CDPATH='' cd "$script_dir/../.." && pwd) || exit 1

update_fixture=
empty_fixture=
symlink_fixture=
url_fixture=
readonly_fixture=
history_fixture=
fence_fixture=
parent_fixture=
rollback_fixture=
failbin=
race_fixture=
racebin=
tag_fixture=
gh_dir=
gitfailbin=
signalbin=
cleanup() {
  if [ -n "$update_fixture" ] && [ -d "$update_fixture" ]; then rm -rf "$update_fixture"; fi
  if [ -n "$empty_fixture" ] && [ -d "$empty_fixture" ]; then rm -rf "$empty_fixture"; fi
  if [ -n "$symlink_fixture" ] && [ -d "$symlink_fixture" ]; then rm -rf "$symlink_fixture"; fi
  if [ -n "$url_fixture" ] && [ -d "$url_fixture" ]; then rm -rf "$url_fixture"; fi
  if [ -n "$readonly_fixture" ] && [ -d "$readonly_fixture" ]; then rm -rf "$readonly_fixture"; fi
  if [ -n "$history_fixture" ] && [ -d "$history_fixture" ]; then rm -rf "$history_fixture"; fi
  if [ -n "$fence_fixture" ] && [ -d "$fence_fixture" ]; then rm -rf "$fence_fixture"; fi
  if [ -n "$parent_fixture" ] && [ -d "$parent_fixture" ]; then rm -rf "$parent_fixture"; fi
  if [ -n "$rollback_fixture" ] && [ -d "$rollback_fixture" ]; then rm -rf "$rollback_fixture"; fi
  if [ -n "$failbin" ] && [ -d "$failbin" ]; then rm -rf "$failbin"; fi
  if [ -n "$race_fixture" ] && [ -d "$race_fixture" ]; then rm -rf "$race_fixture"; fi
  if [ -n "$racebin" ] && [ -d "$racebin" ]; then rm -rf "$racebin"; fi
  if [ -n "$tag_fixture" ] && [ -d "$tag_fixture" ]; then rm -rf "$tag_fixture"; fi
  if [ -n "$gh_dir" ] && [ -d "$gh_dir" ]; then rm -rf "$gh_dir"; fi
  if [ -n "$gitfailbin" ] && [ -d "$gitfailbin" ]; then rm -rf "$gitfailbin"; fi
  if [ -n "$signalbin" ] && [ -d "$signalbin" ]; then rm -rf "$signalbin"; fi
}
trap cleanup 0 1 2 15

assert_contains() {
  assert_file=$1
  assert_needle=$2
  grep -F "$assert_needle" "$assert_file" >/dev/null 2>&1 || fail "$assert_file is missing: $assert_needle"
}

assert_count() {
  count_file=$1
  count_needle=$2
  count_expected=$3
  count_actual=$(awk -v needle="$count_needle" '
    {
      rest = $0
      while ((position = index(rest, needle)) > 0) {
        count++
        rest = substr(rest, position + length(needle))
      }
    }
    END { print count + 0 }
  ' "$count_file")
  [ "$count_actual" -eq "$count_expected" ] || fail "$count_file count for $count_needle = $count_actual, want $count_expected"
}

assert_no_tag() {
  assert_repo=$1
  assert_version=$2
  if git -C "$assert_repo" show-ref --verify --quiet "refs/tags/v$assert_version"; then
    fail "unexpected tag v$assert_version in $assert_repo"
  fi
}

copy_release_files() {
  copy_root=$1
  mkdir -p "$copy_root/hack/release" "$copy_root/cmd/exactmac" "$copy_root/internal/server" "$copy_root/make" "$copy_root/skills/exactmac" || fail "cannot create fixture directories"
  cp "$repo_root/hack/release/update-version.sh" "$copy_root/hack/release/update-version.sh" || fail "cannot copy update script"
  cp "$repo_root/hack/release/tag-version.sh" "$copy_root/hack/release/tag-version.sh" || fail "cannot copy tag script"
  cp "$repo_root/hack/release/release-version-common.sh" "$copy_root/hack/release/release-version-common.sh" || fail "cannot copy release validation helper"
  cp "$repo_root/hack/release/validate-go-version.go" "$copy_root/hack/release/validate-go-version.go" || fail "cannot copy Go version validator"
  cp "$repo_root/cmd/exactmac/main.go" "$copy_root/cmd/exactmac/main.go" || fail "cannot copy CLI source"
  cp "$repo_root/internal/server/protocol_dispatch.go" "$copy_root/internal/server/protocol_dispatch.go" || fail "cannot copy server source"
  cp "$repo_root/internal/server/mcpresources_test.go" "$copy_root/internal/server/mcpresources_test.go" || fail "cannot copy resource fixture"
  cp "$repo_root/internal/server/mcpinitialization_test.go" "$copy_root/internal/server/mcpinitialization_test.go" || fail "cannot copy initialization fixture"
  cp "$repo_root/internal/server/mcppromptslist_test.go" "$copy_root/internal/server/mcppromptslist_test.go" || fail "cannot copy prompts fixture"
  cp "$repo_root/make/exactmac.mk" "$copy_root/make/exactmac.mk" || fail "cannot copy make module"
  cp "$repo_root/skills/exactmac/claude-plugin.json" "$copy_root/skills/exactmac/claude-plugin.json" || fail "cannot copy plugin manifest"
  cp "$repo_root/skills/exactmac/SKILL.md" "$copy_root/skills/exactmac/SKILL.md" || fail "cannot copy skill metadata"
  cp "$repo_root/CHANGELOG.md" "$copy_root/CHANGELOG.md" || fail "cannot copy changelog"
}

initialize_fixture() {
  initialize_root=$1
  git -C "$initialize_root" init -q -b main >/dev/null 2>&1 || fail "cannot initialize fixture Git repository"
  git -C "$initialize_root" remote add origin https://github.com/joeycumines/ExactMac.git || fail "cannot create fixture origin"
  git -C "$initialize_root" add . || fail "cannot stage fixture"
  GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$initialize_root" commit -q -m fixture || fail "cannot commit fixture"
  git -C "$initialize_root" update-ref refs/remotes/origin/main HEAD || fail "cannot create fixture origin/main"
}

add_update_note() {
  note_root=$1
  note_tmp="$note_root/CHANGELOG.fixture"
  awk '
    { print }
    $0 == "## [Unreleased]" {
      print ""
      print "### Added"
      print "- Fixture release note."
    }
  ' "$note_root/CHANGELOG.md" > "$note_tmp" || fail "cannot add fixture changelog note"
  mv "$note_tmp" "$note_root/CHANGELOG.md" || fail "cannot install fixture changelog note"
}

write_gh_stub() {
  stub_conclusion=$1
  stub_head=${2:-$(git -C "$tag_fixture" rev-parse HEAD)}
  stub_second_head=${3:-$stub_head}
  stub_file="$gh_dir/gh"
  rm -f "$gh_dir/api-count"
# The generated gh stub intentionally contains literal shell expansions.
# shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/sh' \
    "head=\$(git rev-parse HEAD)" \
    '[ "${GH_HOST:-}" = github.com ] || exit 2' \
    'if [ "$1" = api ]; then' \
    '  [ "$2" = repos/joeycumines/ExactMac/commits/main ] || exit 2' \
    "api_count_file=\"$gh_dir/api-count\"" \
    '  api_count=0' \
    '  if [ -f "$api_count_file" ]; then api_count=$(awk "{ print \$1 + 0 }" "$api_count_file"); fi' \
    '  api_count=$((api_count + 1))' \
    '  printf "%s\\n" "$api_count" > "$api_count_file"' \
    '  if [ "$api_count" -ge 2 ]; then printf "%s\\n" "'"$stub_second_head"'"; else printf "%s\\n" "$head"; fi' \
    '  exit 0' \
    'fi' \
    '[ "$1" = run ] && [ "$2" = list ] && shift 2 || exit 2' \
    'workflow=' \
    'commit=' \
    'repo=' \
    'while [ "$#" -gt 0 ]; do' \
    '  case "$1" in' \
    '    --workflow|--commit|--repo|--json|--limit|--jq)' \
    '      [ "$#" -ge 2 ] || exit 2' \
    '      case "$1" in' \
    '        --workflow) workflow=$2 ;;' \
    '        --commit) commit=$2 ;;' \
    '        --repo) repo=$2 ;;' \
    '      esac' \
    '      shift 2' \
    '      ;;' \
    '    *) exit 2 ;;' \
    '  esac' \
    'done' \
    '[ "$workflow" = ci.yaml ] && [ "$repo" = joeycumines/ExactMac ] && [ "$commit" = "$head" ] || exit 2' \
    "printf '1\\t%s\\tcompleted\\t%s\\n' \"$stub_head\" \"$stub_conclusion\"" \
    > "$stub_file" || fail "cannot write gh stub"
  chmod 755 "$stub_file" || fail "cannot make gh stub executable"
}

run_tag_failure() {
  run_version=$1
  if (cd "$tag_fixture" && GH_HOST=evil.example PATH="$gh_dir:$PATH" sh hack/release/tag-version.sh "$run_version") >/dev/null 2>&1; then
    fail "tag script unexpectedly accepted $run_version"
  fi
  assert_no_tag "$tag_fixture" "$run_version"
}

update_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-update-script-test.XXXXXX") || fail "cannot create update fixture"
copy_release_files "$update_fixture"
add_update_note "$update_fixture"
initialize_fixture "$update_fixture"

if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2) >/dev/null 2>&1; then
  fail "update script accepted malformed version"
fi
[ -z "$(git -C "$update_fixture" status --porcelain --untracked-files=all)" ] || fail "malformed update changed fixture"
if (cd "$update_fixture" && sh hack/release/update-version.sh 0.0.9) >/dev/null 2>&1; then
  fail "update script accepted a downgrade"
fi
[ -z "$(git -C "$update_fixture" status --porcelain --untracked-files=all)" ] || fail "downgrade update changed fixture"
collision_container="$update_fixture/collision-container"
mkdir "$collision_container" || fail "cannot create work-directory collision fixture"
if (cd "$update_fixture" && sh -c 'collision_record="$1"; collision_dir=".git/exactmac-version-update.$$"; mkdir "$collision_dir" || exit 1; printf "%s\\n" sentinel > "$collision_dir/keep"; printf "%s\\n" "$collision_dir" > "$collision_record"; exec sh hack/release/update-version.sh 1.2.3' sh "$collision_container/path") >/dev/null 2>&1; then
  fail "update script ignored a work-directory collision"
fi
IFS= read -r collision_name < "$collision_container/path"
collision_dir="$update_fixture/$collision_name"
assert_contains "$collision_dir/keep" sentinel
rm -rf "$collision_container"
lock_collision="$update_fixture/.git/exactmac-version-update.lock"
mkdir "$lock_collision" || fail "cannot create lock collision fixture"
if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script ignored a lock collision"
fi
[ -d "$lock_collision" ] || fail "update lock collision was removed"
rmdir "$lock_collision"

stale_server="$update_fixture/internal/server/protocol_dispatch.go.stale"
awk '
  {
    line = $0
    sub(/^[ \t]+/, "", line)
    sub(/[ \t]+$/, "", line)
    if (line == "\"serverInfo\":  map[string]any{\"name\": \"exactmac\", \"version\": \"0.1.0\"},") print "\t\t\"serverInfo\":  map[string]any{\"name\": \"exactmac\", \"version\": \"0.0.9\"},"
    else print $0
  }
  END { print "// serverInfo version 0.1.0" }
' "$update_fixture/internal/server/protocol_dispatch.go" > "$stale_server" || fail "cannot create stale server fixture"
mv "$stale_server" "$update_fixture/internal/server/protocol_dispatch.go" || fail "cannot install stale server fixture"
if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted a stale product field"
fi
assert_contains "$update_fixture/cmd/exactmac/main.go" "exactmac 0.1.0"
git -C "$update_fixture" checkout -q -- internal/server/protocol_dispatch.go || fail "cannot restore server fixture"
comment_server="$update_fixture/internal/server/protocol_dispatch.go.comment"
awk '
  {
    line = $0
    sub(/^[ \t]+/, "", line)
    sub(/[ \t]+$/, "", line)
    if (line == "\"serverInfo\":  map[string]any{\"name\": \"exactmac\", \"version\": \"0.1.0\"},") print "\t\t// \"serverInfo\": map[string]any{\"name\": \"exactmac\", \"version\": \"0.1.0\"},"
    else print $0
  }
' "$update_fixture/internal/server/protocol_dispatch.go" > "$comment_server" || fail "cannot create comment-only server fixture"
mv "$comment_server" "$update_fixture/internal/server/protocol_dispatch.go" || fail "cannot install comment-only server fixture"
if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted a comment-only server field"
fi
git -C "$update_fixture" checkout -q -- internal/server/protocol_dispatch.go || fail "cannot restore comment-only server fixture"
python3 - "$update_fixture/skills/exactmac/claude-plugin.json" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
del data["version"]
data["metadata"] = {"version": "0.1.0"}
path.write_text(json.dumps(data, indent=2) + "\n")
PY
if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted nested-only plugin version"
fi
git -C "$update_fixture" checkout -q -- skills/exactmac/claude-plugin.json || fail "cannot restore plugin fixture"
python3 - "$update_fixture/skills/exactmac/claude-plugin.json" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["version"] = float("nan")
path.write_text(json.dumps(data, indent=2) + "\n")
PY
if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted non-standard JSON"
fi
git -C "$update_fixture" checkout -q -- skills/exactmac/claude-plugin.json || fail "cannot restore strict-JSON fixture"
make_decoy="$update_fixture/make/exactmac.mk.decoy"
awk '
  {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line == "EXACTMAC_VERSION        ?= 0.1.0") print "\tprintf \"EXACTMAC_VERSION        ?= 0.1.0\\n\""
    else print $0
  }
' "$update_fixture/make/exactmac.mk" > "$make_decoy" || fail "cannot create Makefile decoy fixture"
mv "$make_decoy" "$update_fixture/make/exactmac.mk" || fail "cannot install Makefile decoy fixture"
if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted a Makefile recipe decoy"
fi
git -C "$update_fixture" checkout -q -- make/exactmac.mk || fail "cannot restore Makefile fixture"
printf '%s\n' '                    "version": "1.0.0",' >> "$update_fixture/internal/server/mcpinitialization_test.go"
if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted an extra independent version"
fi
git -C "$update_fixture" checkout -q -- internal/server/mcpinitialization_test.go || fail "cannot restore independent-version fixture"

if ! (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3); then
  fail "update script rejected valid fixture version"
fi
assert_contains "$update_fixture/cmd/exactmac/main.go" "exactmac 1.2.3"
assert_contains "$update_fixture/internal/server/protocol_dispatch.go" '"version": "1.2.3"'
assert_contains "$update_fixture/make/exactmac.mk" "EXACTMAC_VERSION        ?= 1.2.3"
assert_contains "$update_fixture/skills/exactmac/claude-plugin.json" '"version": "1.2.3"'
assert_contains "$update_fixture/skills/exactmac/SKILL.md" "version: 1.2.3"
assert_contains "$update_fixture/internal/server/mcpinitialization_test.go" '"version": "1.0.0"'
assert_count "$update_fixture/internal/server/mcpinitialization_test.go" '1.0.0' 4
assert_count "$update_fixture/internal/server/mcpinitialization_test.go" '1.2.3' 3
assert_count "$update_fixture/make/exactmac.mk" "EXACTMAC_BUILD_VERSION  ?= 1" 1
assert_count "$update_fixture/internal/server/protocol_dispatch.go" "2025-11-25" 2
assert_count "$update_fixture/internal/server/protocol_dispatch.go" "mcpProtocolVersionCurrent" 4
assert_contains "$update_fixture/CHANGELOG.md" "## [1.2.3] - "
assert_contains "$update_fixture/CHANGELOG.md" "[1.2.3]:"
assert_contains "$update_fixture/CHANGELOG.md" "compare/v1.2.3...HEAD"
assert_contains "$update_fixture/make/exactmac.mk" "EXACTMAC_BUILD_VERSION  ?= 1"
assert_contains "$update_fixture/internal/server/protocol_dispatch.go" "mcpProtocolVersionCurrent"
update_diff=$(git -C "$update_fixture" diff --binary | cksum)
if (cd "$update_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted an already released target"
fi
update_diff_after=$(git -C "$update_fixture" diff --binary | cksum)
[ "$update_diff" = "$update_diff_after" ] || fail "existing-target update failure changed fixture"

empty_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-empty-script-test.XXXXXX") || fail "cannot create empty fixture"
copy_release_files "$empty_fixture"
initialize_fixture "$empty_fixture"
empty_before=$(git -C "$empty_fixture" status --porcelain --untracked-files=all)
if (cd "$empty_fixture" && sh hack/release/update-version.sh 9.9.9) >/dev/null 2>&1; then
  fail "update script accepted empty Unreleased section"
fi
empty_after=$(git -C "$empty_fixture" status --porcelain --untracked-files=all)
[ "$empty_before" = "$empty_after" ] || fail "empty-Unreleased failure changed fixture"
rm -rf "$empty_fixture"

symlink_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-symlink-script-test.XXXXXX") || fail "cannot create symlink fixture"
copy_release_files "$symlink_fixture"
add_update_note "$symlink_fixture"
initialize_fixture "$symlink_fixture"
cp "$symlink_fixture/CHANGELOG.md" "$symlink_fixture/external.txt" || fail "cannot create symlink target"
rm "$symlink_fixture/CHANGELOG.md"
ln -s "$symlink_fixture/external.txt" "$symlink_fixture/CHANGELOG.md"
if (cd "$symlink_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script followed a destination symlink"
fi
assert_contains "$symlink_fixture/external.txt" "## [Unreleased]"
assert_contains "$symlink_fixture/cmd/exactmac/main.go" "exactmac 0.1.0"
rm -rf "$symlink_fixture"

url_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-url-script-test.XXXXXX") || fail "cannot create URL fixture"
copy_release_files "$url_fixture"
add_update_note "$url_fixture"
initialize_fixture "$url_fixture"
url_changelog_tmp="$url_fixture/CHANGELOG.fixture"
awk '{ if ($0 == "[Unreleased]: https://github.com/joeycumines/ExactMac/compare/v0.1.0...HEAD") print "[Unreleased]: https://github.com//compare/v0.1.0...HEAD"; else print }' "$url_fixture/CHANGELOG.md" > "$url_changelog_tmp" || fail "cannot create malformed URL fixture"
mv "$url_changelog_tmp" "$url_fixture/CHANGELOG.md" || fail "cannot install malformed URL fixture"
if (cd "$url_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted a malformed changelog URL"
fi
assert_contains "$url_fixture/cmd/exactmac/main.go" "exactmac 0.1.0"
git -C "$url_fixture" checkout -q -- CHANGELOG.md || fail "cannot restore URL fixture changelog"
url_changelog_tmp="$url_fixture/CHANGELOG.dot-segment"
awk '{ if ($0 == "[Unreleased]: https://github.com/joeycumines/ExactMac/compare/v0.1.0...HEAD") print "[Unreleased]: https://github.com/../../compare/v0.1.0...HEAD"; else print }' "$url_fixture/CHANGELOG.md" > "$url_changelog_tmp" || fail "cannot create dot-segment URL fixture"
mv "$url_changelog_tmp" "$url_fixture/CHANGELOG.md" || fail "cannot install dot-segment URL fixture"
if (cd "$url_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted a dot-segment changelog URL"
fi
assert_contains "$url_fixture/cmd/exactmac/main.go" "exactmac 0.1.0"
rm -rf "$url_fixture"

readonly_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-readonly-script-test.XXXXXX") || fail "cannot create read-only fixture"
copy_release_files "$readonly_fixture"
add_update_note "$readonly_fixture"
initialize_fixture "$readonly_fixture"
chmod 444 "$readonly_fixture/CHANGELOG.md"
if (cd "$readonly_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted a read-only destination"
fi
assert_contains "$readonly_fixture/cmd/exactmac/main.go" "exactmac 0.1.0"
chmod 644 "$readonly_fixture/CHANGELOG.md"
rm -rf "$readonly_fixture"

history_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-history-script-test.XXXXXX") || fail "cannot create history fixture"
copy_release_files "$history_fixture"
add_update_note "$history_fixture"
initialize_fixture "$history_fixture"
history_tmp="$history_fixture/CHANGELOG.history"
awk '
  /^## \[0\.1\.0\]/ {
    print "## [9.9.9] - 2026-09-24"
    print ""
    print "### Added"
    print "- Future fixture release."
    print ""
  }
  /^\[0\.1\.0\]:/ {
    print "[9.9.9]: https://github.com/joeycumines/ExactMac/releases/tag/v9.9.9"
  }
  { print }
' "$history_fixture/CHANGELOG.md" > "$history_tmp" || fail "cannot create non-monotonic history fixture"
mv "$history_tmp" "$history_fixture/CHANGELOG.md" || fail "cannot install non-monotonic history fixture"
if (cd "$history_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script accepted a non-latest changelog history"
fi
assert_contains "$history_fixture/cmd/exactmac/main.go" "exactmac 0.1.0"
rm -rf "$history_fixture"

fence_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-fence-script-test.XXXXXX") || fail "cannot create fence fixture"
copy_release_files "$fence_fixture"
add_update_note "$fence_fixture"
initialize_fixture "$fence_fixture"
fence_tmp="$fence_fixture/CHANGELOG.fence"
awk '
  { print }
  $0 == "## [Unreleased]" {
    print ""
    print "````markdown"
    print "```"
    print "## [9.9.9] - 2026-09-24"
    print "[9.9.9]: https://evil.example/releases/tag/v9.9.9"
    print "[Unreleased]: https://evil.example/compare/v9.9.9...HEAD"
    print "```"
    print "````"
  }
' "$fence_fixture/CHANGELOG.md" > "$fence_tmp" || fail "cannot create fenced changelog fixture"
mv "$fence_tmp" "$fence_fixture/CHANGELOG.md" || fail "cannot install fenced changelog fixture"
if ! (cd "$fence_fixture" && sh hack/release/update-version.sh 1.2.3); then
  fail "update script rejected valid fenced changelog content"
fi
assert_contains "$fence_fixture/CHANGELOG.md" "## [9.9.9] - 2026-09-24"
assert_contains "$fence_fixture/CHANGELOG.md" "[9.9.9]: https://evil.example/releases/tag/v9.9.9"
rm -rf "$fence_fixture"

parent_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-parent-script-test.XXXXXX") || fail "cannot create parent-symlink fixture"
copy_release_files "$parent_fixture"
add_update_note "$parent_fixture"
initialize_fixture "$parent_fixture"
mv "$parent_fixture/cmd/exactmac" "$parent_fixture/external-exactmac" || fail "cannot move parent directory"
ln -s "$parent_fixture/external-exactmac" "$parent_fixture/cmd/exactmac" || fail "cannot create parent symlink"
if (cd "$parent_fixture" && sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script followed a parent symlink"
fi
assert_contains "$parent_fixture/external-exactmac/main.go" "exactmac 0.1.0"
rm -rf "$parent_fixture"

rollback_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-rollback-script-test.XXXXXX") || fail "cannot create rollback fixture"
copy_release_files "$rollback_fixture"
add_update_note "$rollback_fixture"
printf '%s\n' 'preexisting temporary-looking file' > "$rollback_fixture/CHANGELOG.md.exactmac-version.keep"
initialize_fixture "$rollback_fixture"
failbin=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-failbin.XXXXXX") || fail "cannot create failure injector"
git_real=$(command -v git) || fail "cannot locate git for failure injector"
# The failure injector intentionally contains literal shell expansions.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'if [ "$1" = "-C" ]; then shift 2; fi' 'if [ "$1" = apply ] && [ "$2" != --check ] && [ "$2" != --reverse ]; then' '  case "$*" in' '    *internal/server/protocol_dispatch.go.patch) exit 1 ;;' '  esac' 'fi' "exec \"$git_real\" \"\$@\"" > "$failbin/git" || fail "cannot write failure injector"
chmod 755 "$failbin/git" || fail "cannot make failure injector executable"
if (cd "$rollback_fixture" && PATH="$failbin:$PATH" sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script ignored injected installation failure"
fi
[ -z "$(git -C "$rollback_fixture" status --porcelain --untracked-files=all)" ] || fail "rollback left tracked changes"
assert_contains "$rollback_fixture/CHANGELOG.md.exactmac-version.keep" "preexisting temporary-looking file"
[ ! -e "$rollback_fixture/.git/exactmac-version-update.lock" ] || fail "rollback left update lock"
for rollback_temp in "$rollback_fixture"/.git/exactmac-version-update.*; do
  [ ! -e "$rollback_temp" ] || fail "rollback left work directory $rollback_temp"
done
for rollback_file in \
  "$rollback_fixture/cmd/exactmac/main.go.exactmac-version."* \
  "$rollback_fixture/internal/server/protocol_dispatch.go.exactmac-version."*; do
  [ ! -e "$rollback_file" ] || fail "rollback left temporary file $rollback_file"
done
rm -rf "$rollback_fixture"
rm -rf "$failbin"

race_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-race-script-test.XXXXXX") || fail "cannot create race fixture"
copy_release_files "$race_fixture"
add_update_note "$race_fixture"
initialize_fixture "$race_fixture"
racebin=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-racebin.XXXXXX") || fail "cannot create race injector"
git_real=$(command -v git) || fail "cannot locate git for race injector"
# The race injector intentionally contains literal shell expansions.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'if [ "$1" = "-C" ]; then shift 2; fi' 'if [ "$1" = apply ] && [ "$2" != --check ] && [ "$2" != --reverse ]; then' '  case "$*" in' '    *cmd/exactmac/main.go.patch)' '      if [ ! -e "'"$race_fixture"'/race-seen" ]; then' '        : > "'"$race_fixture"'/race-seen"' '        printf "%s\\n" "// concurrent fixture edit" >> "'"$race_fixture"'/internal/server/protocol_dispatch.go"' '      fi' '      ;;' '  esac' 'fi' "exec \"$git_real\" \"\$@\"" > "$racebin/git" || fail "cannot write race injector"
chmod 755 "$racebin/git" || fail "cannot make race injector executable"
if (cd "$race_fixture" && PATH="$racebin:$PATH" sh hack/release/update-version.sh 1.2.3) >/dev/null 2>&1; then
  fail "update script ignored a concurrent source edit"
fi
assert_contains "$race_fixture/internal/server/protocol_dispatch.go" "// concurrent fixture edit"
if grep -F "1.2.3" "$race_fixture/cmd/exactmac/main.go" >/dev/null 2>&1; then
  fail "concurrent-edit rollback left an installed product version"
fi
rm -rf "$race_fixture"
rm -rf "$racebin"

# Tag fixtures use an external gh stub so changing CI state never dirties the
# repository being tested.
gh_dir=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-gh-stub.XXXXXX") || fail "cannot create gh stub directory"
tag_fixture=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-tag-script-test.XXXXXX") || fail "cannot create tag fixture"
copy_release_files "$tag_fixture"
initialize_fixture "$tag_fixture"
write_gh_stub success

git -C "$tag_fixture" remote set-url origin https://github.com/example/other.git
run_tag_failure 0.1.0
git -C "$tag_fixture" remote set-url origin https://github.com/joeycumines/ExactMac.git
git -C "$tag_fixture" config --add remote.origin.pushurl https://github.com/joeycumines/ExactMac.git
git -C "$tag_fixture" config --add remote.origin.pushurl https://evil.example/other.git
run_tag_failure 0.1.0
git -C "$tag_fixture" config --unset-all remote.origin.pushurl || fail "cannot restore fixture push URL"

git -C "$tag_fixture" tag -a v9.9.9 -m future HEAD
run_tag_failure 0.1.0
git -C "$tag_fixture" tag -d v9.9.9 >/dev/null || fail "cannot remove future fixture tag"

if ! (cd "$tag_fixture" && PATH="$gh_dir:$PATH" sh hack/release/tag-version.sh 0.1.0); then
  fail "tag script rejected valid fixture state"
fi
[ "$(git -C "$tag_fixture" cat-file -t v0.1.0)" = "tag" ] || fail "tag script did not create an annotated tag"
[ "$(git -C "$tag_fixture" rev-parse 'v0.1.0^{commit}')" = "$(git -C "$tag_fixture" rev-parse HEAD)" ] || fail "fixture tag points at the wrong commit"
git -C "$tag_fixture" tag -d v0.1.0 >/dev/null || fail "cannot remove fixture tag"

gitfailbin=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-git-failbin.XXXXXX") || fail "cannot create git failure injector"
git_real=$(command -v git) || fail "cannot locate git for failure injector"
# The git failure injector intentionally contains literal shell expansions.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'case " $* " in' '  *" cat-file -t "*) printf "%s\\n" commit; exit 0 ;;' '  *" update-ref "*)' '    "$git_real" "$@"' '    exit 1' '    ;;' 'esac' "exec \"$git_real\" \"\$@\"" > "$gitfailbin/git" || fail "cannot write git failure injector"
chmod 755 "$gitfailbin/git" || fail "cannot make git failure injector executable"
if (cd "$tag_fixture" && GH_HOST=evil.example PATH="$gitfailbin:$gh_dir:$PATH" sh hack/release/tag-version.sh 0.1.0) >/dev/null 2>&1; then
  fail "tag script ignored a failed postcondition"
fi
assert_no_tag "$tag_fixture" 0.1.0
if (cd "$tag_fixture" && GH_HOST=evil.example PATH="$gitfailbin:$gh_dir:$PATH" sh hack/release/tag-version.sh 0.1.0) >/dev/null 2>&1; then
  fail "tag script ignored a failed tag command"
fi
assert_no_tag "$tag_fixture" 0.1.0
rm -rf "$gitfailbin"
gitfailbin=

signalbin=$(mktemp -d "${TMPDIR:-/tmp}/exactmac-signalbin.XXXXXX") || fail "cannot create signal injector"
git_real=$(command -v git) || fail "cannot locate git for signal injector"
# The signal injector intentionally contains literal shell expansions.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'case " $* " in' '  *" update-ref "*)' '    "$git_real" "$@"' '    kill -TERM "$PPID"' '    sleep 1' '    exit 1' '    ;;' 'esac' "exec \"$git_real\" \"\$@\"" > "$signalbin/git" || fail "cannot write signal injector"
chmod 755 "$signalbin/git" || fail "cannot make signal injector executable"
if (cd "$tag_fixture" && GH_HOST=evil.example PATH="$signalbin:$gh_dir:$PATH" sh hack/release/tag-version.sh 0.1.0) >/dev/null 2>&1; then
  fail "tag script ignored termination during creation"
fi
assert_no_tag "$tag_fixture" 0.1.0
[ ! -e "$tag_fixture/.git/exactmac-tag-version.lock" ] || fail "signal cleanup left tag lock"
rm -rf "$signalbin"
signalbin=

stale_cli="$tag_fixture/cmd/exactmac/main.go.stale"
awk '
  {
    line = $0
    sub(/^[ \t]+/, "", line)
    sub(/[ \t]+$/, "", line)
    if (line == "fmt.Fprintln(os.Stderr, \"exactmac 0.1.0\")") print "\t\tfmt.Fprintln(os.Stderr, \"exactmac 0.0.9\")"
    else print $0
  }
  END { print "// exactmac 0.1.0" }
' "$tag_fixture/cmd/exactmac/main.go" > "$stale_cli" || fail "cannot create stale CLI fixture"
mv "$stale_cli" "$tag_fixture/cmd/exactmac/main.go" || fail "cannot install stale CLI fixture"
run_tag_failure 0.1.0
git -C "$tag_fixture" checkout -q -- cmd/exactmac/main.go || fail "cannot restore CLI fixture"

evil_changelog_tmp="$tag_fixture/CHANGELOG.evil"
awk '{ if ($0 == "[0.1.0]: https://github.com/joeycumines/ExactMac/releases/tag/v0.1.0") print "[0.1.0]: https://evil.example/releases/tag/v0.1.0"; else print }' "$tag_fixture/CHANGELOG.md" > "$evil_changelog_tmp" || fail "cannot create evil-link fixture"
mv "$evil_changelog_tmp" "$tag_fixture/CHANGELOG.md" || fail "cannot install evil-link fixture"
run_tag_failure 0.1.0
git -C "$tag_fixture" checkout -q -- CHANGELOG.md || fail "cannot restore changelog fixture"

printf '%s\n' untracked > "$tag_fixture/untracked-file"
run_tag_failure 0.1.0
rm "$tag_fixture/untracked-file"

git -C "$tag_fixture" checkout -q -b feature
run_tag_failure 0.1.0
git -C "$tag_fixture" checkout -q main

base_sha=$(git -C "$tag_fixture" rev-parse HEAD)
printf '%s\n' second > "$tag_fixture/second-commit.txt"
git -C "$tag_fixture" add second-commit.txt
GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
  GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
  git -C "$tag_fixture" commit -q -m second
current_sha=$(git -C "$tag_fixture" rev-parse HEAD)
git -C "$tag_fixture" update-ref refs/remotes/origin/main "$base_sha"
run_tag_failure 0.1.0
git -C "$tag_fixture" update-ref refs/remotes/origin/main "$current_sha"

write_gh_stub failure
run_tag_failure 0.1.0
write_gh_stub success "$(git -C "$tag_fixture" rev-parse HEAD)" deadbeef
run_tag_failure 0.1.0
write_gh_stub success deadbeef
run_tag_failure 0.1.0
write_gh_stub success
run_tag_failure 0.2.0
run_tag_failure 1.2

git -C "$tag_fixture" tag -a v0.1.0 -m existing HEAD
if (cd "$tag_fixture" && PATH="$gh_dir:$PATH" sh hack/release/tag-version.sh 0.1.0) >/dev/null 2>&1; then
  fail "tag script accepted an existing tag"
fi

printf '%s\n' 'release script fixture tests passed'
