# shellcheck shell=sh
# Shared validation and safe file helpers for the release scripts.
# This file is sourced, not executed directly.

release_is_version_component() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 0 ;;
    [1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

release_validate_semver() {
  release_semver_value=$1
  case "$release_semver_value" in
    *.*.*) ;;
    *) return 1 ;;
  esac
  release_semver_major=${release_semver_value%%.*}
  release_semver_rest=${release_semver_value#*.}
  release_semver_minor=${release_semver_rest%%.*}
  release_semver_patch=${release_semver_rest#*.}
  [ "$release_semver_patch" != "$release_semver_rest" ] || return 1
  release_is_version_component "$release_semver_major" || return 1
  release_is_version_component "$release_semver_minor" || return 1
  release_is_version_component "$release_semver_patch" || return 1
  return 0
}

release_version_is_increasing() {
  release_left=$1
  release_right=$2
  awk -v left="$release_left" -v right="$release_right" '
    function compare_component(a, b, result) {
      if (length(a) > length(b)) return 1
      if (length(a) < length(b)) return -1
      if (("x" a) > ("x" b)) return 1
      if (("x" a) < ("x" b)) return -1
      return 0
    }
    BEGIN {
      split(left, left_parts, ".")
      split(right, right_parts, ".")
      for (part = 1; part <= 3; part++) {
        result = compare_component(left_parts[part], right_parts[part])
        if (result < 0) exit 0
        if (result > 0) exit 1
      }
      exit 1
    }
  '
}

release_count_literal() {
  release_count_file=$1
  release_count_needle=$2
  [ -f "$release_count_file" ] || return 1
  awk -v needle="$release_count_needle" '
    {
      rest = $0
      while ((position = index(rest, needle)) > 0) {
        count++
        rest = substr(rest, position + length(needle))
      }
    }
    END { print count + 0 }
  ' "$release_count_file"
}

release_exact_line_count() {
  release_line_file=$1
  release_line_expected=$2
  [ -f "$release_line_file" ] || return 1
  awk -v expected="$release_line_expected" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == expected) count++
    }
    END { print count + 0 }
  ' "$release_line_file"
}

release_require_exact_line_count() {
  release_exact_file=$1
  release_exact_expected=$2
  release_exact_wanted=$3
  [ -f "$release_exact_file" ] || return 1
  release_exact_actual=$(release_exact_line_count "$release_exact_file" "$release_exact_expected") || return 1
  [ "$release_exact_actual" -eq "$release_exact_wanted" ]
}

release_require_independent_versions() {
  release_independent_root=$1
  release_independent_file="$release_independent_root/internal/server/mcpinitialization_test.go"
  release_require_exact_line_count "$release_independent_file" '"version": "1.0.0",' 4 || return 1
  release_require_exact_line_count "$release_independent_file" '"version": "1.0.0"' 0 || return 1
  return 0
}

