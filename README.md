# tailscale-openwrt-build

Automated, size-optimised [Tailscale](https://tailscale.com) builds for OpenWRT routers.  
Produces `.ipk` packages with aggressive feature stripping + UPX compression — small enough for devices with ≤16 MB flash.

## Size budget

| Stage | Estimated |
|---|---|
| Full combined binary (mipsle) | ~25–30 MB |
| After `-s -w` strip | ~18–22 MB |
| After aggressive `ts_omit` tags | ~10–14 MB |
| After UPX `--best --lzma` | **~4–6 MB** |

## Quick start — install on your router

1. **Add the feed** — edit `/etc/opkg/customfeeds.conf`:

   ```
   src/gz tailscale https://hibiyasleep.github.io/tailscale-openwrt-build/packages/mipsle_softfloat
   ```

   Replace `mipsle_softfloat` with your device's architecture (see [Architectures](#architectures)).

2. **Install:**

   ```sh
   opkg update
   opkg install tailscale
   ```

3. **Start & authenticate:**

   ```sh
   /etc/init.d/tailscale enable
   /etc/init.d/tailscale start
   tailscale up
   ```

## Architectures

Controlled by the `ARCHITECTURES` array in [`build.conf`](build.conf).  
Format: `GOARCH:VARIANT` — the variant maps to `GOMIPS`, `GOARM`, etc.

| Spec | Target | Feed path |
|---|---|---|
| `mipsle:softfloat` | MIPS little-endian soft-float (many MediaTek routers) | `packages/mipsle_softfloat` |
| `mips:softfloat` | MIPS big-endian soft-float (Atheros/QCA) | `packages/mips_softfloat` |
| `arm:7` | ARMv7 (Cortex-A) | `packages/arm_7` |
| `arm:6` | ARMv6 (RPi 1 / Zero class) | `packages/arm_6` |
| `arm64:` | AArch64 | `packages/arm64` |
| `amd64:` | x86-64 | `packages/amd64` |

Uncomment the lines you need:

```bash
ARCHITECTURES=(
  mipsle:softfloat
  # mips:softfloat
  # arm:7
  # arm:6
  # arm64:
  # amd64:
)
```

## Configuration

Everything lives in [`build.conf`](build.conf):

| Variable | Purpose |
|---|---|
| `TAILSCALE_VERSION` | `"latest"` (auto-detect) or a pinned tag like `"v1.78.1"` |
| `ARCHITECTURES` | Array of `GOARCH:VARIANT` targets |
| `OMIT_TAGS` | Features to strip via `ts_omit_*` build tags |
| `INCLUDE_TAGS` | Extra build tags (default: `ts_include_cli` for combined binary) |
| `UPX_ENABLED` | `"true"` / `"false"` |

### Feature tags

The `OMIT_TAGS` list controls which Tailscale features are compiled out.  
Comment out a tag to **re-enable** that feature. The defaults are aggressive — suited for a headless router that only needs VPN routing.

<details>
<summary>Features kept by default</summary>

`dns`, `netstack`, `osrouter`, `health`, `advertiseroutes`, `useroutes`, `useexitnode`, `portmapper`, `logtail`, `c2n`, `captiveportal`, `iptables`

</details>

<details>
<summary>Features stripped by default (57 tags)</summary>

`ssh`, `serve`, `drive`, `taildrop`, `kube`, `aws`, `bird`, `synology`, `doctor`, `debug`, `debugeventbus`, `debugportmapper`, `tpm`, `posture`, `systray`, `qrcodes`, `webclient`, `tap`, `relayserver`, `wakeonlan`, `colorable`, `completion`, `completion_scripts`, `capture`, `desktop_sessions`, `identityfederation`, `oauthkey`, `outboundproxy`, `acme`, `ace`, `conn25`, `cloud`, `netlog`, `hujsonconf`, `linkspeed`, `networkmanager`, `resolved`, `sdnotify`, `webbrowser`, `usermetrics`, `clientmetrics`, `clientupdate`, `appconnectors`, `tailnetlock`, `bakedroots`, `peerapiclient`, `peerapiserver`, `cachenetmap`, `lazywg`, `linuxdnsfight`, `listenrawdisco`, `syspolicy`, `unixsocketidentity`, `useproxy`, `gro`, `portlist`, `dbus`

</details>

## Local builds

```sh
# Build all enabled architectures
./build.sh

# Build a single target
./build.sh mipsle:softfloat

# Package all
./package.sh

# Package a single target
./package.sh arm:7
```

Requires: Go 1.22+, `git`, `curl`, `jq`, `ar`, and optionally `upx`.

## CI workflow

The [GitHub Actions workflow](.github/workflows/build.yml) has three jobs:

1. **`prepare`** — resolves the Tailscale version, checks for existing release, generates the architecture matrix from `build.conf`.
2. **`build`** — matrix job: one parallel runner per architecture. Compiles, compresses, packages `.ipk`, uploads artifacts.
3. **`release`** — collects all `.ipk` artifacts, creates a GitHub Release, deploys the opkg feed to `gh-pages`.

Trigger a manual build from the Actions tab — you can optionally pin a version:

> Actions → Build Tailscale for OpenWRT → Run workflow → `tailscale_version: v1.78.1`

## Credits

Inspired by [du-cki/openwrt-tailscale](https://github.com/du-cki/openwrt-tailscale) and [lanrat/openwrt-tailscale-repo](https://github.com/lanrat/openwrt-tailscale-repo).

## License

The build scripts in this repository are provided as-is.  
Tailscale itself is licensed under the [BSD 3-Clause License](https://github.com/tailscale/tailscale/blob/main/LICENSE).

