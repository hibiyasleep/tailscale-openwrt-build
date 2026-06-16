# tailscale-openwrt-build

Small [Tailscale](https://tailscale.com) builds for OpenWRT routers; aggressive
feature stripping plus UPX compression to fit devices with little flash.

A weekly CI job cross-compiles the latest release for several architectures and
publishes both package formats to GitHub Pages: a signed **opkg** feed (`.ipk`,
OpenWRT ≤24) and a signed **apk** feed (`.apk`, OpenWRT 25+, which replaced opkg
with Alpine's `apk`).

## Install on your router

Pick the path for your OpenWRT version — 25.x and later use `apk`; 24.10 and
earlier use `opkg`.

### OpenWRT 25+ (apk)

1. **Trust the feed signing key.** apk verifies the repository index signature,
   so install the public key into `/etc/apk/keys/` first:

   ```sh
   cat > /etc/apk/keys/tailscale-apk.pem <<'EOF'
   -----BEGIN PUBLIC KEY-----
   MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE5kXgjJriRKXp0tNxAtJSDpq44oO9
   LgFQzYMOsHw1SEVP/xZxwOWp3KwpXeoqVwDmRC/qtSmG33AfqUqPYNxpKQ==
   -----END PUBLIC KEY-----
   EOF
   ```

2. **Add the feed**, using your device's arch (run `apk --print-arch` to find
   it). The URL points at the index file itself (`packages.adb`):

   ```sh
   echo "https://hibiyasleep.github.io/tailscale-openwrt-build/packages/mipsel_24kc/packages.adb" \
     > /etc/apk/repositories.d/tailscale.list
   ```

3. **Install** (the post-install hook enables and starts the service):

   ```sh
   apk update
   apk add tailscale
   tailscale up
   ```

### OpenWRT ≤24 (opkg)

1. **Trust the feed signing key.** Stock OpenWRT verifies feed signatures, so
   install the public key first. The file *must* be named after the key's
   fingerprint:

   ```sh
   cat > /etc/opkg/keys/7e4a00c1131ea1d0 <<'EOF'
   untrusted comment: public key 7e4a00c1131ea1d0
   RWR+SgDBEx6h0LTMVke+FNmp7a2cTl0eTif3hUVu9d1WTdvvn/i2ltYG
   EOF
   ```

   Alternatively, you may disable the signature check entirely by setting
   `option check_signature` to `0` (or removing the line) in `/etc/opkg.conf`;
   simpler, but the feed is then unverified.

2. **Add the feed** to `/etc/opkg/customfeeds.conf`, using your device's arch
   (run `opkg print-architecture` to find it):

   ```
   src/gz tailscale https://hibiyasleep.github.io/tailscale-openwrt-build/packages/mipsel_24kc
   ```

3. **Install:**

   ```sh
   opkg update
   opkg install tailscale
   ```

4. **Start and authenticate:**

   ```sh
   /etc/init.d/tailscale enable
   /etc/init.d/tailscale start
   tailscale up
   ```

## Configuration

Everything is driven by [`build.conf`](build.conf):

| Variable | Purpose |
|---|---|
| `TAILSCALE_VERSION` | `"latest"` (auto-detect) or a pinned tag like `"v1.78.1"` |
| `ARCHITECTURES` | opkg arch names to build (e.g. `mipsel_24kc`) |
| `FEATURES` | Tailscale features to **keep**; everything else is stripped |
| `UPX_ENABLED` | `"true"` / `"false"` |

**Architectures** are the names `opkg print-architecture` (or `apk --print-arch`)
reports on the device — apk reuses the same names — and they must match exactly
or the package is rejected. The Go toolchain settings (`GOARCH`/`GOMIPS`/`GOARM`)
are derived from each name in `build.sh`. The feed path always equals the arch
name (`packages/<arch>`).

**Features** is a keep-list: the build passes it to Tailscale's `cmd/featuretags`
tool with `--min --add`, compiling out everything except the listed features and
their dependencies. The defaults target a headless router (subnet routing, exit
nodes, MagicDNS). `osrouter`, `iptables`, and `unixsocketidentity` are mandatory:
without the first two `tailscaled` can't program the routing table (and MIPS has no
nftables backend), and without `unixsocketidentity` the LocalAPI denies every
request, so `tailscale up` fails with `Access denied: status access denied`.
See the comments in `build.conf` for the full annotated list.

