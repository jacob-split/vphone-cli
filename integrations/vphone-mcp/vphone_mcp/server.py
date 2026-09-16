from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.utilities.types import Image

REPO = Path(os.environ.get("VPHONE_REPO", Path(__file__).resolve().parents[3])).expanduser().resolve()
VPHONE_ROOT = Path(os.environ.get("VPHONE_ROOT", Path.home() / ".vphone")).expanduser().resolve()
VM_ROOT = Path(os.environ.get("VPHONE_LIBRARY_ROOT", VPHONE_ROOT / "VMs")).expanduser().resolve()
VPHONE_BIN = Path(
    os.environ.get(
        "VPHONE_BIN",
        REPO / ".build" / "vphone-cli.app" / "Contents" / "MacOS" / "vphone-cli",
    )
).expanduser().resolve()
DEFAULT_VM = os.environ.get("VPHONE_DEFAULT_VM", "").strip() or None
DIRECT_SOCKET = os.environ.get("VPHONE_SOCK", "").strip() or None
LOG_ROOT = VPHONE_ROOT / "logs"

server = MCPServer(
    "vphone",
    description="Full Codex control plane for local vphone-cli virtual iPhones.",
    instructions=(
        "Resolve a running VM first. Prefer semantic ui_find/ui_tap/ui_type/ui_wait over coordinate UI "
        "automation, then app/file RPC operations, and use screenshots as a visual fallback/verification. "
        "Semantic actions re-resolve their target immediately before acting and return ambiguity instead "
        "of guessing. Sensitive keychain/raw requests are exposed for explicit use but should not be "
        "invoked unless needed."
    ),
)


def _existing_sockets() -> dict[str, Path]:
    found: dict[str, Path] = {}
    if DIRECT_SOCKET:
        p = Path(DIRECT_SOCKET).expanduser()
        if p.exists():
            found["direct"] = p
    if VM_ROOT.exists():
        for p in VM_ROOT.glob("*/vphone.sock"):
            if p.is_socket():
                found[p.parent.name] = p
    # Legacy/project-local layout used by older make-based workflows.
    legacy = REPO / "vm" / "vphone.sock"
    if legacy.exists() and legacy.is_socket():
        found.setdefault("legacy", legacy)
    return found


def _socket_for(vm: str | None = None) -> Path:
    sockets = _existing_sockets()
    requested = vm or DEFAULT_VM
    if requested:
        if requested in sockets:
            return sockets[requested]
        candidate = VM_ROOT / requested / "vphone.sock"
        if candidate.exists() and candidate.is_socket():
            return candidate
        raise RuntimeError(f"VM '{requested}' does not have a live vphone.sock")
    if len(sockets) == 1:
        return next(iter(sockets.values()))
    if not sockets:
        raise RuntimeError("No running vphone VM control socket found")
    raise RuntimeError(f"Multiple running VMs found ({', '.join(sorted(sockets))}); specify vm")


