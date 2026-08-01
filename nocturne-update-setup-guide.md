# Nocturne Connector Plus: Alpine package setup and updates

This is the supported setup procedure for the Nocturne Connector Plus package
repository. It replaces the earlier proof-of-concept updater that cloned and
built Nocturne directly on the Connector.

The package updates only the application layer. Keep a copy of the official
Nocturne image in case the appliance ever needs to be reimaged.

## 1. Preflight

Run all host commands as `root`.

Confirm the supported system and record the current version:

```sh
cat /etc/alpine-release
apk --print-arch
cat /etc/nocturne-connector/version 2>/dev/null || true
rc-service connector-api status || true
curl -fsS http://127.0.0.1/api/info || true
echo
df -h /
```

The initial repository supports Alpine 3.24 on `aarch64`. Stop if the
architecture is different. A patch-level Alpine version such as `3.24.1` is
expected.

The prebuilt package needs far less space than a local source build. Several
hundred megabytes free on `/` is a comfortable starting point; use the disk
troubleshooting section only if `apk` reports insufficient space.

Optionally copy the small persistent state files before the first install:

```sh
backup=/root/nocturne-state-before-apk-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
cp -a /etc/nocturne-connector/*.json "$backup"/ 2>/dev/null || true
cp -a /data/nocturne-connector/*.json "$backup"/ 2>/dev/null || true
chmod -R go-rwx "$backup"
echo "Backup: $backup"
```

## 2. Trust the signing key

Install the repository's public key and verify its documented SHA-256 digest:

```sh
install -d -m 0755 /etc/apk/keys
wget -O /etc/apk/keys/nocturne-connector-plus.rsa.pub \
  https://roach0816.github.io/NocturneConnectorPlus/apk/nocturne-connector-plus.rsa.pub

echo '8baff61619a855ac861cc805fb73d57537e5a6b453f364cee9de6f2b23217e88  /etc/apk/keys/nocturne-connector-plus.rsa.pub' \
  | sha256sum -c -
```

Do not continue if the checksum does not report `OK`.

## 3. Mark application files as package-managed

Alpine normally protects everything under `/etc` from replacement. Nocturne's
upstream image places the application there, so install two narrow exclusions
before the first `apk add`:

```sh
install -d -m 0755 /etc/apk/protected_paths.d
cat > /etc/apk/protected_paths.d/nocturne-connector-plus.list <<'EOF'
-etc/nocturne-connector/api
-etc/nocturne-connector/version
EOF
```

These exclusions do not match any of the persistent state files, including:

- `/etc/nocturne-connector/auth-session.json`
- `/etc/nocturne-connector/setup-state.json`
- `/etc/nocturne-connector/analytics-enabled.json`
- `/etc/nocturne-connector/analytics-pending.json`
- `/etc/wpa_supplicant/wpa_supplicant.conf`
- files under `/data/nocturne-connector`

The package's pre-install safety check refuses installation when the two rules
are missing.

## 4. Add the tagged APK repository

```sh
install -d -m 0755 /etc/apk/repositories.d
cat > /etc/apk/repositories.d/nocturne-connector-plus.list <<'EOF'
v2 @nocturneplus https://roach0816.github.io/NocturneConnectorPlus/apk/v3.24/main
EOF

apk update
```

The `@nocturneplus` tag prevents this repository from being used as a general
replacement for Alpine's official repositories.

Check what would be installed without changing the host:

```sh
apk add --simulate nocturne-connector-plus@nocturneplus
```

## 5. Install the package

```sh
apk add nocturne-connector-plus@nocturneplus
```

The package transaction stops `connector-api`, replaces the application,
installs a private Bun runtime, enables the required OpenRC services, restarts
the API, and waits up to 30 seconds for `/api/info`.

During the first install, existing `connector-api` and `wifi-import` OpenRC
files are preserved under
`/etc/nocturne-connector/pre-apk-service-backup/` before the package takes
ownership of their standard paths. These backups are not used while the
package is installed and are retained if the package is removed.

If the old proof-of-concept updater is present, installation prints a warning.
The package does not delete user-created files. Disable those commands after a
successful package installation so the two update methods cannot be mixed:

```sh
for file in \
  /usr/local/sbin/nocturne-update \
  /usr/local/sbin/nocturne-apply-service-override; do
  [ ! -e "$file" ] || mv "$file" "$file.legacy-disabled"
done
```

Verify the result:

```sh
apk info nocturne-connector-plus
apk policy nocturne-connector-plus
cat /etc/nocturne-connector/version
rc-service connector-api status
curl -fsS http://127.0.0.1/api/info
echo
curl -fsS http://127.0.0.1/api/auth/status
echo
```

Confirm that the service has the compatibility URL:

```sh
pid=$(pgrep -f '/usr/libexec/nocturne-connector-plus/bun' | head -n 1 || true)
if [ -n "$pid" ]; then
  tr '\0' '\n' < "/proc/$pid/environ" | grep '^NOCTURNE_SITE_URL='
fi
```

