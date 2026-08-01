# Nocturne Connector Plus

Nocturne Connector Plus packages the upstream Nocturne Connector application
layer as a normal, signed Alpine Linux package. The Connector host no longer
needs Git, a compiler toolchain, Bun's package cache, or several gigabytes of
temporary build space.

The initial target is the official Raspberry Pi Connector appliance running
Alpine 3.24 on `aarch64`.

## Install on a Connector

Run these commands as `root`:

```sh
install -d -m 0755 /etc/apk/keys \
  /etc/apk/repositories.d /etc/apk/protected_paths.d

wget -O /etc/apk/keys/nocturne-connector-plus.rsa.pub \
  https://roach0816.github.io/NocturneConnectorPlus/apk/nocturne-connector-plus.rsa.pub

echo '8baff61619a855ac861cc805fb73d57537e5a6b453f364cee9de6f2b23217e88  /etc/apk/keys/nocturne-connector-plus.rsa.pub' \
  | sha256sum -c -

cat > /etc/apk/protected_paths.d/nocturne-connector-plus.list <<'EOF'
-etc/nocturne-connector/api
-etc/nocturne-connector/version
EOF

cat > /etc/apk/repositories.d/nocturne-connector-plus.list <<'EOF'
v2 @nocturneplus https://roach0816.github.io/NocturneConnectorPlus/apk/v3.24/main
EOF

apk update
apk add nocturne-connector-plus@nocturneplus
```

The protected-path exclusions apply only to packaged application files.
Authentication, setup, analytics, and Wi-Fi state remain normal protected
configuration.

See [nocturne-update-setup-guide.md](nocturne-update-setup-guide.md) for
preflight checks, migration from the proof-of-concept updater, upgrades,
downgrades, troubleshooting, and disk expansion guidance.

## Normal package operations

```sh
# Upgrade when you choose
apk update
apk upgrade nocturne-connector-plus

# Show the installed and available versions
apk policy nocturne-connector-plus

# Verify the service and API
rc-service connector-api status
curl -fsS http://127.0.0.1/api/info
```

Five signed package versions are retained in the repository. Downgrades use an
explicit version from `apk policy`:

```sh
apk add 'nocturne-connector-plus@nocturneplus=2.0.4.1-r0'
```

## Repository security

- Packages and `APKINDEX.tar.gz` are signed with the committed public key.
- Public-key SHA-256:
  `8baff61619a855ac861cc805fb73d57537e5a6b453f364cee9de6f2b23217e88`
- Every package release includes provenance recording the upstream tag and
  commit, source digest, Bun version and digest, package digest, and workflow
  run.
- Published versions are immutable. If an upstream tag moves, automation fails
  instead of replacing an existing package.

## Maintainer workflow

The daily and manually dispatched workflow in
`.github/workflows/publish-apk-repository.yml` performs the complete release:

1. Select the latest stable upstream release or a requested tag.
2. Validate the expected upstream layout and Alpine 3.24 baseline.
3. Verify the Bun release asset digest.
4. Build and test a signed APK in Alpine 3.24 on native ARM64.
5. Create an immutable GitHub package release.
6. Rebuild the five-version signed repository and deploy it with GitHub Pages.

One-time repository configuration is required:

1. Add the RSA private key as the Actions secret
   `ABUILD_PRIVATE_KEY_B64`.
2. In **Settings → Pages**, choose **GitHub Actions** as the publishing source.
3. Allow Actions read/write access so the workflow can create package releases
   and its monthly scheduler heartbeat commit.

To prepare a release locally without publishing:

```sh
scripts/prepare-release.sh v2.0.4-1 .work/aport
```

The generated directory contains an immutable source archive, verified Bun
archive, rendered `APKBUILD`, lifecycle files, and `release.env`. The actual APK
build must run natively on Alpine `aarch64` with an abuild signing key.

## Scope

This package updates the Nocturne application layer and its two related OpenRC
services. It does not update Alpine Linux, the kernel, firmware, bootloader,
partition scheme, or image-level A/B update components. Reimaging or applying
an upstream full-image OTA may replace this package-managed installation.
