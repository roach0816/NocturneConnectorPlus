#!/bin/sh
set -eu

new_package=${1:?Usage: test-package-in-alpine.sh NEW_PACKAGE [OLD_PACKAGE]}
old_package=${2:-}

[ "$(apk --print-arch)" = aarch64 ] || {
	echo "Package tests must run on Alpine aarch64." >&2
	exit 1
}

apk add --no-cache bluez chrony curl dbus libgcc libstdc++ openrc \
	wpa_supplicant

mkdir -p /run/openrc /run/dbus /etc/apk/keys \
	/etc/apk/protected_paths.d /etc/nocturne-connector/api \
	/etc/wpa_supplicant
touch /run/openrc/softlevel
install -m 0644 /workspace/keys/nocturne-connector-plus.rsa.pub \
	/etc/apk/keys/nocturne-connector-plus.rsa.pub
cp /workspace/packaging/nocturne-connector-plus.protected-paths \
	/etc/apk/protected_paths.d/nocturne-connector-plus.list
printf '%s\n' \
	'v2 @nocturneplus https://roach0816.github.io/NocturneConnectorPlus/apk/v3.24/main' \
	>> /etc/apk/repositories

printf '%s\n' legacy > /etc/nocturne-connector/api/legacy-file.ts
printf '%s\n' legacy > /etc/nocturne-connector/version
printf '%s\n' auth-state > /etc/nocturne-connector/auth-session.json
printf '%s\n' setup-state > /etc/nocturne-connector/setup-state.json
printf '%s\n' analytics-state > /etc/nocturne-connector/analytics-enabled.json
printf '%s\n' wifi-state > /etc/wpa_supplicant/wpa_supplicant.conf
printf '%s\n' legacy-connector-service > /etc/init.d/connector-api
printf '%s\n' legacy-wifi-service > /etc/init.d/wifi-import
printf '%s\n' legacy-site-config > /etc/conf.d/connector-api
chmod 0755 /etc/init.d/connector-api /etc/init.d/wifi-import

apk verify "$new_package"
[ -z "$old_package" ] || apk verify "$old_package"

check_install() {
	expect_plus_version=${1:-false}
	test -x /usr/libexec/nocturne-connector-plus/bun
	if [ "$expect_plus_version" = true ]; then
		test -f /usr/libexec/nocturne-connector-plus/package-version
	fi
	test -f /etc/nocturne-connector/api/server/index.ts
	test -f /etc/nocturne-connector/api/dist/client/index.html
	if grep -Eq '(^|[[:space:]])connector-data([[:space:]]|$)' \
		/etc/init.d/wifi-import; then
		echo "Wi-Fi import unexpectedly depends on the image-only connector-data service." >&2
		exit 1
	fi
	test "$(cat /etc/nocturne-connector/auth-session.json)" = auth-state
	test "$(cat /etc/nocturne-connector/setup-state.json)" = setup-state
	test "$(cat /etc/nocturne-connector/analytics-enabled.json)" = analytics-state
	test "$(cat /etc/wpa_supplicant/wpa_supplicant.conf)" = wifi-state

	if find /etc/nocturne-connector -name '*.apk-new' -print | grep -q .; then
		echo "Package transaction created unexpected .apk-new files." >&2
		exit 1
	fi
	for managed_path in \
		/etc/init.d/connector-api \
		/etc/init.d/wifi-import \
		/etc/conf.d/connector-api; do
		if [ -e "$managed_path.apk-new" ]; then
			echo "OpenRC takeover created $managed_path.apk-new." >&2
			exit 1
		fi
	done

	curl -fsS --max-time 3 http://127.0.0.1/api/info \
		>/tmp/connector-info.json
	grep -Fq '"version"' /tmp/connector-info.json
	if [ "$expect_plus_version" = true ]; then
		grep -Fq '"plusVersion"' /tmp/connector-info.json
	fi

	service_pid=$(cat /run/connector-api.pid)
	tr '\000' '\n' < "/proc/$service_pid/environ" \
		| grep -Fxq 'NOCTURNE_SITE_URL=https://usenocturne.com'
}