def _control(payload: dict[str, Any], vm: str | None = None, timeout: float = 60) -> dict[str, Any]:
    path = _socket_for(vm)
    raw = (json.dumps(payload, separators=(",", ":")) + "\n").encode()
    if len(raw) > 64 * 1024:
        raise ValueError("host-control request exceeds 64 KiB; use file-path transfer tools")
    chunks: list[bytes] = []
    total = 0
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(str(path))
        s.sendall(raw)
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        while True:
            chunk = s.recv(1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > 64 * 1024 * 1024:
                raise RuntimeError("host-control response exceeded 64 MiB")
    if not chunks:
        raise RuntimeError("empty response from vphone host control")
    line = b"".join(chunks).split(b"\n", 1)[0]
    response = json.loads(line)
    if not response.get("ok"):
        raise RuntimeError(response.get("error") or "vphone operation failed")
    return response


def _rpc(op: str, vm: str | None = None, screen: bool = False, **kwargs: Any) -> Any:
    payload: dict[str, Any] = {"t": "rpc", "op": op, "screen": screen}
    payload.update(kwargs)
    response = _control(payload, vm=vm)
    return response.get("data")


def _run_cli(args: list[str], timeout: int = 120) -> subprocess.CompletedProcess[str]:
    if not VPHONE_BIN.exists():
        raise RuntimeError(f"vphone binary not found: {VPHONE_BIN}; build the project first")
    result = subprocess.run(
        [str(VPHONE_BIN), *args], cwd=REPO, text=True, capture_output=True, timeout=timeout
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        if result.returncode in (137, -9):
            detail = (
                "signed vphone binary was killed by host execution policy; enable Research Guests in "
                "Recovery and complete the configured AMFI relaxation, then reboot"
            )
        raise RuntimeError(f"vphone-cli exit {result.returncode}: {detail}")
    return result


def _screen_result(response: dict[str, Any], label: str) -> list[Any]:
    result: list[Any] = [label]
    encoded = response.get("image")
    if encoded:
        result.append(Image(data=base64.b64decode(encoded), format="jpeg"))
    return result


def _command_text(command: list[str]) -> tuple[int, str]:
    try:
        p = subprocess.run(command, text=True, capture_output=True, timeout=8)
        return p.returncode, (p.stdout + p.stderr).strip()
    except Exception as exc:
        return -1, str(exc)


@server.tool()
def doctor() -> dict[str, Any]:
    """Inspect vphone host readiness without changing the Mac."""
    _, sip = _command_text(["csrutil", "status"])
    _, research = _command_text(["csrutil", "allow-research-guests", "status"])
    _, bootargs = _command_text(["sysctl", "-n", "kern.bootargs"])
    _, hv = _command_text(["sysctl", "-n", "kern.hv_support"])
    _, gatekeeper = _command_text(["spctl", "--status"])
    disk = shutil.disk_usage(Path.home())
    help_rc: int | None = None
    help_detail = "binary absent"
    if VPHONE_BIN.exists():
        try:
            p = subprocess.run([str(VPHONE_BIN), "--help"], text=True, capture_output=True, timeout=8)
            help_rc = p.returncode
            help_detail = (p.stderr or p.stdout).strip()[:500]
        except Exception as exc:
            help_rc, help_detail = -1, str(exc)
    dependencies = {
        name: shutil.which(name)
        for name in ["aria2c", "wget", "gtar", "ldid", "sshpass", "cmake", "ipsw"]
    }
    return {
        "repo": str(REPO),
        "binary": str(VPHONE_BIN),
        "binary_exists": VPHONE_BIN.exists(),
        "binary_help_returncode": help_rc,
        "binary_help_detail": help_detail,
        "sip": sip,
        "research_guests": research,
        "boot_args": bootargs,
        "hardware_virtualization": hv,
        "gatekeeper": gatekeeper,
        "disk_free_gib": round(disk.free / 1024**3, 2),
        "dependencies": dependencies,
        "running_sockets": {name: str(path) for name, path in _existing_sockets().items()},
    }


@server.tool()
def vm_list() -> list[dict[str, Any]]:
    """List configured virtual iPhones."""
    text = _run_cli(["vm", "list", "--json"]).stdout.strip()
    return json.loads(text or "[]")


@server.tool()
def vm_info(vm: str) -> dict[str, Any]:
    """Return configuration and restore information for one virtual iPhone."""
    text = _run_cli(["vm", "info", vm, "--json"]).stdout.strip()
    return json.loads(text)


@server.tool()
def vm_create(
    vm: str,
    variant: str = "jb",
    cpu: int = 4,
    memory_mb: int = 4096,
    disk_gb: int = 64,
) -> str:
    """Create a virtual iPhone end-to-end. Defaults to jb so the semantic VPhoneAX broker is installed."""
    if variant not in {"less", "regular", "dev", "jb", "exp"}:
        raise ValueError("variant must be less, regular, dev, jb, or exp")
    result = _run_cli(
        [
            "vm", "create", vm, "--variant", variant, "--cpu", str(cpu),
            "--memory", str(memory_mb), "--disk-size", str(disk_gb),
        ],
        timeout=60 * 90,
    )
    return result.stdout.strip() or "VM creation completed"


@server.tool()
def vm_clone(vm: str, new_vm: str) -> str:
    """Create an APFS copy-on-write clone with a fresh guest identity."""
    return _run_cli(["vm", "clone", vm, new_vm]).stdout.strip()


@server.tool()
def vm_launch(vm: str) -> dict[str, Any]:
    """Launch a virtual iPhone with its graphical surface and Codex control socket."""
    LOG_ROOT.mkdir(parents=True, exist_ok=True)
    log_path = LOG_ROOT / f"{vm}.log"
    log = open(log_path, "ab", buffering=0)
    proc = subprocess.Popen(
        [str(VPHONE_BIN), "vm", "launch", vm],
        cwd=REPO,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    return {"pid": proc.pid, "log": str(log_path), "vm": vm}


@server.tool()
def vm_stop(vm: str) -> str:
    """Stop a running virtual iPhone."""
    return _run_cli(["vm", "stop", vm]).stdout.strip()


@server.tool()
def vm_delete(vm: str) -> str:
    """Permanently delete a virtual iPhone bundle."""
    return _run_cli(["vm", "delete", vm, "--force"]).stdout.strip()


@server.tool()
def guest_status(vm: str | None = None) -> dict[str, Any]:
    """Return guest bridge state, iOS version, IP, capabilities, variant, and socket."""
    return _rpc("status", vm=vm)


@server.tool()
def guest_ping(vm: str | None = None) -> dict[str, Any]:
    """Check the vphoned request/response channel."""
    return _rpc("ping", vm=vm)


@server.tool()
def guest_version(vm: str | None = None) -> dict[str, Any]:
    """Return the running vphoned build hash."""
    return _rpc("version", vm=vm)


@server.tool()
def devmode_status(vm: str | None = None) -> dict[str, Any]:
    """Read Developer Mode status from the guest."""
    return _rpc("devmode_status", vm=vm)


@server.tool(structured_output=False)
def screenshot(vm: str | None = None, path: str | None = None) -> list[Any]:
    """Capture the current virtual iPhone screen; optionally save a full-resolution copy on the Mac."""
    payload: dict[str, Any] = {"t": "screenshot"}
    if path:
        payload["path"] = path
    response = _control(payload, vm=vm)
    return _screen_result(response, f"Screenshot captured{f' at {path}' if path else ''}.")


@server.tool(structured_output=False)
def tap(x: float, y: float, vm: str | None = None) -> list[Any]:
    """Tap guest screen pixel coordinates and return the resulting screen."""
    return _screen_result(_control({"t": "tap", "x": x, "y": y}, vm=vm), f"Tapped ({x}, {y}).")


@server.tool(structured_output=False)
def swipe(
    x1: float, y1: float, x2: float, y2: float, duration_ms: int = 300, vm: str | None = None
) -> list[Any]:
    """Swipe between guest screen pixel coordinates and return the resulting screen."""
    payload = {"t": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "ms": duration_ms}
    return _screen_result(_control(payload, vm=vm), "Swipe completed.")


@server.tool(structured_output=False)
def press_key(name: str, vm: str | None = None) -> list[Any]:
    """Press home, power, volup, or voldown and return the resulting screen."""
    return _screen_result(_control({"t": "key", "name": name}, vm=vm), f"Pressed {name}.")


@server.tool()
def app_list(filter: str = "all", vm: str | None = None) -> list[dict[str, Any]]:
    """List guest apps and running state."""
    return _rpc("app_list", vm=vm, filter=filter)


@server.tool()
def app_foreground(vm: str | None = None) -> dict[str, Any]:
    """Return the foreground guest app."""
    return _rpc("app_foreground", vm=vm)


@server.tool()
def app_launch(bundle_id: str, url: str | None = None, vm: str | None = None) -> dict[str, Any]:
    """Launch a guest app by bundle ID, optionally with a URL."""
    args: dict[str, Any] = {"bundle_id": bundle_id}
    if url:
        args["url"] = url
    return _rpc("app_launch", vm=vm, **args)


@server.tool()
def app_terminate(bundle_id: str, vm: str | None = None) -> dict[str, Any]:
    """Terminate a guest app by bundle ID."""
    return _rpc("app_terminate", vm=vm, bundle_id=bundle_id)


@server.tool()
def install_ipa(host_path: str, vm: str | None = None) -> dict[str, Any]:
    """Install a local .ipa or .tipa into the guest using vphoned."""
    return _rpc("install_ipa", vm=vm, host_path=str(Path(host_path).expanduser().resolve()))


@server.tool()
def file_list(path: str, vm: str | None = None) -> list[dict[str, Any]]:
    """List a guest directory."""
    return _rpc("file_list", vm=vm, path=path)


@server.tool()
def file_download(path: str, host_path: str, vm: str | None = None) -> dict[str, Any]:
    """Download one guest file to an explicit path on the Mac."""
    return _rpc("file_download", vm=vm, path=path, host_path=str(Path(host_path).expanduser().resolve()))


@server.tool()
def file_upload(
    host_path: str, path: str, permissions: str = "644", vm: str | None = None
) -> dict[str, Any]:
    """Upload one Mac file to the guest."""
    return _rpc(
        "file_upload", vm=vm, host_path=str(Path(host_path).expanduser().resolve()),
        path=path, permissions=permissions,
    )


@server.tool()
def file_mkdir(path: str, vm: str | None = None) -> dict[str, Any]:
    """Create a guest directory."""
    return _rpc("file_mkdir", vm=vm, path=path)


@server.tool()
def file_delete(path: str, vm: str | None = None) -> dict[str, Any]:
    """Delete a guest file or supported path."""
    return _rpc("file_delete", vm=vm, path=path)


@server.tool()
def file_rename(source: str, destination: str, vm: str | None = None) -> dict[str, Any]:
    """Rename or move a guest path."""
    return _rpc("file_rename", vm=vm, **{"from": source, "to": destination})


@server.tool()
def clipboard_get(image_path: str | None = None, vm: str | None = None) -> dict[str, Any]:
    """Read guest clipboard text/types; optionally save clipboard image bytes to the Mac."""
    args: dict[str, Any] = {}
    if image_path:
        args["image_path"] = str(Path(image_path).expanduser().resolve())
    return _rpc("clipboard_get", vm=vm, **args)


@server.tool()
def clipboard_set_text(text: str, vm: str | None = None) -> dict[str, Any]:
    """Set guest clipboard text."""
    return _rpc("clipboard_set_text", vm=vm, text=text)


@server.tool()
def clipboard_set_image(host_path: str, vm: str | None = None) -> dict[str, Any]:
    """Set the guest clipboard image from a Mac file."""
    return _rpc("clipboard_set_image", vm=vm, host_path=str(Path(host_path).expanduser().resolve()))


@server.tool()
def open_url(url: str, vm: str | None = None) -> dict[str, Any]:
    """Open a URL inside the guest."""
    return _rpc("open_url", vm=vm, url=url)


@server.tool()
def settings_get(domain: str, key: str | None = None, vm: str | None = None) -> dict[str, Any]:
    """Read a guest preferences domain or key."""
    args: dict[str, Any] = {"domain": domain}
    if key:
        args["key"] = key
    return _rpc("settings_get", vm=vm, **args)


@server.tool()
def settings_set(
    domain: str, key: str, value: Any, value_type: str | None = None, vm: str | None = None
) -> dict[str, Any]:
    """Write a guest preferences key."""
    args: dict[str, Any] = {"domain": domain, "key": key, "value": value}
    if value_type:
        args["value_type"] = value_type
    return _rpc("settings_set", vm=vm, **args)


@server.tool()
def low_power_mode(enabled: bool, vm: str | None = None) -> dict[str, Any]:
    """Enable or disable guest Low Power Mode."""
    return _rpc("low_power_mode", vm=vm, enabled=enabled)


@server.tool()
def location_set(
    latitude: float,
    longitude: float,
    altitude: float = 0,
    horizontal_accuracy: float = 5,
    vertical_accuracy: float = 5,
    speed: float = 0,
    course: float = 0,
    vm: str | None = None,
) -> dict[str, Any]:
    """Inject a simulated guest location."""
    return _rpc(
        "location_set", vm=vm, latitude=latitude, longitude=longitude, altitude=altitude,
        horizontal_accuracy=horizontal_accuracy, vertical_accuracy=vertical_accuracy,
        speed=speed, course=course,
    )


@server.tool()
def location_stop(vm: str | None = None) -> dict[str, Any]:
    """Stop guest location simulation."""
    return _rpc("location_stop", vm=vm)


def _ui_selector(
    identifier: str | None = None,
    label: str | None = None,
    role: str | None = None,
    value: str | None = None,
    contains: bool = False,
    index: int | None = None,
    visible: bool | None = True,
    clickable: bool | None = None,
) -> dict[str, Any]:
    selector: dict[str, Any] = {}
    if identifier is not None:
        selector["identifier"] = identifier
    if label is not None:
        selector["label"] = label
    if role is not None:
        selector["role"] = role
    if value is not None:
        selector["value"] = value
    if contains:
        selector["contains"] = True
    if index is not None:
        if index < 0:
            raise ValueError("index must be >= 0")
        selector["index"] = index
    if visible is not None:
        selector["visible"] = visible
    if clickable is not None:
        selector["clickable"] = clickable
    if not any(k in selector for k in ("identifier", "label", "role", "value")):
        raise ValueError("semantic selector requires identifier, label, role, or value")
    return selector


@server.tool()
def ui_status(vm: str | None = None) -> dict[str, Any]:
    """Return SpringBoard semantic-accessibility runtime, broker, and frontmost-app status."""
    return _rpc("accessibility_status", vm=vm)


@server.tool()
def ui_bootstrap(vm: str | None = None) -> dict[str, Any]:
    """Re-prime the guest AXRuntime/AccessibilityUI semantic broker."""
    return _rpc("accessibility_bootstrap", vm=vm)


@server.tool()
def ui_tree(
    mode: str = "compact",
    max_depth: int = 20,
    max_elements: int = 500,
    visible_only: bool = True,
    clickable_only: bool = False,
    vm: str | None = None,
) -> dict[str, Any]:
    """Return the current semantic UI. Use compact by default; tree/full is diagnostic and bounded."""
    if mode not in {"compact", "tree", "full", "raw"}:
        raise ValueError("mode must be compact, tree, full, or raw")
    if not 1 <= max_elements <= 2000:
        raise ValueError("max_elements must be between 1 and 2000")
    if not 0 <= max_depth <= 60:
        raise ValueError("max_depth must be between 0 and 60")
    return _rpc(
        "accessibility_tree", vm=vm, mode=mode, max_depth=max_depth,
        max_elements=max_elements, visible_only=visible_only, clickable_only=clickable_only,
    )


@server.tool()
def accessibility_tree(depth: int = 20, vm: str | None = None) -> dict[str, Any]:
    """Backward-compatible full semantic accessibility-tree request."""
    return ui_tree(mode="tree", max_depth=depth, max_elements=500, vm=vm)


@server.tool()
def ui_find(
    identifier: str | None = None,
    label: str | None = None,
    role: str | None = None,
    value: str | None = None,
    contains: bool = False,
    index: int | None = None,
    visible: bool | None = True,
    clickable: bool | None = None,
    deep: bool = True,
    max_depth: int = 20,
    max_elements: int = 1000,
    vm: str | None = None,
) -> dict[str, Any]:
    """Find one semantic UI element. Equal matches return ambiguity instead of choosing silently."""
    selector = _ui_selector(identifier, label, role, value, contains, index, visible, clickable)
    return _rpc(
        "accessibility_find", vm=vm, selector=selector, deep=deep,
        max_depth=max_depth, max_elements=max_elements,
    )


@server.tool()
def ui_tap(
    identifier: str | None = None,
    label: str | None = None,
    role: str | None = None,
    value: str | None = None,
    contains: bool = False,
    index: int | None = None,
    visible: bool | None = True,
    max_depth: int = 20,
    vm: str | None = None,
) -> dict[str, Any]:
    """Re-resolve a semantic target and tap its current geometry atomically."""
    selector = _ui_selector(identifier, label, role, value, contains, index, visible, True)
    return _rpc(
        "accessibility_action", vm=vm, selector=selector, action="tap", max_depth=max_depth,
    )


@server.tool()
def ui_type(
    text: str,
    identifier: str | None = None,
    label: str | None = None,
    role: str | None = None,
    value: str | None = None,
    contains: bool = False,
    index: int | None = None,
    visible: bool | None = True,
    method: str = "paste",
    verify: bool = True,
    max_depth: int = 20,
    vm: str | None = None,
) -> dict[str, Any]:
    """Tap a semantic text target and enter text. Paste supports arbitrary Unicode; keys is ASCII-only."""
    if method not in {"paste", "keys"}:
        raise ValueError("method must be paste or keys")
    selector = _ui_selector(identifier, label, role, value, contains, index, visible, True)
    action = _rpc(
        "accessibility_action", vm=vm, selector=selector, action="tap", max_depth=max_depth,
    )
    if not action.get("ok"):
        return {"ok": False, "stage": "resolve_and_tap", "action": action}
    typed = _rpc("type_text", vm=vm, text=text, method=method)
    result: dict[str, Any] = {"ok": True, "action": action, "typed": typed}
    if verify:
        time.sleep(0.25)
        result["resolved_after"] = _rpc(
            "accessibility_find", vm=vm, selector=selector, deep=True,
            max_depth=max_depth, max_elements=1000,
        )
    return result


@server.tool()
def ui_wait(
    condition: str = "present",
    timeout: float = 10.0,
    interval: float = 0.25,
    identifier: str | None = None,
    label: str | None = None,
    role: str | None = None,
    value: str | None = None,
    contains: bool = False,
    index: int | None = None,
    visible: bool | None = True,
    clickable: bool | None = None,
    max_depth: int = 20,
    vm: str | None = None,
) -> dict[str, Any]:
    """Wait for a semantic element to become present or absent without screenshot polling."""
    if condition not in {"present", "absent"}:
        raise ValueError("condition must be present or absent")
    if timeout < 0 or timeout > 60:
        raise ValueError("timeout must be between 0 and 60 seconds")
    if interval < 0.1 or interval > 5:
        raise ValueError("interval must be between 0.1 and 5 seconds")
    selector = _ui_selector(identifier, label, role, value, contains, index, visible, clickable)
    deadline = time.monotonic() + timeout
    last: dict[str, Any] | None = None
    while True:
        last = _rpc(
            "accessibility_find", vm=vm, selector=selector, deep=True,
            max_depth=max_depth, max_elements=1000,
        )
        if condition == "present":
            if last.get("ok"):
                return {"ok": True, "condition": condition, "result": last}
            if last.get("error") == "ambiguous":
                return {"ok": False, "condition": condition, "error": "ambiguous", "result": last}
        elif last.get("error") == "not_found":
            return {"ok": True, "condition": condition, "result": last}
        if time.monotonic() >= deadline:
            return {"ok": False, "condition": condition, "error": "timeout", "last": last}
        time.sleep(interval)


@server.tool()
def ui_at_point(x: float, y: float, vm: str | None = None) -> dict[str, Any]:
    """Return the semantic accessibility element currently under one screen point."""
    return _rpc("accessibility_hit_test", vm=vm, x=x, y=y)


@server.tool()
def camera_status(vm: str | None = None) -> dict[str, Any]:
    """Return virtual-camera connection, source, streaming state, resolution, and FPS."""
    return _rpc("camera_status", vm=vm)


@server.tool()
def camera_source(
    source: str, host_path: str | None = None, vm: str | None = None
) -> dict[str, Any]:
    """Select virtual-camera source: off, test_pattern, or video_file."""
    args: dict[str, Any] = {"source": source}
    if host_path:
        args["host_path"] = str(Path(host_path).expanduser().resolve())
    return _rpc("camera_source", vm=vm, **args)


@server.tool()
def camera_start(vm: str | None = None) -> dict[str, Any]:
    """Start streaming the selected virtual-camera source into the guest."""
    return _rpc("camera_start", vm=vm)


@server.tool()
def camera_stop(vm: str | None = None) -> dict[str, Any]:
    """Stop virtual-camera streaming."""
    return _rpc("camera_stop", vm=vm)


@server.tool()
def recording_status(vm: str | None = None) -> dict[str, Any]:
    """Return host-side virtual-iPhone screen-recording state."""
    return _rpc("recording_status", vm=vm)


@server.tool()
def recording_start(vm: str | None = None) -> dict[str, Any]:
    """Start recording the virtual iPhone screen to the Mac."""
    return _rpc("recording_start", vm=vm)


@server.tool()
def recording_stop(vm: str | None = None) -> dict[str, Any]:
    """Stop screen recording and return the saved .mov path."""
    return _rpc("recording_stop", vm=vm)


@server.tool()
def touchid_status(vm: str | None = None) -> dict[str, Any]:
    """Return whether physical Mac Touch ID forwarding is enabled for vphone navigation."""
    return _rpc("touchid_status", vm=vm)


@server.tool()
def touchid_set(enabled: bool, vm: str | None = None) -> dict[str, Any]:
    """Enable or disable physical Mac Touch ID forwarding used by the vphone host UI."""
    return _rpc("touchid_set", vm=vm, enabled=enabled)


@server.tool()
def battery_set(charge: float, charging: bool = False, vm: str | None = None) -> dict[str, Any]:
    """Set simulated guest battery percentage and charging connectivity."""
    return _rpc("battery_set", vm=vm, charge=charge, connectivity=1 if charging else 2)


@server.tool()
def keychain_list(
    item_class: str | None = None, include_values: bool = False, vm: str | None = None
) -> dict[str, Any]:
    """Read guest keychain metadata. Secret values are redacted unless include_values is explicitly true."""
    args: dict[str, Any] = {}
    if item_class:
        args["class"] = item_class
    result = _rpc("keychain_list", vm=vm, **args)
    if include_values:
        return result
    redacted: list[dict[str, Any]] = []
    for item in result.get("items", []):
        clean = dict(item)
        if "value" in clean:
            clean["value"] = "<redacted>"
        redacted.append(clean)
    return {"items": redacted, "diagnostics": result.get("diagnostics", [])}


@server.tool()
def keychain_add(
    account: str, service: str, password: str, vm: str | None = None
) -> dict[str, Any]:
    """Add a guest keychain item. This is sensitive and should require explicit approval."""
    return _rpc(
        "keychain_add", vm=vm, account=account, service=service, password=password
    )


@server.tool()
def guest_request(
    request: dict[str, Any], host_output_path: str | None = None, vm: str | None = None
) -> dict[str, Any]:
    """Send a raw vphoned request for advanced/future capabilities; use only when no typed tool fits."""
    args: dict[str, Any] = {"request": request}
    if host_output_path:
        args["host_output_path"] = str(Path(host_output_path).expanduser().resolve())
    return _rpc("raw_request", vm=vm, **args)


def main() -> None:
    server.run("stdio")


if __name__ == "__main__":
    main()
