#!/bin/sh
set -eu

usage() {
	echo "Usage: $0 UPSTREAM_TAG [PKGREL] OUTPUT_DIR" >&2
	exit 2
}

[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage

upstream_tag=$1
if [ "$#" -eq 2 ]; then
	pkgrel=0
	output_dir=$2
else
	pkgrel=$2
	output_dir=$3
fi

printf '%s\n' "$upstream_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$' || {
	echo "Unsupported upstream tag: $upstream_tag" >&2
	exit 1
}
printf '%s\n' "$pkgrel" | grep -Eq '^[0-9]+$' || {
	echo "pkgrel must be a non-negative integer." >&2
	exit 1
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)

if [ -e "$output_dir" ] && [ -n "$(ls -A "$output_dir" 2>/dev/null)" ]; then
	echo "Output directory must be empty: $output_dir" >&2
	exit 1
fi
mkdir -p "$output_dir"
output_dir=$(CDPATH='' cd -- "$output_dir" && pwd)

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/nocturne-release.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

api_get() {
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		curl -fsSL \
			-H "Authorization: Bearer $GITHUB_TOKEN" \
			-H "Accept: application/vnd.github+json" \
			"$1"
	else
		curl -fsSL -H "Accept: application/vnd.github+json" "$1"
	fi
}

release_json="$tmp_dir/release.json"
api_get "https://api.github.com/repos/usenocturne/nocturne-connector/releases/tags/$upstream_tag" \
	> "$release_json"

[ "$(jq -r '.draft' "$release_json")" = false ] || {
	echo "Refusing to package a draft release." >&2
	exit 1
}
[ "$(jq -r '.prerelease' "$release_json")" = false ] || {
	echo "Refusing to package a prerelease." >&2
	exit 1
}
[ "$(jq -r '.tag_name' "$release_json")" = "$upstream_tag" ] || {
	echo "Release API returned an unexpected tag." >&2
	exit 1
}

checkout="$tmp_dir/upstream"
git clone --quiet --depth 1 --branch "$upstream_tag" \
	https://github.com/usenocturne/nocturne-connector.git "$checkout"
upstream_commit=$(git -C "$checkout" rev-parse HEAD)
git -C "$checkout" diff --quiet
git -C "$checkout" diff --cached --quiet

for required in \
	build.sh \
	src/bun.lock \
	src/bunfig.toml \
	src/package.json \
	src/server/index.ts \
	src/tsconfig.json \
	scripts/services/wifi-import.sh; do
	[ -f "$checkout/$required" ] || {
		echo "Upstream layout changed; missing $required" >&2
		exit 1
	}
done

bun_version=$(sed -n 's/.*BUN_VERSION:="\([^"]*\)".*/\1/p' \
	"$checkout/build.sh" | head -n 1)
alpine_build=$(sed -n 's/.*ALPINE_BUILD:="\([^"]*\)".*/\1/p' \
	"$checkout/build.sh" | head -n 1)
[ -n "$bun_version" ] || {
	echo "Could not determine BUN_VERSION from upstream build.sh." >&2
	exit 1
}
[ "$alpine_build" = 3.24 ] || {
	echo "Upstream Alpine baseline changed from 3.24 to ${alpine_build:-unknown}." >&2
	exit 1
}

pkgver=$(printf '%s' "${upstream_tag#v}" | tr '-' '.')
source_name="nocturne-connector-$upstream_tag.tar.gz"
bun_name="bun-linux-aarch64-musl-$bun_version.zip"

git -C "$checkout" archive --format=tar.gz \
	--prefix="nocturne-connector-$upstream_tag/" \
	-o "$output_dir/$source_name" HEAD

bun_json="$tmp_dir/bun.json"
api_get "https://api.github.com/repos/oven-sh/bun/releases/tags/bun-v$bun_version" \
	> "$bun_json"
bun_url=$(jq -r '.assets[] | select(.name == "bun-linux-aarch64-musl.zip") | .browser_download_url' \
	"$bun_json")
bun_digest=$(jq -r '.assets[] | select(.name == "bun-linux-aarch64-musl.zip") | .digest' \
	"$bun_json")
if [ -z "$bun_url" ] || [ "$bun_url" = null ]; then
	echo "Bun aarch64-musl asset is missing for v$bun_version." >&2
	exit 1
fi
case "$bun_digest" in
	sha256:*) bun_sha256=${bun_digest#sha256:} ;;
	*)
		echo "Bun did not publish a sha256 digest for the required asset." >&2
		exit 1
		;;
esac

curl -fL --retry 3 "$bun_url" -o "$output_dir/$bun_name"
actual_bun_sha256=$(sha256sum "$output_dir/$bun_name" | awk '{print $1}')
[ "$actual_bun_sha256" = "$bun_sha256" ] || {
	echo "Bun asset digest mismatch." >&2
	exit 1
}

cp "$repo_dir"/packaging/connector-api.confd \
	"$repo_dir"/packaging/connector-api.initd \
	"$repo_dir"/packaging/nocturne-connector-plus.* \
	"$output_dir/"

sed \
	-e "s/@PKGVER@/$pkgver/g" \
	-e "s/@PKGREL@/$pkgrel/g" \
	-e "s/@UPSTREAM_TAG@/$upstream_tag/g" \
	-e "s/@UPSTREAM_COMMIT@/$upstream_commit/g" \
	-e "s/@BUN_VERSION@/$bun_version/g" \
	"$repo_dir/packaging/APKBUILD.in" > "$output_dir/APKBUILD"

source_sha256=$(sha256sum "$output_dir/$source_name" | awk '{print $1}')
published_at=$(jq -r '.published_at' "$release_json")

cat > "$output_dir/release.env" <<EOF
UPSTREAM_TAG=$upstream_tag
UPSTREAM_COMMIT=$upstream_commit
UPSTREAM_PUBLISHED_AT=$published_at
PKGVER=$pkgver
PKGREL=$pkgrel
PACKAGE_RELEASE=apk-$pkgver-r$pkgrel
BUN_VERSION=$bun_version
BUN_SHA256=$bun_sha256
SOURCE_SHA256=$source_sha256
EOF

printf 'Prepared %s (%s) as %s-r%s with Bun %s.\n' \
	"$upstream_tag" "$upstream_commit" "$pkgver" "$pkgrel" "$bun_version"
