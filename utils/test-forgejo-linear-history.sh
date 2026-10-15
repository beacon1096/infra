#!/usr/bin/env bash
# Exercise real receive-pack transactions, including the quarantine object store.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export GIT_AUTHOR_NAME='Hook Test' GIT_AUTHOR_EMAIL='hook-test@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
git init -q --bare "$scratch/server.git"
git init -q "$scratch/client"
cd "$scratch/client"
git remote add origin "$scratch/server.git"
tree=$(git mktree </dev/null)
commit() { printf '%s\n' "$1" | git -c commit.gpgSign=false commit-tree "$tree" "${@:2}"; }
initial=$(commit initial)
left=$(commit old-left -p "$initial")
right=$(commit old-right -p "$initial")
baseline=$(commit old-merge -p "$left" -p "$right")
git push -q origin "$baseline:refs/heads/main"
cp "$root/wanxiang/kubernetes/apps/development/forgejo/app/hooks/require-linear-history.sh" "$scratch/server.git/hooks/pre-receive"
chmod +x "$scratch/server.git/hooks/pre-receive"
printf '%s\n' "$baseline" > "$scratch/server.git/hooks/linear-history-baseline"

passed=0
accept() {
    local description=$1
    shift
    if ! git push --porcelain origin "$@" >"$scratch/output" 2>&1; then
        cat "$scratch/output" >&2
        printf 'FAIL (unexpected rejection): %s\n' "$description" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
    passed=$((passed + 1))
}
reject() {
    local description=$1
    shift
    if git push --porcelain origin "$@" >"$scratch/output" 2>&1; then
        printf 'FAIL (unexpected acceptance): %s\n' "$description" >&2
        exit 1
    fi
    if ! grep -q 'policy/linear-history:' "$scratch/output"; then
        cat "$scratch/output" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
    passed=$((passed + 1))
}

linear=$(commit linear -p "$baseline")
other=$(commit other -p "$baseline")
merged=$(commit new-merge -p "$linear" -p "$other")
hidden=$(commit merge-under-tip -p "$merged")
rebased=$(commit rebased -p "$linear")
accept 'new branch inherits historical merges' "$linear:refs/heads/work"
accept 'linear main update' "$linear:refs/heads/main"
reject 'fast-forward into main cannot import a merge' "$merged:refs/heads/main"
reject 'new branch containing a merge' "$merged:refs/heads/bad"
reject 'merge hidden below a single-parent tip' "$hidden:refs/heads/hidden"
reject 'forced branch update containing a merge' "+$merged:refs/heads/work"
accept 'rebased branch update' "+$rebased:refs/heads/work"
accept 'branch deletion' ':refs/heads/work'
accept 'tags remain outside this branch policy' "$merged:refs/tags/merge-object"
reject 'existing tag cannot launder merge into a branch' "$merged:refs/heads/from-tag"
reject 'AGit review push' "$merged:refs/for/main/topic"
reject 'PR head update' "$merged:refs/pull/123/head"
reject 'mixed transaction rejects all branch updates' "$rebased:refs/heads/clean" "$merged:refs/heads/dirty"
if git --git-dir="$scratch/server.git" show-ref --verify --quiet refs/heads/clean; then
    printf 'FAIL: rejected transaction updated the clean branch\n' >&2
    exit 1
fi
accept 'clean multi-ref push' "$rebased:refs/heads/clean" "$linear:refs/heads/another"
mkdir "$scratch/central-hooks"
cp "$scratch/server.git/hooks/pre-receive" "$scratch/central-hooks/pre-receive"
git --git-dir="$scratch/server.git" config core.hooksPath "$scratch/central-hooks"
accept 'central dispatcher still reads the repository baseline' "$rebased:refs/heads/central-clean"
reject 'central dispatcher still rejects merges' "$merged:refs/heads/central-dirty"
mv "$scratch/server.git/hooks/linear-history-baseline" "$scratch/baseline"
reject 'missing baseline file fails closed' "$rebased:refs/heads/missing-baseline"
mv "$scratch/baseline" "$scratch/server.git/hooks/linear-history-baseline"
printf 'missing\n' > "$scratch/server.git/hooks/linear-history-baseline"
reject 'invalid baseline fails closed' "$rebased:refs/heads/invalid-baseline"
printf '%040d\n' 1 > "$scratch/server.git/hooks/linear-history-baseline"
reject 'missing baseline object fails closed' "$rebased:refs/heads/missing-object"
printf '%s\n' "$baseline" > "$scratch/server.git/hooks/linear-history-baseline"
printf '%s receive-pack policy checks passed.\n' "$passed"