if [ -n "$old_package" ]; then
	apk add "$old_package"
	test "$(cat /etc/nocturne-connector/pre-apk-service-backup/init.d.connector-api)" = \
		legacy-connector-service
	test "$(cat /etc/nocturne-connector/pre-apk-service-backup/init.d.wifi-import)" = \
		legacy-wifi-service
	test "$(cat /etc/nocturne-connector/pre-apk-service-backup/conf.d.connector-api)" = \
		legacy-site-config
	check_install
fi
apk add --upgrade "$new_package"
if [ -z "$old_package" ]; then
	test "$(cat /etc/nocturne-connector/pre-apk-service-backup/init.d.connector-api)" = \
		legacy-connector-service
	test "$(cat /etc/nocturne-connector/pre-apk-service-backup/init.d.wifi-import)" = \
		legacy-wifi-service
	test "$(cat /etc/nocturne-connector/pre-apk-service-backup/conf.d.connector-api)" = \
		legacy-site-config
fi
check_install true
test -x /usr/libexec/nocturne-connector-plus/install-connector-update
curl -fsS --max-time 3 http://127.0.0.1/api/connector-update/status \
	>/tmp/connector-update-status.json
installed_version=$(cat /usr/libexec/nocturne-connector-plus/package-version)
current_version=$(cat /etc/nocturne-connector/version)
grep -Fq "\"installedPackageVersion\":\"$installed_version\"" \
	/tmp/connector-update-status.json
# This test APK uses an ephemeral key, so the production repository index is
# intentionally untrusted here. Seed the persisted cache to exercise the cheap
# GET path independently of a remote apk update.
mkdir -p /var/cache/nocturne-connector-plus
printf '{"status":"up_to_date","currentVersion":"%s","installedPackageVersion":"%s","latestUpstreamVersion":"%s","availablePackageVersion":"%s","packagedUpstreamVersion":"%s","updateAvailable":false,"packagePending":false,"installing":false,"checkedAt":"2026-08-02T00:00:00.000Z"}\n' \
	"$current_version" "$installed_version" "$current_version" \
	"$installed_version" "$current_version" \
	>/var/cache/nocturne-connector-plus/update-status.json
curl -fsS --max-time 3 http://127.0.0.1/api/connector-update/status \
	>/tmp/connector-update-cached-status.json
grep -Fq "\"latestUpstreamVersion\":\"$current_version\"" \
	/tmp/connector-update-cached-status.json
cross_origin_check_status=$(curl -sS --max-time 3 \
	-o /tmp/connector-check-cross-origin.json -w '%{http_code}' -X POST \
	-H 'Origin: https://example.invalid' \
	http://127.0.0.1/api/connector-update/check)
if [ "$cross_origin_check_status" != 403 ]; then
	echo "Cross-origin update check returned HTTP $cross_origin_check_status instead of 403." >&2
	exit 1
fi
cross_origin_status=$(curl -sS --max-time 3 -o /tmp/connector-update-cross-origin.json \
	-w '%{http_code}' -X POST -H 'Origin: https://example.invalid' \
	http://127.0.0.1/api/connector-update/install)
if [ "$cross_origin_status" != 403 ]; then
	echo "Cross-origin update request returned HTTP $cross_origin_status instead of 403." >&2
	exit 1
fi

if apk info -R nocturne-connector-plus | grep -Eq '(^|[[:space:]])(bash|git|npm|unzip)([[:space:]]|$)'; then
	echo "A build-only dependency leaked into runtime dependencies." >&2
	exit 1
fi

if [ -n "$old_package" ]; then
	apk add "$old_package"
	check_install
fi

apk del nocturne-connector-plus
test "$(cat /etc/nocturne-connector/auth-session.json)" = auth-state
test "$(cat /etc/nocturne-connector/setup-state.json)" = setup-state
test "$(cat /etc/nocturne-connector/analytics-enabled.json)" = analytics-state
test "$(cat /etc/wpa_supplicant/wpa_supplicant.conf)" = wifi-state
test ! -e /etc/nocturne-connector/api/server/index.ts

echo "Signed lifecycle, runtime, state preservation, downgrade, and removal tests passed."
