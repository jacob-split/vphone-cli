# Codex control for vphone-cli

This repository includes an owned MCP server under `integrations/vphone-mcp` so Codex can create, launch, inspect, manipulate, and debug virtual iPhones without depending on the limited external `vphone-mcp` wrapper.

## Host profile

On an 8 GB Apple Silicon Mac, the local defaults are 4 vCPUs and 4096 MB guest RAM. The virtual disk remains a sparse 64 GB file, so it grows as the guest writes data instead of reserving 64 GB immediately.

The canonical `codex-semantic` worker is right-sized to 2 vCPUs and 4096 MB RAM. It is kept stopped between VPhone tasks; use `scripts/install_semantic_worker.sh codex-semantic` to start it and `scripts/uninstall_semantic_worker.sh codex-semantic` to park it afterward. Its IPSW cache is intentionally empty because normal boot does not require restore media.

Codex VM creation defaults to the `jb` variant because semantic UI control requires the SpringBoard tweak-loading path. `jb` and `exp` install VPhoneAX automatically; `regular`, `dev`, and `less` do not currently provide the SpringBoard semantic broker.

## One-time host security gate

PV=3 research guests require host policy changes that cannot be made from a normal macOS session. If `scripts/boot_host_preflight.sh` reports `Allow Research Guests status: disabled`, boot Recovery OS and run:

```sh
csrutil allow-research-guests enable
```

With SIP already fully disabled, the shortest AMFI path documented by this project is then, from normal macOS:

```sh
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

Reboot before testing. Re-run `scripts/boot_host_preflight.sh --assert-bootable` after the reboot.

Use the `vphone-amfidont` path instead only if intentionally switching to the narrower SIP/debug-relaxed configuration documented in the main README.

## Install the Codex MCP

After dependencies and the signed app bundle are built:

```sh
./scripts/install_codex_mcp.sh
```

The installer creates an isolated `.mcp-venv`, installs the MCP package, installs `~/.codex/bin/vphone-mcp`, and adds a non-required `vphone` stdio server to `~/.codex/config.toml` without changing global Codex approval policy.

## Control surface

The MCP exposes VM lifecycle, host doctor, screenshots, raw touch/swipe/keys, app lifecycle, IPA installation, guest files, clipboard, URLs, settings, Developer Mode status, low-power mode, simulated location, virtual camera, host screen recording, Touch ID forwarding, battery simulation, keychain access, and a raw vphoned request escape hatch.

Semantic UI control is the preferred automation path. `VPhoneAX.dylib` runs only inside SpringBoard, dynamically boots AXRuntime/AccessibilityUI, resolves the frontmost application, and serves semantic UI over `/var/mobile/Library/VPhoneAX/vphone-ax.sock`. `vphoned` proxies that broker over vsock; Codex never connects to SpringBoard directly. The JB CFW installer builds, signs, and stages VPhoneAX automatically. Vendored AXRuntime bridge code under `scripts/vphoneax/vendor/ios-mcp` retains its MIT license.

Codex semantic tools are `ui_status`, `ui_bootstrap`, `ui_tree`, `ui_find`, `ui_tap`, `ui_type`, `ui_wait`, and `ui_at_point`. Compact semantic queries are the default. Full trees are bounded to prevent runaway AX traversals. Selectors prefer exact accessibility identifiers, then role/label/value matches; equal-best matches return `ambiguous` instead of choosing silently. Semantic actions re-query immediately before acting, so a previously returned rectangle is never trusted as the action target.

`ui_type` first resolves and taps the field, then uses guest clipboard plus Cmd-V for Unicode-safe input by default; `method=keys` retains the ASCII key-event path. `ui_wait` polls semantic state rather than screenshots. Screenshots remain the visual verification/fallback layer when an application exposes poor accessibility metadata.

Screenshots are returned as MCP image content. Large binary transfers use explicit host paths instead of embedding base64 in JSON. The host Unix socket is owner-only (`0600`). Keychain values are redacted unless `include_values=true` is requested explicitly.

## M1 firmware patch fix

Builds apply `scripts/patches/libcapstone-opcount-oob.patch` to the pinned `vendor/libcapstone-spm` checkout before compilation. The build fails instead of silently continuing if the patch stops applying cleanly after an upstream submodule change.

## Semantic acceptance and broker updates

Validate an already bootable JB VM with the full semantic contract:

```sh
.mcp-venv/bin/python scripts/test_semantic_vm.py codex-semantic
```

The acceptance pass verifies AX bootstrap, unique selectors, semantic tap/navigation, waits, hit testing, ambiguity rejection, bounded full trees, Unicode-safe typing with verification, foreground-app identity, the `semantic_operational` health bit, and JB variant preservation.

For an existing JB VM, a VPhoneAX broker update must be persisted into the offline Preboot volume rather than copied only through the running guest. Stop the VM, then run:

```sh
./scripts/update_vphoneax_vm.sh ~/.vphone/VMs/codex-semantic /path/to/signed/VPhoneAX.dylib
```

The updater mounts only the stopped VM disk, replaces the canonical VPhoneAX dylib/filter plist in the Procursus tweak directory, syncs, and detaches. Newly created JB/EXP VMs receive the current broker through the normal CFW installer.
