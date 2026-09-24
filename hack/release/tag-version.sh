#!/bin/sh

# Create one annotated product tag after verifying the exact release state.
# This script deliberately creates a local tag only; pushing and publishing
# remain separate, deliberate release steps.

# shellcheck disable=SC1091
# shellcheck source=release-version-common.sh
script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P) || exit 1
. "$script_dir/release-version-common.sh" || exit 1
repo_root=$(CDPATH='' cd -P "$script_dir/../.." && pwd -P) || exit 1
cd "$repo_root" || exit 1
umask 077

fail() {
  printf 'tag-version.sh: %s\n' "$1" >&2
  exit 1
}

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf 'Usage: %s X.Y.Z\n' "$0" >&2
  exit 1
fi

version=$1
if ! release_validate_semver "$version"; then
  fail "version must be a SemVer X.Y.Z without leading zeroes"
fi

tag_lock=
tag_lock_owned=false
tag_lock_created=false
tag_lock_token="$$-$(date +%s)"
tag_nonce="$$-$(date +%s)"
tag_message="ExactMac $version [exactmac-tag-$tag_nonce]"
tag_attempted=false
tag_created=false
tag_object_id=
head_sha=
tag_cleanup() {
  trap '' 1 2 15
  if [ "$tag_attempted" = true ] || [ "$tag_created" = true ]; then
    if [ -n "$tag_object_id" ] && [ -n "$head_sha" ]; then
      cleanup_tag_ref=$(git show-ref --hash --verify "refs/tags/v$version" 2>/dev/null) || cleanup_tag_ref=
      if [ -n "$cleanup_tag_ref" ] && [ "$cleanup_tag_ref" = "$tag_object_id" ]; then
        git update-ref -d "refs/tags/v$version" "$tag_object_id" >/dev/null 2>&1 || :
      fi
    fi
  fi
  if [ "$tag_lock_owned" = true ] && [ -d "$tag_lock" ] && [ ! -L "$tag_lock" ] && [ -f "$tag_lock/owner" ]; then
    IFS= read -r cleanup_lock_token < "$tag_lock/owner" || cleanup_lock_token=
    if [ "$cleanup_lock_token" = "$tag_lock_token" ]; then
      rm -f "$tag_lock/owner"
      rmdir "$tag_lock" 2>/dev/null || :
    fi
  elif [ "$tag_lock_created" = true ] && [ -n "$tag_lock" ] && [ -d "$tag_lock" ] && [ ! -L "$tag_lock" ]; then
    rmdir "$tag_lock" 2>/dev/null || :
  fi
}
trap tag_cleanup 0
trap 'tag_cleanup; exit 130' 1 2 15

command -v git >/dev/null 2>&1 || fail "git is required"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required for exact-commit CI verification"

if [ ! -d .git ] && [ ! -f .git ]; then
  fail "repository root is not a Git worktree"
fi
tag_lock=$(git rev-parse --git-path exactmac-tag-version.lock) || fail "cannot resolve Git lock path"

origin_fetch_all=$(git remote get-url --all origin) || fail "origin fetch URLs are not available"
origin_push_all=$(git remote get-url --push --all origin) || fail "origin push URLs are not available"
[ -n "$origin_fetch_all" ] && [ -n "$origin_push_all" ] || fail "origin must have fetch and push URLs"
for origin_url in $origin_fetch_all $origin_push_all; do
  case "$origin_url" in
    https://github.com/joeycumines/ExactMac.git|git@github.com:joeycumines/ExactMac.git) ;;
    *) fail "every origin fetch and push URL must point to github.com/joeycumines/ExactMac" ;;
  esac
done

status=$(git status --porcelain --untracked-files=all) || fail "cannot inspect Git working tree"
if [ -n "$status" ]; then
  fail "working tree must be clean, including untracked files"
fi

branch=$(git symbolic-ref --quiet --short HEAD) || fail "HEAD must be on a branch"
if [ "$branch" != "main" ]; then
  fail "current branch must be main"
fi

head_sha=$(git rev-parse HEAD) || fail "cannot resolve HEAD"
origin_main=$(git rev-parse --verify refs/remotes/origin/main) || fail "origin/main is not available"
if [ "$head_sha" != "$origin_main" ]; then
  fail "HEAD must equal origin/main before tagging"
fi
canonical_head=$(GH_HOST=github.com gh api repos/joeycumines/ExactMac/commits/main --jq .sha) || fail "cannot inspect canonical GitHub main"
if [ "$canonical_head" != "$head_sha" ]; then
  fail "HEAD must equal canonical GitHub main before tagging"
fi

if git show-ref --verify --quiet "refs/tags/v$version"; then
  fail "v$version already exists"
fi

if ! release_require_tag_position "$repo_root" "$version"; then
  fail "release history is not monotonic or the tag is not the latest release"
fi
if ! release_require_product_surfaces "$repo_root" "$version"; then
  fail "known product-version surfaces are inconsistent or incomplete"
fi

ci_runs=$(GH_HOST=github.com gh run list --repo joeycumines/ExactMac --workflow ci.yaml --commit "$head_sha" --json databaseId,headSha,status,conclusion --limit 100 --jq '.[] | [.databaseId, .headSha, .status, .conclusion] | @tsv') || fail "cannot inspect CI runs for $head_sha"
ci_ok=false
ci_tab=$(printf '\t')
while IFS="$ci_tab" read -r run_id run_head run_status run_conclusion; do
  [ -n "$run_id" ] || continue
  if [ "$run_head" = "$head_sha" ] && [ "$run_status" = "completed" ] && [ "$run_conclusion" = "success" ]; then
    ci_ok=true
    break
  fi
