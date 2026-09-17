# VPhone Semantic Control — Handoff

Date: 2026-09-16
Branch: `codex/vphone-codex-integration`
Base semantic commit: `79ee99c feat: add semantic vphone accessibility control`

## Current state

The semantic control subsystem is operational on the live `codex-semantic` JB VM.
The host security gate is fully satisfied:

- SIP disabled.
- Research Guests enabled.
- `kern.bootargs = amfi_get_out_of_my_way=1 -v`.
- Signed `vphone-cli --help` exits 0.

VM `codex-semantic` is a restored JB guest with 4 CPUs, 4096 MB RAM, a sparse 64 GB disk, iOS 27.0 / cloudOS 26.4. Its current physical bundle size is about 20 GB.

The Mac currently has about 16 GiB raw APFS free space. Do not remove Xcode iOS DeviceSupport or the active iOS 27 simulator runtime.

## Semantic architecture

`VPhoneAX.dylib` is injected only into SpringBoard through the JB tweak loader. It dynamically initializes AXRuntime / AccessibilityUI and listens on `/var/mobile/Library/VPhoneAX/vphone-ax.sock`.

`vphoned` proxies semantic requests over vsock 1337. `VPhoneControl` and the host-control Unix socket expose those requests to the owned Codex MCP. Codex semantic tools are `ui_status`, `ui_bootstrap`, `ui_tree`, `ui_find`, `ui_tap`, `ui_type`, `ui_wait`, and `ui_at_point`.
## Verified live acceptance

On the live VM, `scripts/test_semantic_vm.py codex-semantic` passed with `ok: true` in 17.736 seconds. Verified:

- guest variant remains `jb` and advertises `accessibility_semantic`;
- SpringBoard broker is ready and identifies as `VOTAXUIClientIdentifier`;
- semantic find returns a unique target;
- semantic tap navigates and `ui_wait` observes the destination;
- point hit-testing works;
- ambiguous selectors return candidates instead of guessing;
- absence waits work;
- bounded full trees work;
- Unicode-safe typing is verified after input;
- foreground app identity resolves correctly (`com.apple.Preferences` / Settings during acceptance);
- top-level `semantic_operational` becomes true.

`VPhoneAX` and `vphoned` both compile successfully. MCP unit tests pass 6/6. `git diff --check` passes.

The broker persists in the guest and has loaded into SpringBoard across repeated launches. `/var/mobile/Library/VPhoneAX/vphoneax.log` shows AXRuntime, AccessibilityUI, the AXUIClient, application accessibility, and VoiceOver usage bootstrap all succeeding.

## Remaining work

1. Fix misleading diagnostic metadata: nested `accessibilityState.runtimeLikelyActive` / `axRuntimeMode` can still report inactive even while direct AX queries and top-level `semantic_operational` are working. Make status internally consistent without weakening the real operational check.
2. Tighten the `vphoned` self-update reconnect path. On cold boot the host can see repeated `ECONNRESET` retries for roughly a minute after pushing a new daemon binary. It eventually reconnects and passes acceptance, but startup should be fast and quiet.
3. Improve semantic normalization quality. Some SpringBoard nodes still normalize to generic `control`, and the raw `traits` attribute can serialize AX error `-25205` text. Filter unsupported AX values and infer stronger roles such as button/icon/tab item where evidence supports it.
4. Run Live-specific end-to-end validation: install/launch the current Live IPA, find real Live controls semantically, type into fields, verify navigation/state transitions, and exercise crash/relaunch/recovery. The generic Settings acceptance is complete; Live-specific coverage is not.
5. Keep semantics on `jb` as the canonical Codex path unless there is a concrete requirement for regular/dev variants. Those variants do not load the SpringBoard broker today.
6. Monitor storage. The VM bundle is ~20 GB physical and raw APFS free space is ~16 GiB. Avoid downloading duplicate firmware/reference fixture corpora. Preserve DeviceSupport.

## Runtime notes

A cold launch showed the expected semantic capability in the vphoned hello. After the daemon self-update/reconnect settled, host status was connected and listed `accessibility_semantic`.

`ui_status` then showed SpringBoard pid 42, broker ready, bootstrap complete, AXRuntime/AccessibilityUI loaded, AXUIClient created, application accessibility enabled, and VoiceOver usage confirmed. `ui_tree` returned usable home-screen labels and tap geometry before the full acceptance run.

Leave the currently running `codex-semantic` VM available for the next agent if possible; it can resume validation immediately instead of restoring again.

## Resume commands

```sh
cd /Users/jacob/Developer/vphone-cli
git switch codex/vphone-codex-integration
.build/vphone-cli.app/Contents/MacOS/vphone-cli vm info codex-semantic
.mcp-venv/bin/python scripts/test_semantic_vm.py codex-semantic
```

If the VM is stopped, launch with `.build/vphone-cli.app/Contents/MacOS/vphone-cli vm launch codex-semantic -v` and wait for the vphoned reconnect cycle before judging semantic status.
