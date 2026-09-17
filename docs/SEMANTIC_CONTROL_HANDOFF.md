# VPhone Semantic Control — Handoff

Date: 2026-09-17
Branch: `codex/vphone-codex-integration`
Verified runtime implementation: `dd0878c`

## Final state

The `codex-semantic` JB virtual iPhone is operational as the canonical headless Codex/VPhone semantic-control target. It is configured for 2 vCPUs and 4096 MB RAM and is normally parked with no LaunchAgent or VM process running. Start it for a VPhone task with `scripts/install_semantic_worker.sh codex-semantic`, then stop and unregister it afterward with `scripts/uninstall_semantic_worker.sh codex-semantic`.

The latest right-sized cold-boot validation passed the complete end-to-end acceptance suite with `ok: true` in 55.45 seconds at 2 vCPUs and 4096 MB RAM. The 2 GB and 3 GB memory trials were rejected after readiness or semantic-navigation failures. `git diff --check` also passes.

The active stack is:
- host `.build/vphone-cli.app` and its owner-only `vphone.sock`;
- `vphoned` in the JB guest over vsock 1337;
- `VPhoneAX.dylib` injected into SpringBoard;
- AXRuntime / AccessibilityUI with client `VOTAXUIClientIdentifier`;
- MCP tools in `integrations/vphone-mcp` for semantic UI, apps, files, clipboard, settings and the rest of the VPhone control plane.

## Verified acceptance

The final `scripts/test_semantic_vm.py codex-semantic` run verified:
- JB guest and `accessibility_semantic` capability;
- VPhoneAX broker ready and VoiceOver AX client initialized;
- cold-boot lock-state recovery and interactive unlock;
- Settings foreground launch;
- semantic `General → About` navigation;
- point hit-testing and bounded semantic tree retrieval;
- ambiguous selectors return candidates instead of guessing;
- presence/absence waits;
- semantic text entry and verification using the Settings Search field (`Bluetooth`);
- foreground identity `com.apple.Preferences` / Settings;
- top-level `semantic_operational=true`.
## Important implementation decisions

Unlock is authoritative, not inferred from foreground process changes. VPhoneAX reads SpringBoard's `SBLockScreenManager.isUILocked`, then performs `startUIUnlockFromSource:0` plus `_finishUIUnlockFromSource:withOptions:`, dismisses Cover Sheet, and wakes the interactive display before reporting success.

Semantic activation does not depend on virtual touch. The reliable action path re-resolves the target and invokes the private `AXElement` wrapper's native `press` selector. Public `AXUIElementPerformAction("AXPress")` remains only a fallback because iOS 27 returned generic AX failure `-25200` for valid Settings rows.

Semantic typing similarly uses the AXElement wrapper (`insertText:`) and matches compact semantic aliases as well as primary text. This is required for controls such as the Settings node `Search field`, whose native AX wrapper is labeled `Search`.

Semantic geometry rejects unusable AX activation points outside the visible element and uses the visible rect center instead. Example: Settings General reports a stale center around y=854 while its visible row is y=660–716; the actionable semantic point is y=688.

VPhoneAX requests are bounded so a stale or booting SpringBoard broker cannot monopolize `vphoned`'s serial control loop. Broker connection setup is nonblocking with hard deadlines, and broker work is guarded by an outer deadline.

`vphoned` also keeps a bounded idle timeout on established vsock sessions. This is required because a guest userspace transition can leave a half-stale accepted client; the timeout returns the daemon to `accept()` so the host reconnect watchdog can bind to the new session automatically.

Headless workers do not auto-forward host CoreLocation on connect. Explicit `location_set` remains supported. This avoids a private location-simulation call blocking the serial guest control loop during boot.
## Runtime and recovery notes

The signed/current `vphoned` build is persisted into the cold-boot VM anchor. At final verification, the built daemon, app-bundled daemon and VM staging daemon all matched SHA-256 `64190fa9c424afb095a8cf5838714635bdb9a112957b83dac43badde86e9ed32`.

The guest normally performs a userspace transition during JB boot. Do not treat the first brief disconnect/reset as final failure. The current reconnect/idle-timeout logic is designed to recover automatically; judge readiness using `guest_ping` plus `ui_status`, not a single early connection attempt.

The host security prerequisites remain SIP disabled, Research Guests enabled, and `amfi_get_out_of_my_way=1 -v` in boot args. Preserve the active iOS tooling/runtime required by this project.

The firmware IPSW cache is not required for normal VM boot or semantic operation and is intentionally empty. A rebuild, restore or VM recreation must download the required IPSWs again. Keep the active sparse `Disk.img` on local Mac storage while the VM is running; do not place the writable image on SSHFS or NFS.

## Resume / verification

```sh
cd /Users/jacob/Developer/vphone-cli
git switch codex/vphone-codex-integration
scripts/install_semantic_worker.sh codex-semantic
launchctl print gui/$(id -u)/com.split.vphone.codex-semantic
.mcp-venv/bin/python scripts/test_semantic_vm.py codex-semantic
scripts/uninstall_semantic_worker.sh codex-semantic
git diff --check
```

If the worker needs reinstalling, use `scripts/install_semantic_worker.sh codex-semantic`; it removes orphaned VPhone processes/socket ownership before installing the single LaunchAgent worker. Do not manually layer a second headless VM process beside the LaunchAgent.

## Scope

Generic VPhone/Codex semantic control is complete and verified. Application-specific test plans (for example, exhaustive Live-app workflows) are separate downstream work, not a blocker on this VPhone control-plane completion.