## Local builds

```sh
./build.sh                 # build all architectures in build.conf
./build.sh mipsel_24kc     # build one
./package.sh               # package all into .ipk + opkg feed index
./package.sh mipsel_24kc   # package one
./package-apk.sh           # package all into .apk + apk feed index (packages.adb)
./package-apk.sh mipsel_24kc
```

Both packagers consume the same `tailscale.combined.<arch>` binaries from
`build.sh` and write into the same `feed/packages/<arch>/` tree, where opkg's
`Packages` and apk's `packages.adb` coexist.

Requires Go 1.22+, `git`, `curl`, `jq`, and optionally `upx`. Building `.apk`
additionally needs [apk-tools 3](https://gitlab.alpinelinux.org/alpine/apk-tools)
(the `apk` CLI with `mkpkg`/`mkndx` — apk-tools 2 won't do) plus `fakeroot` to
record `root:root` file ownership. `fakeroot` only works on Linux; on macOS it is
a no-op under SIP, so locally built `.apk`s carry the build user's uid — fine for
testing, but CI (Linux) produces the canonical packages.

To sign locally, point `USIGN_SEC` at a `usign` secret-key file (opkg) and/or
`APK_SIGN_KEY` at the apk EC private key (apk); otherwise the feeds are left
unsigned. `APK_RELEASE` (default `1`) sets the apk `-r<N>` release suffix.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs weekly (and on
demand) in three jobs: **prepare** resolves the version and builds the arch
matrix from `build.conf`; **build** compiles and compresses each arch in
parallel, then packages it into both `.ipk` and `.apk` (building apk-tools 3 from
source first, since it isn't packaged for Ubuntu); **release** publishes a GitHub
Release and deploys the combined opkg + apk feed to `gh-pages`. Manual runs
(Actions → *Run workflow*) can pin a version and pick a mode (*Normal* / *Test* /
*Re-release*).

### Feed signing

Each feed has its own signing key; both public keys ship to users and both
private keys live in repository secrets. Without a key the build still succeeds
but emits that feed unsigned.

- **opkg** — the `Packages` index is signed with
  [`usign`](https://git.openwrt.org/?p=project/usign.git). Public key
  ([`tailscale-feed.pub`](tailscale-feed.pub), keynum `7e4a00c1131ea1d0`) is
  committed; private key in the `USIGN_SECRET_KEY` secret. Rotate with
  `usign -G -s new.sec -p new.pub`, then update `tailscale-feed.pub`, the keynum,
  and the secret.
- **apk** — the `packages.adb` index is signed with an OpenSSL EC (`prime256v1`)
  key; individual packages are left unsigned (apk derives package integrity from
  the signed index, matching OpenWRT's own scheme). Public key
  ([`tailscale-apk.pem`](tailscale-apk.pem)) is committed and installed to
  `/etc/apk/keys/` on the device; private key in the `APK_SIGN_KEY` secret.
  Rotate with:

  ```sh
  openssl ecparam -name prime256v1 -genkey -noout -out tailscale-apk.sec
  openssl ec -in tailscale-apk.sec -pubout -out tailscale-apk.pem
  ```

  then commit the new `tailscale-apk.pem` and update the `APK_SIGN_KEY` secret
  (`gh secret set APK_SIGN_KEY < tailscale-apk.sec`).

## Credits

Inspired by [du-cki/openwrt-tailscale](https://github.com/du-cki/openwrt-tailscale)
and [lanrat/openwrt-tailscale-repo](https://github.com/lanrat/openwrt-tailscale-repo).
Tailscale is licensed under the
[BSD 3-Clause License](https://github.com/tailscale/tailscale/blob/main/LICENSE).
