#!/usr/bin/env python3
"""End-to-end acceptance test for the vphone semantic control subsystem."""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "integrations" / "vphone-mcp"))
from vphone_mcp import server as vp  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def wait_guest(vm: str, timeout: float = 120.0) -> dict:
    deadline = time.monotonic() + timeout
    streak = 0
    last: dict = {}
    while time.monotonic() < deadline:
        try:
            last = vp.guest_status(vm)
            ready = last.get("connected") and "accessibility_semantic" in last.get("capabilities", [])
            streak = streak + 1 if ready else 0
            if streak >= 2:
                return last
        except Exception:
            streak = 0
        time.sleep(1)
    raise TimeoutError(f"guest bridge did not stabilize: {last}")


def find(vm: str, **selector) -> dict:
    return vp.ui_find(vm=vm, **selector)


def ensure_settings_root(vm: str) -> None:
    deadline = time.monotonic() + 30.0
    nudged_unlock = False
    while time.monotonic() < deadline:
        try:
            vp.app_launch("com.apple.Preferences", vm=vm)
            time.sleep(0.8)
            status = vp.ui_status(vm)
            if status.get("frontmost_context", {}).get("bundleId") == "com.apple.Preferences":
                break
        except Exception:
            pass

        # If SpringBoard semantics expose the Settings icon, use that instead of
        # guessing whether the device is locked or LaunchServices is still warming.
        try:
            settings = find(vm, label="Settings")
            if settings.get("ok"):
                vp.ui_tap(label="Settings", vm=vm)
                time.sleep(0.8)
                continue
        except Exception:
            pass

        if not nudged_unlock:
            unlocked = vp.device_unlock(vm)
            if not unlocked.get("ok"):
                raise AssertionError(f"worker could not unlock semantically: {unlocked}")
            nudged_unlock = True
        time.sleep(1)
    else:
        raise AssertionError("Settings did not become launchable after cold boot")

    for _ in range(5):
        general = find(vm, label="General")
        if general.get("ok"):
            return
        back = find(vm, label="Settings")
        if back.get("ok"):
            vp.ui_tap(label="Settings", vm=vm)
            time.sleep(0.6)
            continue
        time.sleep(0.5)
    raise AssertionError("could not reach Settings root")


def tap_point(node: dict) -> tuple[float, float]:
    point = node.get("tap") or node.get("center_point") or {}
    return float(point.get("x", 0)), float(point.get("y", 0))


def run_acceptance(vm: str) -> dict:
    report: dict[str, object] = {"vm": vm, "checks": {}}
    checks: dict[str, object] = report["checks"]  # type: ignore[assignment]

    guest = wait_guest(vm)
    require(guest.get("connected") is True, "guest bridge is disconnected")
    require("accessibility_semantic" in guest.get("capabilities", []), "semantic capability missing")
    checks["guest"] = {"variant": guest.get("variant"), "capabilities": guest.get("capabilities")}

    status = vp.ui_status(vm)
    runtime = status.get("runtime", {})
    require(status.get("broker_ready") == 1, "AX broker not ready")
    require(runtime.get("clientIdentifier") == "VOTAXUIClientIdentifier", "VoiceOver AX client not active")
    checks["bootstrap"] = {"broker_ready": True, "client": runtime.get("clientIdentifier")}

    ensure_settings_root(vm)
    general = find(vm, label="General")
    require(general.get("ok") and general.get("match_count") == 1, "General is not a unique semantic match")
    gx, gy = tap_point(general["node"])
    require((gx, gy) != (0.0, 0.0), "General resolved to sentinel tap point")
    checks["find"] = {"label": "General", "tap": [gx, gy]}

    tapped = vp.ui_tap(label="General", vm=vm)
    require(tapped.get("ok"), "semantic tap on General failed")
    about_wait = vp.ui_wait(label="About", condition="present", timeout=8, interval=0.3, vm=vm)
    require(about_wait.get("ok"), "General navigation did not expose About")
    about = about_wait["result"]["node"]
    checks["tap_wait"] = {"destination": about.get("text"), "generation": about_wait["result"].get("generation")}

    ax, ay = tap_point(about)
    hit = vp.ui_at_point(ax, ay, vm=vm)
    require(hit.get("ok"), "semantic hit-test failed on About")
    hit_text = json.dumps(hit.get("node", {}), ensure_ascii=False)
    require("About" in hit_text, "hit-test did not resolve About semantics")
    checks["hit_test"] = {"point": [ax, ay]}

    ambiguous = find(vm, role="control")
    require(not ambiguous.get("ok") and ambiguous.get("error") == "ambiguous", "ambiguous selector was not rejected")
    require(int(ambiguous.get("match_count", 0)) > 1, "ambiguity did not include multiple candidates")
    checks["ambiguity"] = {"match_count": ambiguous.get("match_count")}

    absent = vp.ui_wait(
        label="__vphone_semantic_never_exists__", condition="absent",
        timeout=2, interval=0.25, vm=vm,
    )
    require(absent.get("ok"), "absent semantic wait failed")
    checks["wait_absent"] = True

    full = vp.ui_tree(vm=vm, mode="full", max_depth=8, max_elements=120, visible_only=True)
    require(full.get("ok") and full.get("root"), "bounded full semantic tree failed")
    count = int(full.get("element_count", 0))
    require(0 < count <= 120, f"unexpected bounded tree size: {count}")
    checks["full_tree"] = {"elements": count, "generation": full.get("generation")}

    vp.ui_tap(label="Settings", vm=vm)
    time.sleep(0.8)
    search = find(vm, role="search_field")
    require(search.get("ok") and search.get("match_count") == 1, "Settings search field not found")
    typed = vp.ui_type("Bluetooth", role="search_field", method="paste", verify=True, vm=vm)
    require(typed.get("ok") and typed.get("typed", {}).get("typed"), "semantic typing failed")
    after = typed.get("resolved_after", {})
    require(after.get("ok"), "search field did not resolve after typing")
    tx, ty = tap_point(after.get("node", {}))
    require((tx, ty) != (0.0, 0.0), "post-type search field kept sentinel AX tap point")
    checks["type_verify"] = {"query": "Bluetooth", "tap_after": [tx, ty]}

    foreground = vp.app_foreground(vm)
    require(foreground.get("bundle_id") == "com.apple.Preferences", f"foreground app mismatch: {foreground}")
    checks["foreground"] = foreground

    final_status = vp.ui_status(vm)
    require(final_status.get("semantic_operational") is True, "semantic operational health bit is false")
    checks["operational"] = True

    final_guest = vp.guest_status(vm)
    require(final_guest.get("variant") == "jb", f"guest variant mismatch: {final_guest.get('variant')}")
    checks["variant"] = "jb"
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vm", nargs="?", default="codex-semantic")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    started = time.monotonic()
    try:
        report = run_acceptance(args.vm)
        report["ok"] = True
        report["duration_seconds"] = round(time.monotonic() - started, 3)
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0
    except Exception as exc:
        report = {
            "ok": False,
            "vm": args.vm,
            "duration_seconds": round(time.monotonic() - started, 3),
            "error": f"{type(exc).__name__}: {exc}",
        }
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
