#!/bin/sh
# Managed by infrastructure/infra: Forgejo server-side linear history policy.
set -eu

reject() {
    printf 'policy/linear-history: %s\n' "$*" >&2
    exit 1
}

# Pin the grandfathered history. Never exclude --all or the current main:
# another ref (or a multi-ref push) must not launder a new merge commit.
repo_dir=$(git rev-parse --absolute-git-dir) || exit 1
# Forgejo 16+ uses core.hooksPath for its central dispatcher; the policy data
# remains in this repository, not in the central hooks directory.
baseline_path=$repo_dir/hooks/linear-history-baseline
baseline=$(cat "$baseline_path") || reject 'Cannot read the history baseline; contact the administrator.'
case "$baseline" in
    ''|*[!0-9a-f]*) reject 'Invalid history baseline.' ;;
esac
case ${#baseline} in
    40|64) ;;
    *) reject 'The history baseline must be a full commit ID.' ;;
esac
git cat-file -e "$baseline^{commit}" || reject 'The history baseline commit is missing.'

while read -r _old_oid new_oid ref_name; do
    case "$ref_name" in
        refs/heads/*|refs/for/*|refs/draft/*|refs/drafts/*|refs/for-review/*|refs/pull/*/head) ;;
        *) continue ;;
    esac
    # Deletion remains subject to Forgejo's own permission checks.
    case "$new_oid" in
        *[!0]*) ;;
        *) continue ;;
    esac
    git cat-file -e "$new_oid^{commit}" || reject "Cannot inspect $ref_name."
    merge_oid=$(git rev-list --max-count=1 --min-parents=2 "$new_oid" "^$baseline" --) ||
        reject "Cannot inspect the history of $ref_name."
    if [ -n "$merge_oid" ]; then
        reject "$ref_name contains merge commit $merge_oid. Rebase your work onto the target branch (normally origin/main), then push with --force-with-lease. Merging main into a work branch is not allowed."
    fi
done