done <<EOF
$ci_runs
EOF
if [ "$ci_ok" != true ]; then
  fail "no successful CI run exists for exact commit $head_sha"
fi
setup_signal_pending=false
trap 'setup_signal_pending=true' 1 2 15
if ! mkdir "$tag_lock" 2>/dev/null; then
  trap 'tag_cleanup; exit 130' 1 2 15
  fail "another tag operation is already running"
fi
tag_lock_created=true
printf '%s\n' "$tag_lock_token" > "$tag_lock/owner" || {
  trap 'tag_cleanup; exit 130' 1 2 15
  fail "cannot mark tag lock"
}
tag_lock_owned=true
trap 'tag_cleanup; exit 130' 1 2 15
if [ "$setup_signal_pending" = true ]; then
  fail "interrupted while acquiring tag lock"
fi

latest_origin_main=$(git rev-parse --verify refs/remotes/origin/main) || fail "origin/main changed during CI verification"
latest_canonical_head=$(GH_HOST=github.com gh api repos/joeycumines/ExactMac/commits/main --jq .sha) || fail "cannot recheck canonical GitHub main"
if [ "$latest_origin_main" != "$head_sha" ] || [ "$latest_canonical_head" != "$head_sha" ]; then
  fail "release commit changed during CI verification"
fi

status_now=$(git status --porcelain --untracked-files=all) || fail "cannot recheck Git working tree"
if [ -n "$status_now" ]; then
  fail "working tree changed during tag verification"
fi
head_now=$(git rev-parse HEAD) || fail "cannot recheck HEAD"
if [ "$head_now" != "$head_sha" ]; then
  fail "HEAD changed during tag verification"
fi
latest_origin_main=$(git rev-parse --verify refs/remotes/origin/main) || fail "origin/main changed during final tag verification"
latest_canonical_head=$(GH_HOST=github.com gh api repos/joeycumines/ExactMac/commits/main --jq .sha) || fail "cannot recheck canonical GitHub main"
if [ "$latest_origin_main" != "$head_sha" ] || [ "$latest_canonical_head" != "$head_sha" ]; then
  fail "release commit changed during final tag verification"
fi

tag_attempted=true
tag_signal_pending=false
trap 'tag_signal_pending=true' 1 2 15
tag_command_status=0
tagger_ident=$(git var GIT_COMMITTER_IDENT) || tag_command_status=$?
if [ "$tag_command_status" -eq 0 ]; then
  tag_object_id=$(printf 'object %s\ntype commit\ntag %s\ntagger %s\n\n%s\n' "$head_sha" "v$version" "$tagger_ident" "$tag_message" | git mktag) || tag_command_status=$?
fi
if [ "$tag_command_status" -eq 0 ] && [ -n "$tag_object_id" ]; then
  git update-ref "refs/tags/v$version" "$tag_object_id" "" || tag_command_status=$?
fi
if [ "$tag_command_status" -eq 0 ]; then
  tag_created=true
fi
trap 'tag_cleanup; exit 130' 1 2 15
if [ "$tag_signal_pending" = true ]; then
  fail "interrupted during tag creation"
fi
if [ "$tag_command_status" -ne 0 ] || [ -z "$tag_object_id" ]; then
  fail "could not create annotated tag v$version"
fi

tag_type=$(git cat-file -t "$tag_object_id") || fail "could not inspect created tag"
if [ "$tag_type" != "tag" ]; then
  fail "created tag is not annotated"
fi
tag_target=$(git rev-parse "$tag_object_id^{commit}") || fail "could not resolve created tag target"
if [ "$tag_target" != "$head_sha" ]; then
  fail "created tag does not point at HEAD"
fi
latest_canonical_after=$(GH_HOST=github.com gh api repos/joeycumines/ExactMac/commits/main --jq .sha) || fail "cannot recheck GitHub main after tagging"
status_after=$(git status --porcelain --untracked-files=all) || fail "cannot recheck Git tree after tagging"
if [ -n "$status_after" ]; then
  fail "working tree changed during tag creation"
fi
branch_after=$(git symbolic-ref --quiet --short HEAD) || fail "branch changed during tag creation"
if [ "$branch_after" != "main" ]; then
  fail "branch changed during tag creation"
fi
head_after=$(git rev-parse HEAD) || fail "HEAD changed during tag creation"
if [ "$head_after" != "$head_sha" ]; then
  fail "HEAD changed during tag creation"
fi
origin_after=$(git remote get-url --all origin) || fail "origin fetch URLs changed during tag creation"
push_after=$(git remote get-url --push --all origin) || fail "origin push URLs changed during tag creation"
for origin_after_url in $origin_after $push_after; do
  case "$origin_after_url" in
    https://github.com/joeycumines/ExactMac.git|git@github.com:joeycumines/ExactMac.git) ;;
    *) fail "origin URL changed during tag creation" ;;
  esac
done
latest_origin_after=$(git rev-parse --verify refs/remotes/origin/main) || fail "origin/main changed during tag creation"
if [ "$latest_origin_after" != "$head_sha" ] || [ "$latest_canonical_after" != "$head_sha" ]; then
  fail "release commit changed during tag creation"
fi
current_tag_ref=$(git show-ref --hash --verify "refs/tags/v$version") || fail "created tag ref disappeared"
if [ "$current_tag_ref" != "$tag_object_id" ]; then
  fail "created tag ref was replaced"
fi
git update-ref "refs/tags/v$version" "$tag_object_id" "$tag_object_id" || fail "created tag ownership changed"
tag_created=false
tag_attempted=false

printf 'Created annotated local tag v%s at %s.\n' "$version" "$head_sha"
printf 'Inspect the tag before any deliberate push or publication step.\n'
