# tailscale-openwrt-build

Small [Tailscale](https://tailscale.com) `.ipk` builds for OpenWRT routers;
aggressive feature stripping plus UPX compression to fit devices with little flash.

A weekly CI job cross-compiles the latest release for several architectures and
publishes a signed opkg feed to GitHub Pages.

## Install on your router

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

**Architectures** are the names `opkg print-architecture` reports on the device;
they must match exactly or opkg rejects the package. The Go toolchain settings
(`GOARCH`/`GOMIPS`/`GOARM`) are derived from each name in `build.sh`. The feed
path always equals the arch name (`packages/<arch>`).

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
./package.sh               # package all into .ipk + feed index
./package.sh mipsel_24kc   # package one
```

Requires Go 1.22+, `git`, `curl`, `jq`, and optionally `upx`. To sign the feed
locally, point `USIGN_SEC` at a `usign` secret-key file; otherwise the feed is
left unsigned.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs weekly (and on
demand) in three jobs: **prepare** resolves the version and builds the arch
matrix from `build.conf`; **build** compiles, compresses, and packages each arch
in parallel; **release** publishes a GitHub Release and deploys the opkg feed to
`gh-pages`. Manual runs (Actions → *Run workflow*) can pin a version and pick a
mode (*Normal* / *Test* / *Re-release*).

### Feed signing

The opkg index is signed with [`usign`](https://git.openwrt.org/?p=project/usign.git).
The public key ([`tailscale-feed.pub`](tailscale-feed.pub), keynum
`7e4a00c1131ea1d0`) is committed and shipped to users; the private key lives in
the `USIGN_SECRET_KEY` repository secret. Without it the build still succeeds but
emits an unsigned feed. To rotate: `usign -G -s new.sec -p new.pub`, then update
`tailscale-feed.pub`, the keynum above, and the secret.

## Credits

Inspired by [du-cki/openwrt-tailscale](https://github.com/du-cki/openwrt-tailscale)
and [lanrat/openwrt-tailscale-repo](https://github.com/lanrat/openwrt-tailscale-repo).
Tailscale is licensed under the
[BSD 3-Clause License](https://github.com/tailscale/tailscale/blob/main/LICENSE).
