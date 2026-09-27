set -euo pipefail
image=$1
patches=$2
destination=$3
[[ $(docker image inspect --format '{{.Id}}' "$image") == "$image" ]]
staging=$(mktemp -d)
source_container=$(docker create "$image" true)
trap 'docker rm "$source_container" >/dev/null 2>&1 || true; rm -rf "$staging"' EXIT
while IFS=$'\t' read -r file source original patched; do
    docker cp "$source_container:$source" "$staging/$file"
    (cd "$staging" && printf '%s  %s\n' "$original" "$file" | sha256sum -c -)
    patch --batch --fuzz=0 -p0 -d "$staging" < "$patches/$file.patch"
    (cd "$staging" && printf '%s  %s\n' "$patched" "$file" | sha256sum -c -)
done < <(jq -r '.[] | [.file, .source, .original_sha256, .patched_sha256] | @tsv' "$patches/manifest.json")
mkdir -p "$destination"
install -m 0644 "$staging/"*.py "$destination/"
