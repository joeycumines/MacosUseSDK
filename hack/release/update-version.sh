#!/bin/sh

# Update the product version across the tracked release surfaces. All output is
# built and validated before a transactional installation begins.

# shellcheck disable=SC1091
# shellcheck source=release-version-common.sh
script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P) || exit 1
. "$script_dir/release-version-common.sh" || exit 1
repo_root=$(CDPATH='' cd -P "$script_dir/../.." && pwd -P) || exit 1
cd "$repo_root" || exit 1
umask 077

install_started=false
work_dir=
work_owned=false
work_created=false
work_token="$$-$(date +%s)"
lock_dir=
lock_owned=false
lock_created=false
lock_token="$$-$(date +%s)"
cleanup() {
  if [ "$work_owned" = true ] && [ -n "$work_dir" ] && [ -d "$work_dir" ] && [ ! -L "$work_dir" ] && [ -f "$work_dir/owner" ]; then
    IFS= read -r cleanup_work_token < "$work_dir/owner" || cleanup_work_token=
    if [ "$cleanup_work_token" = "$work_token" ]; then
      rm -rf "$work_dir"
    fi
  elif [ "$work_created" = true ] && [ -n "$work_dir" ] && [ -d "$work_dir" ] && [ ! -L "$work_dir" ]; then
    rmdir "$work_dir" 2>/dev/null || :
  fi
  if [ "$lock_owned" = true ] && [ -n "$lock_dir" ] && [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] && [ -f "$lock_dir/owner" ]; then
    IFS= read -r cleanup_lock_token < "$lock_dir/owner" || cleanup_lock_token=
    if [ "$cleanup_lock_token" = "$lock_token" ]; then
      rm -f "$lock_dir/owner"
      rmdir "$lock_dir" 2>/dev/null || :
    fi
  elif [ "$lock_created" = true ] && [ -n "$lock_dir" ] && [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
    rmdir "$lock_dir" 2>/dev/null || :
  fi
}
rollback() {
  return 0
}
fail() {
  if [ "$install_started" = true ]; then
    rollback
  fi
  printf 'update-version.sh: %s\n' "$1" >&2
  exit 1
}
trap cleanup 0
trap 'fail "interrupted"' 1 2 15

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf 'Usage: %s X.Y.Z\n' "$0" >&2
  exit 1
fi

version=$1
if ! release_validate_semver "$version"; then
  fail "version must be a SemVer X.Y.Z without leading zeroes"
fi

command -v git >/dev/null 2>&1 || fail "git is required"
git_dir=$(git rev-parse --absolute-git-dir) || fail "cannot resolve Git directory"
lock_dir="$git_dir/exactmac-version-update.lock"
setup_signal_pending=false
trap 'setup_signal_pending=true' 1 2 15
if ! mkdir "$lock_dir" 2>/dev/null; then
  trap 'fail "interrupted"' 1 2 15
  fail "another product-version update is already running"
fi
lock_created=true
printf '%s\n' "$lock_token" > "$lock_dir/owner" || {
  trap 'fail "interrupted"' 1 2 15
  fail "cannot mark update lock"
}
lock_owned=true
trap 'fail "interrupted"' 1 2 15
if [ "$setup_signal_pending" = true ]; then
  fail "interrupted while acquiring update lock"
fi

command -v gmake >/dev/null 2>&1 || fail "gmake is required to read the product version"
current_version=$(env -u EXACTMAC_VERSION gmake -f "$repo_root/make/exactmac.mk" -pn 2>/dev/null | awk -F ' = ' '$1 == "EXACTMAC_VERSION" && !found { print $2; found = 1 } END { if (!found) exit 1 }') || fail "cannot determine current product version from make/exactmac.mk"
if ! release_validate_semver "$current_version"; then
  fail "make/exactmac.mk contains an invalid product version"
fi
if ! release_version_is_increasing "$current_version" "$version"; then
  fail "target version must be greater than the current product version"
fi
if ! release_require_update_position "$repo_root" "$current_version" "$version"; then
  fail "release history is not monotonic or the target does not follow the latest release"
fi
if ! release_require_product_surfaces "$repo_root" "$current_version"; then
  fail "known product-version surfaces are inconsistent or incomplete"
fi

product_files="cmd/exactmac/main.go internal/server/protocol_dispatch.go internal/server/mcpresources_test.go internal/server/mcpinitialization_test.go internal/server/mcppromptslist_test.go make/exactmac.mk skills/exactmac/claude-plugin.json skills/exactmac/SKILL.md CHANGELOG.md"
for product_file in $product_files; do
  if ! release_preflight_destination "$repo_root/$product_file" "$repo_root"; then
    fail "destination is missing, not writable, or is a symlink: $product_file"
  fi
done

unreleased_body=$(awk '
  function fence_info(line, closing,    token, rest) {
    if (!match(line, /^[ ]{0,3}(```+|~~~+)/)) return ""
    token = substr(line, RSTART, RLENGTH)
    rest = substr(line, RSTART + RLENGTH)
    if (closing) {
      if (rest !~ /^[ \t]*$/) return ""
    } else if (substr(token, 1, 1) == "`" && index(rest, "`") > 0) {
      return "invalid"
    }
    return substr(token, 1, 1) ":" length(token)
  }
  {
    info = fence_info($0, fence != "")
    if (info == "invalid") exit 1
    if (fence == "") {
      if (info != "") {
        split(info, fence_parts, ":")
        fence_char = fence_parts[1]
        fence_length = fence_parts[2]
        fence = "open"
        if (inside) print
        next
      }
    } else {
      if (info != "") {
        split(info, fence_parts, ":")
        if (fence_parts[1] == fence_char && fence_parts[2] + 0 >= fence_length + 0) fence = ""
      }
      if (inside) print
      next
    }
    if (inside && $0 ~ /^## \[/) exit
    if ($0 == "## [Unreleased]") { inside = 1; next }
    if (inside) print
  }
  END { if (fence != "") exit 1 }
' "$repo_root/CHANGELOG.md") || fail "cannot read the Unreleased section"
if [ -z "$(printf '%s' "$unreleased_body" | tr -d '[:space:]')" ]; then
  fail "Unreleased has no content to promote; add release notes first"
fi
# shellcheck disable=SC2016
if ! printf '%s\n' "$unreleased_body" | python3 -c '
import re
import sys

in_comment = False
fence_char = ""
fence_length = 0
found = False
for line in sys.stdin:
    visible = []
    position = 0
    while True:
        if in_comment:
            end = line.find("-->", position)
            if end < 0:
                position = len(line)
                break
            position = end + 3
            in_comment = False
            continue
        start = line.find("<!--", position)
        if start < 0:
            visible.append(line[position:])
            break
        visible.append(line[position:start])
        position = start + 4
        in_comment = True
    text = "".join(visible)
    fence = re.match(r"^[ ]{0,3}(`{3,}|~{3,})(.*)$", text)
    if fence_char:
        if fence:
            marker = fence.group(1)
            if marker[0] == fence_char and len(marker) >= fence_length and not fence.group(2).strip():
                fence_char = ""
                fence_length = 0
        continue
    if fence:
        marker = fence.group(1)
        info = fence.group(2)
        if marker[0] == "`" and "`" in info:
            raise SystemExit(1)
        fence_char = marker[0]
        fence_length = len(marker)
        continue
    if text.strip():
        found = True
if in_comment or fence_char or not found:
    raise SystemExit(1)
'; then
  fail "Unreleased has no substantive release notes to promote"
fi

repo_url=$(release_changelog_repo_url "$repo_root/CHANGELOG.md") || fail "Unreleased link is not a valid GitHub compare URL"
release_date=$(date -u '+%Y-%m-%d') || fail "cannot determine the release date"
case "$release_date" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) fail "date did not return YYYY-MM-DD" ;;
esac

product_files="cmd/exactmac/main.go internal/server/protocol_dispatch.go internal/server/mcpresources_test.go internal/server/mcpinitialization_test.go internal/server/mcppromptslist_test.go make/exactmac.mk skills/exactmac/claude-plugin.json skills/exactmac/SKILL.md CHANGELOG.md"
stage_root=
source_manifest=
work_dir="$git_dir/exactmac-version-update.$$"
setup_signal_pending=false
trap 'setup_signal_pending=true' 1 2 15
if ! mkdir "$work_dir" 2>/dev/null; then
  trap 'fail "interrupted"' 1 2 15
  fail "cannot create a temporary directory"
fi
work_created=true
printf '%s\n' "$work_token" > "$work_dir/owner" || {
  trap 'fail "interrupted"' 1 2 15
  fail "cannot mark update work directory"
}
work_owned=true
trap 'fail "interrupted"' 1 2 15
if [ "$setup_signal_pending" = true ]; then
  fail "interrupted while creating update work directory"
fi
tmp_dir=$work_dir
stage_root="$tmp_dir/tree"
source_manifest="$tmp_dir/source-manifest"
: > "$source_manifest" || fail "cannot create source manifest"

for product_file in $product_files; do
  source_digest=$(git -C "$repo_root" hash-object "$repo_root/$product_file") || fail "cannot hash source $product_file"
  printf '%s %s\n' "$source_digest" "$product_file" >> "$source_manifest" || fail "cannot record source $product_file"
done

verify_source_file() {
  verify_relative=$1
  verify_expected=$(awk -v path="$verify_relative" '$2 == path { print $1; exit }' "$source_manifest") || return 1
  [ -n "$verify_expected" ] || return 1
  verify_actual=$(git -C "$repo_root" hash-object "$repo_root/$verify_relative") || return 1
  [ "$verify_actual" = "$verify_expected" ]
}

stage_copy() {
  stage_source="$repo_root/$1"
  stage_destination="$stage_root/$1"
  stage_directory=$(dirname "$stage_destination")
  mkdir -p "$stage_directory" || fail "cannot create staging directory for $1"
  cp -p "$stage_source" "$stage_destination" || fail "cannot stage $1"
}

for product_file in $product_files; do
  stage_copy "$product_file"
done

stage_cli() {
  stage_file="$stage_root/cmd/exactmac/main.go"
  stage_tmp="$stage_file.stage"
  if ! awk -v old="$current_version" -v new="$version" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "fmt.Fprintln(os.Stderr, \"exactmac " old "\")") {
        prefix = $0
        sub(/[^ \t].*$/, "", prefix)
        print prefix "fmt.Fprintln(os.Stderr, \"exactmac " new "\")"
        found++
      } else {
        print $0
      }
    }
    END { if (found != 1) exit 1 }
  ' "$stage_file" > "$stage_tmp"; then
    fail "could not stage the CLI version"
  fi
  mv "$stage_tmp" "$stage_file" || fail "could not install staged CLI version"
}

stage_make() {
  stage_file="$stage_root/make/exactmac.mk"
  stage_tmp="$stage_file.stage"
  if ! awk -v old="$current_version" -v new="$version" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (index(line, "EXACTMAC_VERSION") == 1) {
        found++
        if (line != "EXACTMAC_VERSION        ?= " old) bad = 1
        else print "EXACTMAC_VERSION        ?= " new
      } else {
        print $0
      }
    }
    END { if (found != 1 || bad) exit 1 }
  ' "$stage_file" > "$stage_tmp"; then
    fail "could not stage EXACTMAC_VERSION"
  fi
  mv "$stage_tmp" "$stage_file" || fail "could not install staged EXACTMAC_VERSION"
}

stage_json_version() {
  stage_file="$stage_root/skills/exactmac/claude-plugin.json"
  stage_tmp="$stage_file.stage"
  if ! awk -v old="$current_version" -v new="$version" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "\"version\": \"" old "\"," || line == "\"version\": \"" old "\"") {
        prefix = $0
        sub(/[^ \t].*$/, "", prefix)
        if (line == "\"version\": \"" old "\",") print prefix "\"version\": \"" new "\","
        else print prefix "\"version\": \"" new "\""
        found++
      } else {
        print $0
      }
    }
    END { if (found != 1) exit 1 }
  ' "$stage_file" > "$stage_tmp"; then
    fail "could not stage plugin version"
  fi
  mv "$stage_tmp" "$stage_file" || fail "could not install staged plugin version"
}

