#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
    printf 'Usage: %s IMAGE PATCH_DIR DESTINATION\n' "$0" >&2
    exit 2
fi
image=$1
patches=$(realpath -e "$2")
destination=$(realpath -m "$3")
if [[ ! $image =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*@sha256:[a-f0-9]{64}$ ]]; then
    printf 'IMAGE must be a complete repository@sha256: RepoDigest URI\n' >&2
    exit 2
fi

check_hash() {
    local actual
    actual=$(sha256sum "$1")
    if [[ ${actual%% *} != "$2" ]]; then
        printf 'SHA256 mismatch: %s; expected %s; got %s\n' "$1" "$2" "${actual%% *}" >&2
        return 1
    fi
}

mapfile -t entries < <(
    jq -er '
        if type != "array" or length == 0 then error("Expected at least one source patch")
        else .[] | [.file, .source, .original_sha256, .patched_sha256, .patch_sha256]
        | if all(.[]; type == "string" and length > 0) then @tsv
          else error("Missing manifest field") end end
    ' "$patches/manifest.json"
)

declare -A allowed=()
for entry in "${entries[@]}"; do
    IFS=$'\t' read -r file source original patched patch_hash <<< "$entry"
    [[ $file == *.py && $file != */* ]]
    [[ $source == /sgl-workspace/sglang/python/* ]]
    [[ $source == */"$file" ]]
    for hash in "$original" "$patched" "$patch_hash"; do
        [[ $hash =~ ^[a-f0-9]{64}$ ]]
    done
    if [[ -n ${allowed[$file]:-} ]]; then
        printf 'Duplicate manifest file: %s\n' "$file" >&2
        exit 2
    fi
    allowed[$file]=1
    check_hash "$patches/$file.patch" "$patch_hash"
done

# Keep the overlay outside a checkpoint and refuse a mixed-use destination.
ancestor=$destination
while :; do
    if [[ -e $ancestor/config.json || -e $ancestor/model.safetensors.index.json ]]; then
        printf 'DESTINATION must not be inside a model directory: %s\n' "$ancestor" >&2
        exit 2
    fi
    [[ $ancestor == / ]] && break
    ancestor=$(dirname "$ancestor")
done
if [[ -e $destination ]]; then
    [[ -d $destination && ! -L $destination ]]
    shopt -s nullglob dotglob
    for existing in "$destination"/*; do
        base=${existing##*/}
        if [[ -L $existing || ! -f $existing || -z ${allowed[$base]:-} ]]; then
            printf 'DESTINATION must contain only manifest overlay files\n' >&2
            exit 2
        fi
    done
fi

# inspect never pulls; RepoDigests are not Docker's config-image .Id.
docker image inspect "$image" | jq -e --arg image "$image" '
    length == 1 and (.[0].RepoDigests | index($image) != null)
' >/dev/null
staging=$(mktemp -d)
source_container=
cleanup() {
    if [[ $source_container =~ ^[a-f0-9]{64}$ ]]; then
        docker rm "$source_container" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$staging"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
source_container=$(docker create --pull=never --network=none --read-only \
    --entrypoint /bin/true "$image")
[[ $source_container =~ ^[a-f0-9]{64}$ ]]
for entry in "${entries[@]}"; do
    IFS=$'\t' read -r file source original patched patch_hash <<< "$entry"
    work=$(mktemp -d "$staging/${file}.XXXXXX")
    docker cp "$source_container:$source" "$work/$file"
    check_hash "$work/$file" "$original"
    patch --batch --forward --fuzz=0 --no-backup-if-mismatch -p0 -d "$work" \
        < "$patches/$file.patch"
    check_hash "$work/$file" "$patched"
    mkdir -p -- "$destination"
    install -m 0644 -- "$work/$file" "$destination/$file"
    check_hash "$destination/$file" "$patched"
    printf 'Prepared %s (sha256:%s)\n' "$destination/$file" "$patched"
    printf 'Server read-only bind target: %s\n' "$source"
done
