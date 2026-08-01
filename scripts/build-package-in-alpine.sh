#!/bin/sh
set -eu

: "${APORT_DIR:?Set APORT_DIR to the generated aport directory}"
: "${OUTPUT_DIR:?Set OUTPUT_DIR to the package output directory}"
: "${ABUILD_PRIVATE_KEY_FILE:?Set ABUILD_PRIVATE_KEY_FILE to the signing key}"

[ "$(id -u)" -eq 0 ] || {
	echo "This helper must run as root inside Alpine." >&2
	exit 1
}
[ "$(apk --print-arch)" = aarch64 ] || {
	echo "Package builds must run natively on Alpine aarch64." >&2
	exit 1
}
[ -f "$APORT_DIR/APKBUILD" ] || {
	echo "Generated APKBUILD not found in $APORT_DIR." >&2
	exit 1
}
[ -f "$ABUILD_PRIVATE_KEY_FILE" ] || {
	echo "Signing key not found: $ABUILD_PRIVATE_KEY_FILE" >&2
	exit 1
}

apk add --no-cache alpine-sdk atools libgcc libstdc++ openssl shellcheck sudo
apk update

adduser -D builder
addgroup builder abuild
install -d -m 0750 -o builder -g builder /home/builder/.abuild
install -m 0600 -o builder -g builder "$ABUILD_PRIVATE_KEY_FILE" \
	/home/builder/.abuild/nocturne-connector-plus.rsa
openssl rsa -in /home/builder/.abuild/nocturne-connector-plus.rsa \
	-pubout -out /home/builder/.abuild/nocturne-connector-plus.rsa.pub \
	2>/dev/null
chown builder:builder /home/builder/.abuild/nocturne-connector-plus.rsa.pub
install -m 0644 /home/builder/.abuild/nocturne-connector-plus.rsa.pub \
	/etc/apk/keys/nocturne-connector-plus.rsa.pub

mkdir -p /etc/sudoers.d "$OUTPUT_DIR"
printf '%s\n' 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder
chown -R builder:builder "$APORT_DIR" "$OUTPUT_DIR"

cat > /home/builder/.abuild/abuild.conf <<EOF
PACKAGER="Nocturne Connector Plus <roach0816@users.noreply.github.com>"
PACKAGER_PRIVKEY="/home/builder/.abuild/nocturne-connector-plus.rsa"
REPODEST="$OUTPUT_DIR"
EOF
chown builder:builder /home/builder/.abuild/abuild.conf

for script in "$APORT_DIR"/*.initd "$APORT_DIR"/*.install-update \
	"$APORT_DIR"/*.post-* "$APORT_DIR"/*.pre-*; do
	shellcheck -s sh "$script"
done

su builder -c "cd '$APORT_DIR' && abuild checksum"
su builder -c "cd '$APORT_DIR' && apkbuild-lint APKBUILD"
su builder -c "cd '$APORT_DIR' && abuild -r"

package_path=$(find "$OUTPUT_DIR" -type f \
	-name 'nocturne-connector-plus-*.apk' | head -n 1)
[ -n "$package_path" ] || {
	echo "abuild completed without producing the expected package." >&2
	exit 1
}
printf '%s\n' "$package_path"