stage_skill_version() {
  stage_file="$stage_root/skills/exactmac/SKILL.md"
  stage_tmp="$stage_file.stage"
  if ! awk -v old="$current_version" -v new="$version" '
    {
      raw = $0
      line = raw
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (NR == 1 && line == "---") { frontmatter = 1; print $0 }
      else if (frontmatter == 1 && line == "---") { frontmatter = 2; print $0 }
      else if (frontmatter == 1 && line == "metadata:") { metadata = 1; print $0 }
      else if (metadata == 1 && raw ~ /^  version: /) {
        value = raw
        sub(/^  version:[[:space:]]*/, "", value)
        sub(/[[:space:]]$/, "", value)
        if (value != old) bad = 1
        else {
          prefix = raw
          sub(/[^ \t].*$/, "", prefix)
          print prefix "version: " new
          found++
        }
      } else if (metadata == 1 && index(line, "version:") == 1) bad = 1
      else print $0
    }
    END { if (frontmatter != 2 || !metadata || found != 1 || bad) exit 1 }
  ' "$stage_file" > "$stage_tmp"; then
    fail "could not stage skill version"
  fi
  mv "$stage_tmp" "$stage_file" || fail "could not install staged skill version"
}

stage_server_info() {
  stage_relative=$1
  stage_expected=$2
  stage_file="$stage_root/$stage_relative"
  stage_tmp="$stage_file.stage"
  if ! awk -v old="$current_version" -v new="$version" -v expected="$stage_expected" '
    function replace_server_value(value, before, after, position, suffix, result, matched, found_version, matched_prefix) {
      result = ""
      suffix = value
      replacement_count = 0
      while (match(suffix, /"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/)) {
        matched = substr(suffix, RSTART, RLENGTH)
        found_version = matched
        sub(/^.*:[[:space:]]*"/, "", found_version)
        sub(/"$/, "", found_version)
        if (found_version == before) {
          matched_prefix = matched
          sub(/"[0-9]+\.[0-9]+\.[0-9]+"$/, "", matched_prefix)
          matched = matched_prefix "\"" after "\""
        }
        result = result substr(suffix, 1, RSTART - 1) matched
        suffix = substr(suffix, RSTART + RLENGTH)
        replacement_count++
      }
      if (replacement_count > 1) invalid = 1
      return result suffix
    }
    {
      transformed = $0
      comment_line = $0
      sub(/^[ \t]+/, "", comment_line)
      if (comment_line ~ /^(\/\/|\*|\/\*)/) {
        print transformed
        next
      }
      if ($0 ~ /"serverInfo"[[:space:]]*:/) {
        transformed = replace_server_value($0, old, new)
        if (replacement_count > 0) {
          found += replacement_count
          in_server_info = 0
        } else {
          in_server_info = 1
        }
      } else if (in_server_info) {
        transformed = replace_server_value($0, old, new)
        if (replacement_count > 0) {
          found += replacement_count
          in_server_info = 0
        }
      }
      print transformed
    }
    END { if (found != expected || in_server_info || invalid) exit 1 }
  ' "$stage_file" > "$stage_tmp"; then
    fail "could not stage server version in $stage_relative"
  fi
  mv "$stage_tmp" "$stage_file" || fail "could not install staged server version in $stage_relative"
}

stage_cli
stage_server_info "internal/server/protocol_dispatch.go" 1
stage_server_info "internal/server/mcpresources_test.go" 1
stage_server_info "internal/server/mcpinitialization_test.go" 3
stage_server_info "internal/server/mcppromptslist_test.go" 1
stage_json_version
stage_skill_version
stage_make

stage_changelog="$stage_root/CHANGELOG.md"
stage_changelog_tmp="$stage_changelog.stage"
if ! awk -v target="$version" -v date="$release_date" -v repo="$repo_url" '
  function has_text(value) { return value ~ /[^[:space:]]/ }
  function emit_release(value) {
    print "## [" target "] - " date
    printf "%s", value
    if (value !~ /\n$/) print ""
  }
  function fence_info(line, closing,    token, rest) {
    if (!match(line, /^[ ]{0,3}(```+|~~~+)/)) return ""
    token = substr(line, RSTART, RLENGTH)
    rest = substr(line, RSTART + RLENGTH)
    if (closing) {
      if (rest !~ /^[ \t]*$/) return ""
    } else if (substr(token, 1, 1) == "`" && index(rest, "`") > 0) {
      return "invalid"
    }
    return substr(token, 1, 1) ":" length(token)
  }
  {
    info = fence_info($0, fence != "")
    if (info == "invalid") exit 1
    if (fence == "") {
      if (info != "") {
        split(info, fence_parts, ":")
        fence_char = fence_parts[1]
        fence_length = fence_parts[2]
        fence = "open"
        print
        next
      }
    } else {
      if (info != "") {
        split(info, fence_parts, ":")
        if (fence_parts[1] == fence_char && fence_parts[2] + 0 >= fence_length + 0) fence = ""
      }
      print
      next
    }
    if ($0 == "## [Unreleased]") {
      if (found_unreleased) invalid = 1
      found_unreleased = 1
      in_unreleased = 1
      unreleased_text = ""
      print
      next
    }
    if (in_unreleased && $0 ~ /^## \[/) {
      if (!has_text(unreleased_text)) invalid = 1
      else emit_release(unreleased_text)
      in_unreleased = 0
    }
    if (in_unreleased) {
      unreleased_text = unreleased_text $0 "\n"
      next
    }
    if (index($0, "[" target "]:") == 1) invalid = 1
    if ($0 ~ /^\[Unreleased\]: /) {
      print "[Unreleased]: " repo "/compare/v" target "...HEAD"
      print "[" target "]: " repo "/releases/tag/v" target
      wrote_link = 1
      next
    }
    print
  }
  END {
    if (in_unreleased) {
      if (!has_text(unreleased_text)) invalid = 1
      else emit_release(unreleased_text)
    }
     if (!found_unreleased || !wrote_link || invalid || fence != "" || fence_error) exit 1
  }
' "$stage_changelog" > "$stage_changelog_tmp"; then
  fail "could not stage CHANGELOG.md"
fi
mv "$stage_changelog_tmp" "$stage_changelog" || fail "could not install staged CHANGELOG.md"

if ! release_require_product_surfaces "$stage_root" "$version"; then
  fail "staged product-version surfaces are inconsistent"
fi
expected_unreleased="[Unreleased]: $repo_url/compare/v$version...HEAD"
expected_release_link="[$version]: $repo_url/releases/tag/v$version"
[ "$(release_exact_line_count "$stage_root/CHANGELOG.md" "$expected_unreleased")" -eq 1 ] || fail "staged Unreleased link is invalid"
[ "$(release_exact_line_count "$stage_root/CHANGELOG.md" "$expected_release_link")" -eq 1 ] || fail "staged release link is invalid"

patch_root="$tmp_dir/patches"
mkdir -p "$patch_root" || fail "cannot create patch staging directory"

make_patch() {
  patch_relative=$1
  patch_path="$patch_root/$patch_relative.patch"
  patch_directory=$(dirname "$patch_path")
  mkdir -p "$patch_directory" || return 1
  if diff -u --label "a/$patch_relative" --label "b/$patch_relative" "$repo_root/$patch_relative" "$stage_root/$patch_relative" > "$patch_path"; then
    return 1
  else
    patch_diff_status=$?
    [ "$patch_diff_status" -eq 1 ] || return 1
  fi
  return 0
}

for product_file in $product_files; do
  make_patch "$product_file" || fail "could not create update patch for $product_file"
done

applied_cli=false
applied_server=false
applied_resources=false
applied_initialization=false
applied_prompts=false
applied_make=false
applied_plugin=false
applied_skill=false
applied_changelog=false
install_started=true
rollback_patch() {
  rollback_relative=$1
  rollback_patch_path="$patch_root/$rollback_relative.patch"
  if ! git -C "$repo_root" apply --reverse --check --whitespace=nowarn "$rollback_patch_path"; then
    return 2
  fi
  if ! git -C "$repo_root" apply --reverse --whitespace=nowarn "$rollback_patch_path"; then
    return 1
  fi
  return 0
}

rollback() {
  [ "$install_started" = true ] || return 0
  trap '' 1 2 15
  install_started=false
  rollback_failed=false
  [ "$applied_changelog" = true ] && { rollback_patch "CHANGELOG.md" || rollback_failed=true; }
  [ "$applied_skill" = true ] && { rollback_patch "skills/exactmac/SKILL.md" || rollback_failed=true; }
  [ "$applied_plugin" = true ] && { rollback_patch "skills/exactmac/claude-plugin.json" || rollback_failed=true; }
  [ "$applied_make" = true ] && { rollback_patch "make/exactmac.mk" || rollback_failed=true; }
  [ "$applied_prompts" = true ] && { rollback_patch "internal/server/mcppromptslist_test.go" || rollback_failed=true; }
  [ "$applied_initialization" = true ] && { rollback_patch "internal/server/mcpinitialization_test.go" || rollback_failed=true; }
  [ "$applied_resources" = true ] && { rollback_patch "internal/server/mcpresources_test.go" || rollback_failed=true; }
  [ "$applied_server" = true ] && { rollback_patch "internal/server/protocol_dispatch.go" || rollback_failed=true; }
  [ "$applied_cli" = true ] && { rollback_patch "cmd/exactmac/main.go" || rollback_failed=true; }
  if [ "$rollback_failed" = true ]; then
    printf 'update-version.sh: rollback could not restore every applied destination; concurrent changes were preserved\n' >&2
  fi
  trap 'fail "interrupted"' 1 2 15
}

install_one() {
  install_relative=$1
  install_patch="$patch_root/$install_relative.patch"
  if ! release_preflight_destination "$repo_root/$install_relative" "$repo_root" || ! verify_source_file "$install_relative"; then
    return 1
  fi
  update_signal_pending=false
  trap 'update_signal_pending=true' 1 2 15
  install_status=0
  expected_install_digest=$(git -C "$repo_root" hash-object "$stage_root/$install_relative") || return 1
  git -C "$repo_root" apply --check --whitespace=nowarn "$install_patch" || install_status=$?
  if [ "$install_status" -eq 0 ] && ! verify_source_file "$install_relative"; then
    install_status=1
  fi
  if [ "$install_status" -eq 0 ] && [ "$update_signal_pending" = false ]; then
    git -C "$repo_root" apply --whitespace=nowarn "$install_patch" || install_status=$?
  fi
  if [ "$install_status" -eq 0 ]; then
    actual_install_digest=$(git -C "$repo_root" hash-object "$repo_root/$install_relative") || install_status=1
    if [ "$install_status" -eq 0 ] && [ "$actual_install_digest" != "$expected_install_digest" ]; then
      install_status=1
    fi
  fi
  if [ "$install_status" -eq 0 ]; then
    case "$install_relative" in
      "cmd/exactmac/main.go") applied_cli=true ;;
      "internal/server/protocol_dispatch.go") applied_server=true ;;
      "internal/server/mcpresources_test.go") applied_resources=true ;;
      "internal/server/mcpinitialization_test.go") applied_initialization=true ;;
      "internal/server/mcppromptslist_test.go") applied_prompts=true ;;
      "make/exactmac.mk") applied_make=true ;;
      "skills/exactmac/claude-plugin.json") applied_plugin=true ;;
      "skills/exactmac/SKILL.md") applied_skill=true ;;
      "CHANGELOG.md") applied_changelog=true ;;
    esac
  fi
  trap 'fail "interrupted"' 1 2 15
  if [ "$update_signal_pending" = true ]; then
    return 2
  fi
  [ "$install_status" -eq 0 ]
}

install_one "cmd/exactmac/main.go" || fail "could not install cmd/exactmac/main.go"
install_one "internal/server/protocol_dispatch.go" || fail "could not install internal/server/protocol_dispatch.go"
install_one "internal/server/mcpresources_test.go" || fail "could not install internal/server/mcpresources_test.go"
install_one "internal/server/mcpinitialization_test.go" || fail "could not install internal/server/mcpinitialization_test.go"
install_one "internal/server/mcppromptslist_test.go" || fail "could not install internal/server/mcppromptslist_test.go"
install_one "make/exactmac.mk" || fail "could not install make/exactmac.mk"
install_one "skills/exactmac/claude-plugin.json" || fail "could not install skills/exactmac/claude-plugin.json"
install_one "skills/exactmac/SKILL.md" || fail "could not install skills/exactmac/SKILL.md"
install_one "CHANGELOG.md" || fail "could not install CHANGELOG.md"

for product_file in $product_files; do
  if ! release_preflight_destination "$repo_root/$product_file" "$repo_root"; then
    fail "installed destination became unsafe: $product_file"
  fi
done
if ! release_require_product_surfaces "$repo_root" "$version"; then
  fail "installed product-version surfaces are inconsistent"
fi
for product_file in $product_files; do
  if ! release_preflight_destination "$repo_root/$product_file" "$repo_root"; then
    fail "installed destination became unsafe during final validation: $product_file"
  fi
done
install_started=false
printf 'Updated product version surfaces to %s (%s).\n' "$version" "$release_date"
printf 'Review the diff and commit it manually; no commit or tag was created.\n'
