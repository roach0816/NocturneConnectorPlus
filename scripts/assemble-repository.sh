#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?Set GH_TOKEN for GitHub release downloads}"

site_dir=${1:?Usage: assemble-repository.sh SITE_DIR PRIVATE_KEY PUBLIC_KEY}
private_key=${2:?Usage: assemble-repository.sh SITE_DIR PRIVATE_KEY PUBLIC_KEY}
public_key=${3:?Usage: assemble-repository.sh SITE_DIR PRIVATE_KEY PUBLIC_KEY}

repo_dir="$site_dir/apk/v3.24/main/aarch64"
metadata_dir="$site_dir/apk/metadata"
mkdir -p "$repo_dir" "$metadata_dir"

mapfile -t release_tags < <(
	gh release list --limit 100 \
		--json tagName,publishedAt,isDraft,isPrerelease \
	| jq -r '
		map(select(
			(.isDraft | not) and
			(.isPrerelease | not) and
			(.tagName | startswith("apk-"))
		))
		| sort_by(.publishedAt)
		| reverse
		| .[0:5]
		| .[].tagName'
)

[ "${#release_tags[@]}" -gt 0 ] || {
	echo "No published APK releases were found." >&2
	exit 1
}

for tag in "${release_tags[@]}"; do
	gh release download "$tag" --dir "$repo_dir" \
		--pattern 'nocturne-connector-plus-*.apk' --skip-existing
	gh release download "$tag" --dir "$metadata_dir" \
		--pattern '*.provenance.json' --skip-existing
done

install -m 0644 "$public_key" \
	"$site_dir/apk/nocturne-connector-plus.rsa.pub"
touch "$site_dir/.nojekyll"

docker run --rm --platform linux/arm64 \
	-v "$repo_dir:/repo" \
	-v "$private_key:/run/secrets/nocturne-connector-plus.rsa:ro" \
	-v "$public_key:/run/secrets/nocturne-connector-plus.rsa.pub:ro" \
	alpine:3.24 sh -ec '
		apk add --no-cache abuild
		install -m 0644 \
			/run/secrets/nocturne-connector-plus.rsa.pub \
			/etc/apk/keys/nocturne-connector-plus.rsa.pub
		cd /repo
		apk index -o APKINDEX.tar.gz ./*.apk
		abuild-sign -k /run/secrets/nocturne-connector-plus.rsa APKINDEX.tar.gz
	'

jq -s 'sort_by(.package.version) | reverse' \
	"$metadata_dir"/*.provenance.json > "$site_dir/apk/versions.json"

cat > "$site_dir/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Nocturne Connector Plus APK Repository</title></head>
<body>
<h1>Nocturne Connector Plus APK Repository</h1>
<p>This site hosts the signed Alpine Linux package repository.</p>
<p>See the project README for installation and upgrade instructions.</p>
</body>
</html>
EOF

echo "Assembled repository with ${#release_tags[@]} retained package version(s)."