release_server_info_versions() {
  release_server_file=$1
  [ -f "$release_server_file" ] || return 1
  awk '
    function emit_version(line, value) {
      if (!match(line, /"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/)) return 0
      value = substr(line, RSTART, RLENGTH)
      sub(/^"version"[[:space:]]*:[[:space:]]*"/, "", value)
      sub(/"$/, "", value)
      print value
      return 1
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line ~ /^(\/\/|\*|\/\*)/) next
      if (in_server_info) {
        if (emit_version($0)) {
          found++
          in_server_info = 0
        }
        next
      }
      if ($0 ~ /"serverInfo"[[:space:]]*:/) {
        if (emit_version($0)) {
          found++
        } else {
          in_server_info = 1
        }
      }
    }
    END {
      if (in_server_info || found == 0) exit 1
    }
  ' "$release_server_file"
}

release_require_server_info() {
  release_server_root=$1
  release_server_relative=$2
  release_server_version=$3
  release_server_expected=$4
  release_server_actual=$(release_server_info_versions "$release_server_root/$release_server_relative") || return 1
  release_server_count=$(printf '%s\n' "$release_server_actual" | awk 'NF { count++ } END { print count + 0 }')
  [ "$release_server_count" -eq "$release_server_expected" ] || return 1
  release_server_bad=false
  while IFS= read -r release_server_value; do
    [ "$release_server_value" = "$release_server_version" ] || release_server_bad=true
  done <<EOF
$release_server_actual
EOF
  [ "$release_server_bad" = false ]
}

release_require_protocol_server_info() {
  release_protocol_root=$1
  release_protocol_version=$2
  release_require_exact_line_count "$release_protocol_root/internal/server/protocol_dispatch.go" "\"serverInfo\":  map[string]any{\"name\": \"exactmac\", \"version\": \"$release_protocol_version\"}," 1
}

release_require_json_fixture_server_info() {
  release_fixture_root=$1
  release_fixture_relative=$2
  release_fixture_version=$3
  awk -v expected="$release_fixture_version" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "\"serverInfo\": {") {
        headers++
        in_server = 1
        name_seen = 0
        next
      }
      if (in_server && line == "\"name\": \"exactmac\",") {
        name_seen = 1
        next
      }
      if (in_server && line == "\"version\": \"" expected "\"") {
        if (!name_seen) bad = 1
        versions++
        in_server = 0
        next
      }
      if (in_server && line == "}") {
        bad = 1
        in_server = 0
      }
    }
    END { if (headers != 1 || versions != 1 || in_server || bad) exit 1 }
  ' "$release_fixture_root/$release_fixture_relative"
}

release_require_initialization_server_info() {
  release_init_root=$1
  release_init_version=$2
  awk -v expected="$release_init_version" '
    {
      raw = $0
      line = raw
      sub(/^[ \t]+/, "", line)
      if (line ~ /^(\/\/|\*|\/\*)/) next
      if (index(raw, "\"serverInfo\":") > 0) {
        keys++
        if (raw ~ /response: `\{/ && (index(raw, "\"version\": \"" expected "\"") > 0 || index(raw, "\"version\":\"" expected "\"") > 0)) raw_count++
        else if (line == "\"serverInfo\":      map[string]any{\"name\": \"exactmac\", \"version\": \"" expected "\"},") map_count++
        else bad = 1
      }
    }
    END { if (keys != 3 || raw_count != 2 || map_count != 1 || bad) exit 1 }
  ' "$release_init_root/internal/server/mcpinitialization_test.go"
}

release_require_cli_version() {
  release_cli_root=$1
  release_cli_version=$2
  release_cli_file="$release_cli_root/cmd/exactmac/main.go"
  [ -f "$release_cli_file" ] || return 1
  awk -v expected="$release_cli_version" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "fmt.Fprintln(os.Stderr, \"exactmac " expected "\")") {
        found++
      } else if (index(line, "exactmac ") > 0 && line ~ /exactmac [0-9]+\.[0-9]+\.[0-9]+/) {
        bad = 1
      }
    }
    END { if (found != 1 || bad) exit 1 }
  ' "$release_cli_file"
}

release_require_make_version() {
  release_make_root=$1
  release_make_version=$2
  release_make_file="$release_make_root/make/exactmac.mk"
  [ -f "$release_make_file" ] || return 1
  command -v gmake >/dev/null 2>&1 || return 1
  release_make_database=$(env -u EXACTMAC_VERSION gmake -f "$release_make_file" -pn 2>/dev/null) || return 1
  release_make_effective=$(printf '%s\n' "$release_make_database" | awk -F ' = ' '$1 == "EXACTMAC_VERSION" && !found { print $2; found = 1 }')
  [ "$release_make_effective" = "$release_make_version" ] || return 1
  awk -v expected="$release_make_version" '
    {
      raw = $0
      if (raw ~ /^[ \t]*#/) next
      if (raw ~ /^[ \t]*EXACTMAC_VERSION[ \t]*(::=|:=|\?=|\+=|!=|=)/) {
        if (raw != "EXACTMAC_VERSION        ?= " expected) bad = 1
        found++
      }
      if (raw ~ /^[ \t]*override[ \t]+EXACTMAC_VERSION[ \t]*(::=|:=|\?=|\+=|!=|=)/) bad = 1
    }
    END { if (found != 1 || bad) exit 1 }
  ' "$release_make_file"
}

release_require_json_version() {
  release_json_root=$1
  release_json_version=$2
  release_json_file="$release_json_root/skills/exactmac/claude-plugin.json"
  [ -f "$release_json_file" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  if ! python3 - "$release_json_file" "$release_json_version" <<'PY'
import json
import sys


def reject_constant(value):
    raise ValueError("non-standard JSON constant: " + value)


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def reject_nested_version(value, nested=False):
    if isinstance(value, dict):
        for key, child in value.items():
            if nested and key == "version":
                raise ValueError("unexpected nested version key")
            reject_nested_version(child, True)
    elif isinstance(value, list):
        for child in value:
            reject_nested_version(child, True)


with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(
        handle,
        object_pairs_hook=reject_duplicate_keys,
        parse_constant=reject_constant,
    )
reject_nested_version(document)
if not isinstance(document, dict) or document.get("version") != sys.argv[2]:
    raise SystemExit(1)
PY
  then
    return 1
  fi
  return 0
}

release_require_skill_version() {
  release_skill_root=$1
  release_skill_version=$2
  release_skill_file="$release_skill_root/skills/exactmac/SKILL.md"
  [ -f "$release_skill_file" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$release_skill_file" "$release_skill_version" <<'PY'
import re
import sys

path, expected = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
if not lines or lines[0] != "---":
    raise SystemExit(1)
try:
    end = lines.index("---", 1)
except ValueError:
    raise SystemExit(1)
frontmatter = lines[1:end]
top_keys = set()
metadata_seen = False
metadata_keys = set()
version_seen = False
top_block = False
for line in frontmatter:
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if "\t" in line:
        raise SystemExit(1)
    indent = len(line) - len(line.lstrip(" "))
    content = line[indent:]
    if indent == 0:
        top_block = False
        match = re.fullmatch(r"([A-Za-z0-9_-]+):(?:[ ]*(.*))?", content)
        if not match or match.group(1) in top_keys:
            raise SystemExit(1)
        key, value = match.groups()
        top_keys.add(key)
        if key == "metadata":
            if value:
                raise SystemExit(1)
            metadata_seen = True
        elif value in {"|", ">", "|-", ">-", "|+", ">+"}:
            top_block = True
        continue
    if top_block:
        continue
    if not metadata_seen or indent != 2:
        raise SystemExit(1)
    match = re.fullmatch(r"([A-Za-z0-9_-]+):(?:[ ]*(.*))?", content)
    if not match or match.group(1) in metadata_keys:
        raise SystemExit(1)
    key, value = match.groups()
    metadata_keys.add(key)
    if key == "version":
        if value != expected or version_seen:
            raise SystemExit(1)
        version_seen = True
    elif value in {"|", ">", "|-", ">-", "|+", ">+"}:
        raise SystemExit(1)
if not metadata_seen or not version_seen:
    raise SystemExit(1)
PY
}

release_validate_changelog_structure() {
  release_structure_root=$1
  release_structure_file="$release_structure_root/CHANGELOG.md"
  [ -f "$release_structure_file" ] || return 1
  release_structure_ref=$(awk '
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
      if (info == "invalid") {
        fence_error = 1
        next
      }
      if (fence == "") {
        if (info != "") {
          split(info, fence_parts, ":")
          fence_char = fence_parts[1]
          fence_length = fence_parts[2]
          fence = "open"
          next
        }
      } else {
        if (info != "") {
          split(info, fence_parts, ":")
          if (fence_parts[1] == fence_char && fence_parts[2] + 0 >= fence_length + 0) fence = ""
        }
        next
      }
    }
    /^\[Unreleased\]: / {
      value = $0
      sub(/^\[Unreleased\]: https:\/\/github\.com\/joeycumines\/ExactMac\/compare\/v/, "", value)
      sub(/\.\.\.HEAD$/, "", value)
      print value
      found = 1
      next
    }
    END { if (found != 1 || fence != "" || fence_error) exit 1 }
  ' "$release_structure_file") || return 1
  release_validate_semver "$release_structure_ref" || return 1
  release_structure_latest=$(release_latest_changelog_version "$release_structure_root") || return 1
  [ "$release_structure_ref" = "$release_structure_latest" ] || return 1
  awk '
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
      if (info == "invalid") {
        fence_error = 1
        next
      }
      if (fence == "") {
        if (info != "") {
          split(info, fence_parts, ":")
          fence_char = fence_parts[1]
          fence_length = fence_parts[2]
          fence = "open"
          next
        }
      } else {
        if (info != "") {
          split(info, fence_parts, ":")
          if (fence_parts[1] == fence_char && fence_parts[2] + 0 >= fence_length + 0) fence = ""
        }
        next
      }
    }
    $0 == "## [Unreleased]" { header++ }
    /^\[Unreleased\]: / { link++ }
    END { if (header != 1 || link != 1 || fence != "" || fence_error) exit 1 }
  ' "$release_structure_file"
}

release_require_changelog_version() {
  release_changelog_root=$1
  release_changelog_version=$2
  release_changelog_file="$release_changelog_root/CHANGELOG.md"
  [ -f "$release_changelog_file" ] || return 1
  release_changelog_repo_url "$release_changelog_file" >/dev/null || return 1
  release_validate_changelog_structure "$release_changelog_root" || return 1
  awk -v expected="$release_changelog_version" -v repo="https://github.com/joeycumines/ExactMac" '
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
      if (info == "invalid") {
        fence_error = 1
        next
      }
      if (fence == "") {
        if (info != "") {
          split(info, fence_parts, ":")
          fence_char = fence_parts[1]
          fence_length = fence_parts[2]
          fence = "open"
          next
        }
      } else {
        if (info != "") {
          split(info, fence_parts, ":")
          if (fence_parts[1] == fence_char && fence_parts[2] + 0 >= fence_length + 0) fence = ""
        }
        next
      }
    }
    /^## \[/ {
      if ($0 == "## [Unreleased]") next
      label = $0
      sub(/^## \[/, "", label)
      sub(/\].*$/, "", label)
      headers[label] = 1
      header_count++
      if (label == expected) header++
    }
    /^\[Unreleased\]: / {
      if ($0 !~ /^\[Unreleased\]: https:\/\/github\.com\/joeycumines\/ExactMac\/compare\/v[0-9]+\.[0-9]+\.[0-9]+\.\.\.HEAD$/) bad = 1
    }
    /^\[[0-9]+\.[0-9]+\.[0-9]+\]: / {
      label = $0
      sub(/^\[/, "", label)
      sub(/\]:.*$/, "", label)
      if (!(label in headers)) bad = 1
      links[label] = 1
      link_count++
      target = "[" label "]: " repo "/releases/tag/v" label
      if ($0 != target) bad = 1
    }
    END {
      for (label in headers) if (!(label in links)) bad = 1
       if (header != 1 || link_count != header_count || bad || fence != "" || fence_error) exit 1
    }
  ' "$release_changelog_file" || return 1
  release_changelog_latest=$(release_latest_changelog_version "$release_changelog_root") || return 1
  [ "$release_changelog_latest" = "$release_changelog_version" ]
}

# shellcheck disable=SC2154
release_validate_go_surfaces() {
  release_go_root=$1
  release_go_version=$2
  release_go_validator="$script_dir/validate-go-version.go"
  [ -f "$release_go_validator" ] || return 1
  command -v go >/dev/null 2>&1 || return 1
  go run "$release_go_validator" cli "$release_go_root/cmd/exactmac/main.go" "$release_go_version" || return 1
  go run "$release_go_validator" protocol "$release_go_root/internal/server/protocol_dispatch.go" "$release_go_version" || return 1
  go run "$release_go_validator" initialization "$release_go_root/internal/server/mcpinitialization_test.go" "$release_go_version" || return 1
  go run "$release_go_validator" resource "$release_go_root/internal/server/mcpresources_test.go" "$release_go_version" || return 1
  go run "$release_go_validator" prompts "$release_go_root/internal/server/mcppromptslist_test.go" "$release_go_version" || return 1
  go run "$release_go_validator" independent "$release_go_root/internal/server/mcpinitialization_test.go" 1.0.0 || return 1
  return 0
}

release_require_product_surfaces() {
  release_product_root=$1
  release_product_version=$2
  release_require_cli_version "$release_product_root" "$release_product_version" || return 1
  release_require_make_version "$release_product_root" "$release_product_version" || return 1
  release_require_json_version "$release_product_root" "$release_product_version" || return 1
  release_require_skill_version "$release_product_root" "$release_product_version" || return 1
  release_require_protocol_server_info "$release_product_root" "$release_product_version" || return 1
  release_require_json_fixture_server_info "$release_product_root" "internal/server/mcpresources_test.go" "$release_product_version" || return 1
  release_require_initialization_server_info "$release_product_root" "$release_product_version" || return 1
  release_require_json_fixture_server_info "$release_product_root" "internal/server/mcppromptslist_test.go" "$release_product_version" || return 1
  release_require_independent_versions "$release_product_root" || return 1
  release_validate_go_surfaces "$release_product_root" "$release_product_version" || return 1
  release_require_changelog_version "$release_product_root" "$release_product_version" || return 1
  return 0
}

release_changelog_repo_url() {
  release_changelog_file=$1
  [ -f "$release_changelog_file" ] || return 1
  awk '
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
      if (info == "invalid") {
        fence_error = 1
        next
      }
      if (fence == "") {
        if (info != "") {
          split(info, fence_parts, ":")
          fence_char = fence_parts[1]
          fence_length = fence_parts[2]
          fence = "open"
          next
        }
      } else {
        if (info != "") {
          split(info, fence_parts, ":")
          if (fence_parts[1] == fence_char && fence_parts[2] + 0 >= fence_length + 0) fence = ""
        }
        next
      }
    }
    /^\[Unreleased\]: / {
      value = $0
      sub(/^\[Unreleased\]: /, "", value)
      if (value !~ /^https:\/\/github\.com\/joeycumines\/ExactMac\/compare\/v[0-9]+\.[0-9]+\.[0-9]+\.\.\.HEAD$/) exit 1
      sub(/\/compare\/.*$/, "", value)
       print value
       found = 1
       next
     }
     END { if (found != 1 || fence != "" || fence_error) exit 1 }
  ' "$release_changelog_file"
}

release_latest_changelog_version() {
  release_history_root=$1
  release_history_file="$release_history_root/CHANGELOG.md"
  [ -f "$release_history_file" ] || return 1
  release_history_versions=$(awk '
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
      if (info == "invalid") {
        fence_error = 1
        next
      }
      if (fence == "") {
        if (info != "") {
          split(info, fence_parts, ":")
          fence_char = fence_parts[1]
          fence_length = fence_parts[2]
          fence = "open"
          next
        }
      } else {
        if (info != "") {
          split(info, fence_parts, ":")
          if (fence_parts[1] == fence_char && fence_parts[2] + 0 >= fence_length + 0) fence = ""
        }
        next
      }
    }
    /^## \[/ {
      if ($0 == "## [Unreleased]") {
        if (seen_release) exit 1
        next
      }
      if ($0 !~ /^## \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) exit 1
      seen_release = 1
      value = $0
      sub(/^## \[/, "", value)
      sub(/\].*$/, "", value)
      print value
    }
    END { if (fence != "" || fence_error) exit 1 }
  ' "$release_history_file") || return 1
  [ -n "$release_history_versions" ] || return 1
  release_history_latest=
  release_history_previous=
  while IFS= read -r release_history_value; do
    [ -n "$release_history_value" ] || continue
    release_validate_semver "$release_history_value" || return 1
    if [ -z "$release_history_latest" ]; then
      release_history_latest=$release_history_value
    else
      [ "$release_history_value" != "$release_history_previous" ] || return 1
      if ! release_version_is_increasing "$release_history_value" "$release_history_previous"; then
        return 1
      fi
    fi
    release_history_previous=$release_history_value
  done <<EOF
$release_history_versions
EOF
  [ -n "$release_history_latest" ] || return 1
  printf '%s\n' "$release_history_latest"
}

release_latest_root_tag_version() {
  release_tags_root=$1
  release_tags=$(git -C "$release_tags_root" tag --list 'v[0-9]*') || return 1
  release_tags_latest=
  for release_tag in $release_tags; do
    release_tag_version=${release_tag#v}
    release_validate_semver "$release_tag_version" || return 1
    if [ -z "$release_tags_latest" ] || release_version_is_increasing "$release_tags_latest" "$release_tag_version"; then
      release_tags_latest=$release_tag_version
    fi
  done
  [ -n "$release_tags_latest" ] || return 0
  printf '%s\n' "$release_tags_latest"
}

release_require_update_position() {
  release_position_root=$1
  release_position_current=$2
  release_position_target=$3
  release_position_latest=$(release_latest_changelog_version "$release_position_root") || return 1
  [ "$release_position_latest" = "$release_position_current" ] || return 1
  release_position_tag_latest=$(release_latest_root_tag_version "$release_position_root") || return 1
  if [ -n "$release_position_tag_latest" ] && [ "$release_position_tag_latest" != "$release_position_current" ]; then
    release_version_is_increasing "$release_position_tag_latest" "$release_position_current" || return 1
  fi
  release_version_is_increasing "$release_position_current" "$release_position_target" || return 1
  if [ -n "$release_position_tag_latest" ]; then
    release_version_is_increasing "$release_position_tag_latest" "$release_position_target" || return 1
  fi
  return 0
}

release_require_tag_position() {
  release_position_root=$1
  release_position_version=$2
  release_position_latest=$(release_latest_changelog_version "$release_position_root") || return 1
  [ "$release_position_latest" = "$release_position_version" ] || return 1
  release_position_tag_latest=$(release_latest_root_tag_version "$release_position_root") || return 1
  if [ -n "$release_position_tag_latest" ]; then
    release_version_is_increasing "$release_position_tag_latest" "$release_position_version" || return 1
  fi
  return 0
}

release_preflight_destination() {
  release_destination=$1
  release_boundary=${2:-/}
  [ -d "$release_boundary" ] && [ ! -L "$release_boundary" ] || return 1
  [ -f "$release_destination" ] && [ ! -L "$release_destination" ] || return 1
  release_parent=$(dirname "$release_destination")
  while [ "$release_parent" != "$release_boundary" ] && [ "$release_parent" != "." ] && [ "$release_parent" != "/" ]; do
    [ -d "$release_parent" ] && [ ! -L "$release_parent" ] || return 1
    release_parent=$(dirname "$release_parent")
  done
  [ "$release_parent" = "$release_boundary" ] || return 1
  [ -w "$release_destination" ] || return 1
  return 0
}