Expected value:

```text
NOCTURNE_SITE_URL=https://usenocturne.com
```

## 6. Upgrade when you choose

Repository publishing is automatic; installation on the Connector is manual:

```sh
apk update
apk upgrade nocturne-connector-plus
```

Then verify:

```sh
apk policy nocturne-connector-plus
curl -fsS http://127.0.0.1/api/info
echo
rc-service connector-api status
tail -n 100 /var/log/connector-api.log
```

## 7. Downgrade

The repository retains the five most recent signed versions. List them:

```sh
apk policy nocturne-connector-plus
```

Select an exact older Alpine version from that output. For example:

```sh
apk add 'nocturne-connector-plus@nocturneplus=2.0.4.1-r0'
```

The service restarts and receives the same health check after a downgrade.
Persistent state is not part of the application payload and remains in place.

## 8. Remove the package

```sh
apk del nocturne-connector-plus
```

Removal stops and disables the package-managed services and removes application
files. Persistent authentication, setup, analytics, and Wi-Fi state is retained.
The repository definition and public key are also retained so a later reinstall
remains possible.

## Troubleshooting

### Signature or index errors

```sh
sha256sum /etc/apk/keys/nocturne-connector-plus.rsa.pub
cat /etc/apk/repositories.d/nocturne-connector-plus.list
apk update
```

The public-key digest must be:

```text
8baff61619a855ac861cc805fb73d57537e5a6b453f364cee9de6f2b23217e88
```

Never use `--allow-untrusted` for this repository.

### The package refuses to install because protected-path rules are absent

Re-run section 3 exactly, then run `apk add` again. The refusal prevents Alpine
from leaving application replacements as `.apk-new` files.

### The package is marked broken or the API health check fails

```sh
rc-service connector-api status || true
tail -n 150 /var/log/connector-api.log
ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null || true
apk policy nocturne-connector-plus
```

Correct the reported problem and retry the package hook with:

```sh
apk fix nocturne-connector-plus
```

Or downgrade to an exact retained version as shown in section 7.

### Pair codes fail

```sh
cat /etc/conf.d/connector-api
rc-service connector-api restart
sleep 5
curl -fsS http://127.0.0.1/api/info
```

The configuration must set `NOCTURNE_SITE_URL` to
`https://usenocturne.com`.

### Insufficient root filesystem space

First clear only disposable APK cache data and retry:

```sh
apk cache clean 2>/dev/null || true
rm -rf /var/cache/apk/* 2>/dev/null || true
df -h /
```

If the physical disk is larger than the ext4 root partition, the following
conservative procedure supports only a normal MBR/GPT disk where root is the
final partition. Keep stable power throughout this operation.

Install the required tools, enabling the matching Alpine `community` repository
first if `cloud-utils-growpart` is unavailable:

```sh
apk add util-linux e2fsprogs e2fsprogs-extra cloud-utils-growpart
```

Detect and inspect the layout:

```sh
root_source=$(findmnt -n -o SOURCE /)
root_part=$(readlink -f "$root_source")
parent_name=$(lsblk -no PKNAME "$root_part" | tr -d '[:space:]')
part_num=$(lsblk -no PARTN "$root_part" | tr -d '[:space:]')
fstype=$(findmnt -n -o FSTYPE /)
disk="/dev/$parent_name"
last_part=$(lsblk -nrpo NAME,TYPE "$disk" \
  | awk '$2 == "part" {last=$1} END {print last}')

printf 'Root partition: %s\nDisk: %s\nPartition: %s\nFilesystem: %s\nLast partition: %s\n' \
  "$root_part" "$disk" "$part_num" "$fstype" "$last_part"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$disk"
sfdisk --dump "$disk"
```

Stop unless the filesystem is `ext4` and `root_part` exactly equals
`last_part`. Perform a dry run:

```sh
growpart -N "$disk" "$part_num"
```

If it reports a valid `CHANGE`, save the partition table and grow it:

```sh
backup="/root/partition-table-$(basename "$disk")-$(date +%Y%m%d-%H%M%S).txt"
sfdisk --dump "$disk" > "$backup"
chmod 0600 "$backup"
growpart "$disk" "$part_num"
sync
reboot
```

After reconnecting, re-detect root and expand the filesystem:

```sh
root_part=$(readlink -f "$(findmnt -n -o SOURCE /)")
resize2fs "$root_part"
df -h /
```

Do not use this procedure when root is not the final partition, when the
filesystem is not ext4, or when any detected value is unexpected.

## Scope and limitations

- The package follows stable releases from
  `usenocturne/nocturne-connector` and records the exact source commit.
- It updates the API/client application, private Bun runtime, `connector-api`,
  and `wifi-import`.
- It does not upgrade Alpine Linux, the kernel, firmware, bootloader, partition
  scheme, or image-level A/B updater.
- A full-image reflash or upstream image OTA may replace the package-managed
  files and require repository setup again.
