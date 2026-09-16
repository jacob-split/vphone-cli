import AppKit
import Darwin
import Foundation
import ImageIO

// MARK: - Host Control Socket

/// Lightweight Unix domain socket server that accepts automation commands from
/// local processes (e.g. Claude Code via `nc -U`).  One JSON line in, one JSON
/// line out, then the connection closes.
///
/// Every response includes an `"image"` field with a compact base64-encoded
/// grayscale JPEG of the current screen (unless `"screen":false` is sent).
///
/// Supported commands:
///   {"t":"screenshot"}                          → full-res save to Desktop (or explicit path)
///   {"t":"screenshot","path":"/tmp/shot.png"}   → save to explicit path (PNG/JPEG by extension)
///   {"t":"tap","x":645,"y":1398}                → tap at pixel coordinates
///   {"t":"swipe","x1":645,"y1":2600,"x2":645,"y2":1400,"ms":300}  → swipe
///   {"t":"key","name":"home"}                   → hardware key (home/power/volup/voldown)
///   {"t":"type","text":"Hello"}                 → set guest clipboard
///
/// All commands except "screenshot" wait briefly then capture a compact screen
/// image returned as `"image":"<base64>"` in the response.  Pass `"screen":false`
/// to skip the capture.
@MainActor
class VPhoneHostControl {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "vphone.hostcontrol.accept")

    private weak var captureView: VPhoneVirtualMachineView?
    private var screenRecorder: VPhoneScreenRecorder?
    private weak var control: VPhoneControl?
    private weak var cameraServer: VPhoneCameraServer?
    private weak var touchIDMonitor: VPhoneTouchIDMonitor?
    private weak var virtualMachine: VPhoneVirtualMachine?
    private weak var keyHelper: VPhoneKeyHelper?

    /// Thread-safe box for passing results between main actor and accept queue.
    private final class ResultBox: @unchecked Sendable {
        var path: String?
        var error: String?
        var ok = false
        var imageBase64: String?
        var data: Any?
    }

    /// Screen pixel dimensions for coordinate mapping.
    private var screenWidth: Int = 1290
    private var screenHeight: Int = 2796

    /// Compact screenshot scale factor (1/3 = 430x932).
    private static let compactScale = 3

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start(
        captureView: VPhoneVirtualMachineView,
        screenRecorder: VPhoneScreenRecorder,
        control: VPhoneControl,
        cameraServer: VPhoneCameraServer?,
        touchIDMonitor: VPhoneTouchIDMonitor?,
        virtualMachine: VPhoneVirtualMachine,
        keyHelper: VPhoneKeyHelper,
        screenWidth: Int,
        screenHeight: Int
    ) {
        self.captureView = captureView
        self.screenRecorder = screenRecorder
        self.control = control
        self.cameraServer = cameraServer
        self.touchIDMonitor = touchIDMonitor
        self.virtualMachine = virtualMachine
        self.keyHelper = keyHelper
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[hostctl] failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            print("[hostctl] socket path too long")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, byte) in pathBytes.enumerated() {
                    dst[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            print("[hostctl] bind failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard listen(fd, 4) == 0 else {
            print("[hostctl] listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        socketPath.withCString { path in
            _ = Darwin.chmod(path, mode_t(S_IRUSR | S_IWUSR))
        }

        listenFD = fd
        print("[hostctl] listening on \(socketPath)")

        let capturedFD = fd
        acceptQueue.async { [weak self] in
            Self.acceptLoop(listenFD: capturedFD, controller: self)
        }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Compact Screenshot

    /// Capture current screen as a small grayscale JPEG, returned as base64.
    private func captureCompactScreenshot() async -> String? {
        guard let recorder = screenRecorder, let view = captureView, view.window != nil else {
            return nil
        }

        // Reuse the existing private-API capture
        guard let cgImage = await captureStillImage(recorder: recorder, view: view) else {
            return nil
        }

        let dstW = cgImage.width / Self.compactScale
        let dstH = cgImage.height / Self.compactScale

        // Draw into grayscale context
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: dstW, height: dstH,
            bitsPerComponent: 8, bytesPerRow: dstW,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // High contrast: bump brightness
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

        guard let grayImage = ctx.makeImage() else { return nil }

        // Encode as low-quality JPEG
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.35]
        CGImageDestinationAddImage(dest, grayImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (data as Data).base64EncodedString()
    }

    /// Access the recorder's private capture method via the existing async wrapper.
    private func captureStillImage(recorder: VPhoneScreenRecorder, view: NSView) async -> CGImage? {
        // Use the public saveScreenshot path but intercept before encoding.
        // We call the recorder's internal captureStillImage indirectly by
        // going through saveScreenshot to a temp file, then reading back.
        // This is suboptimal but avoids exposing internal API.
        //
        // Better: use the same private API directly.
        guard let vmView = view as? VPhoneVirtualMachineView,
              let display = vmView.recordingGraphicsDisplay
        else { return nil }

        return await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("_takeScreenshotWithCompletionHandler:")
            guard display.responds(to: selector),
                  let cls = object_getClass(display),
                  let method = class_getInstanceMethod(cls, selector)
            else {
                continuation.resume(returning: nil)
                return
            }

            typealias CompletionBlock = @convention(block) (AnyObject?) -> Void
            typealias IMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

            let impl = method_getImplementation(method)
            let fn = unsafeBitCast(impl, to: IMP.self)

            let block: CompletionBlock = { imageObject in
                guard let imageObject else {
                    continuation.resume(returning: nil)
                    return
                }
                if let nsImage = imageObject as? NSImage {
                    continuation.resume(returning: nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    return
                }
                let cf = imageObject as CFTypeRef
                if CFGetTypeID(cf) == CGImage.typeID {
                    continuation.resume(returning: (cf as! CGImage))
                    return
                }
                continuation.resume(returning: nil)
            }
            let blockObj = unsafeBitCast(block, to: AnyObject.self)
            fn(display, selector, blockObj)
        }
    }

    // MARK: - Accept Loop

    private nonisolated static func acceptLoop(listenFD: Int32, controller: VPhoneHostControl?) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break }
            handleClient(clientFD, controller: controller)
        }
    }

    private nonisolated static func handleClient(_ fd: Int32, controller: VPhoneHostControl?) {
        defer { close(fd) }

        guard let line = readLine(from: fd) else { return }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["t"] as? String
        else {
            writeResponse(fd, ok: false, error: "invalid JSON")
            return
        }

        // Whether to include a compact screenshot in the response (default: true)
        let wantScreen = json["screen"] as? Bool ?? true
        // Delay before screenshot (ms) — lets animations settle
        let screenDelay = json["delay"] as? Int ?? 500

        switch type {
        case "screenshot":
            let outputPath = json["path"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller,
                      let recorder = controller.screenRecorder,
                      let view = controller.captureView,
                      view.window != nil
                else {
                    result.error = "no active VM view"
                    return
                }
                do {
                    if let outputPath {
                        let url = try await recorder.saveScreenshot(view: view, to: URL(fileURLWithPath: outputPath))
                        result.path = url.path
                    }
                    // Always include compact image for screenshot command
                    result.imageBase64 = await controller.captureCompactScreenshot()
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, path: result.path, image: result.imageBase64)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "tap":
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
                writeResponse(fd, ok: false, error: "tap requires x and y (pixel coordinates)")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let view = controller.captureView, view.window != nil else {
                    result.error = "no active VM view"
                    return
                }
                view.injectTap(
                    pixelX: x, pixelY: y,
                    screenWidth: controller.screenWidth, screenHeight: controller.screenHeight
                )
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "swipe":
            guard let x1 = json["x1"] as? Double, let y1 = json["y1"] as? Double,
                  let x2 = json["x2"] as? Double, let y2 = json["y2"] as? Double
            else {
                writeResponse(fd, ok: false, error: "swipe requires x1, y1, x2, y2")
                return
            }
            let durationMs = json["ms"] as? Int ?? 300
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let view = controller.captureView, view.window != nil else {
                    result.error = "no active VM view"
                    return
                }
                view.injectSwipe(
                    fromX: x1, fromY: y1, toX: x2, toY: y2,
                    screenWidth: controller.screenWidth, screenHeight: controller.screenHeight,
                    durationMs: durationMs
                )
                result.ok = true
                if wantScreen {
                    // Wait for swipe to finish + settle
                    let totalDelay = durationMs + screenDelay
                    try? await Task.sleep(nanoseconds: UInt64(totalDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "key":
            guard let name = json["name"] as? String else {
                writeResponse(fd, ok: false, error: "key requires name (home/power/volup/voldown)")
                return
            }
            let hidKey: (page: UInt32, usage: UInt32)? = switch name {
            case "home": (0x0C, 0x40)
            case "power": (0x0C, 0x30)
            case "volup": (0x0C, 0xE9)
            case "voldown": (0x0C, 0xEA)
            default: nil
            }
            guard let key = hidKey else {
                writeResponse(fd, ok: false, error: "unknown key: \(name)")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                ctl.sendHIDPress(page: key.page, usage: key.usage)
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "type":
            guard let text = json["text"] as? String else {
                writeResponse(fd, ok: false, error: "type requires text")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.clipboardSet(text: text)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "rpc":
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller else {
                    result.error = "host control unavailable"
                    return
                }
                do {
                    result.data = try await controller.handleRPC(json)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }
            semaphore.wait()
            writeResponse(
                fd, ok: result.ok, error: result.error, image: result.imageBase64, data: result.data
            )

        default:
            writeResponse(fd, ok: false, error: "unknown command: \(type)")
        }
    }

    // MARK: - Guest RPC

    private func handleRPC(_ json: [String: Any]) async throws -> Any {
        guard let ctl = control else {
            throw VPhoneControl.ControlError.notConnected
        }
        guard let op = json["op"] as? String, !op.isEmpty else {
            throw VPhoneControl.ControlError.protocolError("rpc requires op")
        }

        func string(_ key: String) throws -> String {
            guard let value = json[key] as? String, !value.isEmpty else {
                throw VPhoneControl.ControlError.protocolError("\(op) requires \(key)")
            }
            return value
        }
        func number(_ key: String, default fallback: Double? = nil) throws -> Double {
            if let n = json[key] as? NSNumber { return n.doubleValue }
            if let fallback { return fallback }
            throw VPhoneControl.ControlError.protocolError("\(op) requires numeric \(key)")
        }
        func requireConnected() throws {
            guard ctl.isConnected else { throw VPhoneControl.ControlError.notConnected }
        }
        func writeHostData(_ data: Data, to path: String) throws {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }

        switch op {
        case "status":
            return [
                "connected": ctl.isConnected,
                "guest_name": ctl.guestName,
                "guest_ip": ctl.guestIP ?? NSNull(),
                "ios_version": ctl.guestIOSVersion ?? NSNull(),
                "capabilities": ctl.guestCaps,
                "variant": String(describing: ctl.variant),
                "socket": socketPath,
            ] as [String: Any]

        case "ping":
            try await ctl.sendPing()
            return ["pong": true]

        case "version":
            return ["hash": try await ctl.sendVersion()]

        case "devmode_status":
            return ["enabled": try await ctl.sendDevModeStatus().enabled]

        case "file_list":
            return try await ctl.listFiles(path: string("path"))

        case "file_download":
            let guestPath = try string("path")
            let hostPath = try string("host_path")
            let data = try await ctl.downloadFile(path: guestPath)
            try writeHostData(data, to: hostPath)
            return ["host_path": hostPath, "bytes": data.count]

        case "file_upload":
            let hostPath = try string("host_path")
            let guestPath = try string("path")
            let data = try Data(contentsOf: URL(fileURLWithPath: hostPath))
            try await ctl.uploadFile(
                path: guestPath, data: data, permissions: json["permissions"] as? String ?? "644"
            )
            return ["path": guestPath, "bytes": data.count]

        case "file_mkdir":
            try await ctl.createDirectory(path: string("path"))
            return ["created": true]

        case "file_delete":
            try await ctl.deleteFile(path: string("path"))
            return ["deleted": true]

        case "file_rename":
            try await ctl.renameFile(from: string("from"), to: string("to"))
            return ["renamed": true]

        case "install_ipa":
            let hostPath = try string("host_path")
            let message = try await ctl.installIPA(localURL: URL(fileURLWithPath: hostPath))
            return ["message": message]

        case "keychain_list":
            let result = try await ctl.listKeychainItems(filterClass: json["class"] as? String)
            return ["items": result.items, "diagnostics": result.diagnostics]

        case "keychain_add":
            let ok = try await ctl.addKeychainItem(
                account: json["account"] as? String ?? "vphone-test",
                service: json["service"] as? String ?? "vphone",
                password: json["password"] as? String ?? "testpass123"
            )
            return ["added": ok]

        case "clipboard_get":
            let content = try await ctl.clipboardGet()
            var result: [String: Any] = [
                "text": content.text ?? NSNull(),
                "types": content.types,
                "has_image": content.hasImage,
                "change_count": content.changeCount,
                "image_bytes": content.imageData?.count ?? 0,
            ]
            if let imageData = content.imageData, let hostPath = json["image_path"] as? String {
                try writeHostData(imageData, to: hostPath)
                result["image_path"] = hostPath
            }
            return result

        case "clipboard_set_text":
            try await ctl.clipboardSet(text: string("text"))
            return ["set": true]

        case "type_text":
            let text = try string("text")
            let method = json["method"] as? String ?? "paste"
            switch method {
            case "paste":
                try await ctl.clipboardSet(text: text)
                // Cmd-V through guest HID handles arbitrary Unicode from UIPasteboard.
                ctl.sendHIDDown(page: 0x07, usage: 0xE3)
                ctl.sendHIDPress(page: 0x07, usage: 0x19)
                ctl.sendHIDUp(page: 0x07, usage: 0xE3)
                try? await Task.sleep(for: .milliseconds(250))
            case "keys":
                guard let keyHelper else {
                    throw VPhoneControl.ControlError.protocolError("keyboard helper unavailable")
                }
                keyHelper.typeString(text)
                let settle = min(5.0, max(0.15, Double(text.count) * 0.025 + 0.1))
                try? await Task.sleep(for: .seconds(settle))
            default:
                throw VPhoneControl.ControlError.protocolError("type_text method must be paste or keys")
            }
            return ["typed": true, "characters": text.count, "method": method]

        case "clipboard_set_image":
            let hostPath = try string("host_path")
            try await ctl.clipboardSet(imageData: Data(contentsOf: URL(fileURLWithPath: hostPath)))
            return ["set": true]

        case "app_list":
            return try await ctl.appList(filter: json["filter"] as? String ?? "all").map { app in
                [
                    "bundle_id": app.bundleId, "name": app.name, "version": app.version,
                    "type": app.type, "state": app.state, "pid": app.pid, "path": app.path,
                    "data_container": app.dataContainer,
                ] as [String: Any]
            }

        case "app_launch":
            let pid = try await ctl.appLaunch(
                bundleId: string("bundle_id"), url: json["url"] as? String
            )
            return ["pid": pid]

        case "app_terminate":
            try await ctl.appTerminate(bundleId: string("bundle_id"))
            return ["terminated": true]

        case "app_foreground":
            let app = try await ctl.appForeground()
            return ["bundle_id": app.bundleId, "name": app.name, "pid": app.pid]

        case "open_url":
            try await ctl.openURL(string("url"))
            return ["opened": true]

        case "settings_get":
            let value = try await ctl.settingsGet(
                domain: string("domain"), key: json["key"] as? String
            )
            return ["value": value ?? NSNull()]

        case "settings_set":
            guard let value = json["value"] else {
                throw VPhoneControl.ControlError.protocolError("settings_set requires value")
            }
            try await ctl.settingsSet(
                domain: string("domain"), key: string("key"), value: value,
                type: json["value_type"] as? String
            )
            return ["set": true]

        case "low_power_mode":
            guard let enabled = json["enabled"] as? Bool else {
                throw VPhoneControl.ControlError.protocolError("low_power_mode requires enabled")
            }
            try await ctl.lowPowerMode(enabled: enabled)
            return ["enabled": enabled]

        case "accessibility_status":
            return try await ctl.accessibilityStatus()

        case "accessibility_bootstrap":
            return try await ctl.accessibilityBootstrap()

        case "accessibility_tree":
            return try await ctl.accessibilityTree(
                mode: json["mode"] as? String ?? "compact",
                maxDepth: (json["max_depth"] as? NSNumber)?.intValue ?? 20,
                maxElements: (json["max_elements"] as? NSNumber)?.intValue ?? 500,
                visibleOnly: json["visible_only"] as? Bool ?? true,
                clickableOnly: json["clickable_only"] as? Bool ?? false
            )

        case "accessibility_find":
            guard let selector = json["selector"] as? [String: Any] else {
                throw VPhoneControl.ControlError.protocolError("accessibility_find requires selector")
            }
            return try await ctl.accessibilityFind(
                selector: selector, deep: json["deep"] as? Bool ?? true,
                maxDepth: (json["max_depth"] as? NSNumber)?.intValue ?? 20,
                maxElements: (json["max_elements"] as? NSNumber)?.intValue ?? 1000
            )

        case "accessibility_hit_test":
            return try await ctl.accessibilityHitTest(
                x: try number("x"), y: try number("y")
            )

        case "accessibility_action":
            guard let selector = json["selector"] as? [String: Any] else {
                throw VPhoneControl.ControlError.protocolError("accessibility_action requires selector")
            }
            return try await ctl.accessibilityAction(
                selector: selector, action: json["action"] as? String ?? "tap",
                maxDepth: (json["max_depth"] as? NSNumber)?.intValue ?? 20
            )

        case "location_set":
            try requireConnected()
            let lat = try number("latitude")
            let lon = try number("longitude")
            ctl.sendLocation(
                latitude: lat, longitude: lon, altitude: try number("altitude", default: 0),
                horizontalAccuracy: try number("horizontal_accuracy", default: 5),
                verticalAccuracy: try number("vertical_accuracy", default: 5),
                speed: try number("speed", default: 0), course: try number("course", default: 0)
            )
            return ["latitude": lat, "longitude": lon]

        case "location_stop":
            try requireConnected()
            ctl.sendLocationStop()
            return ["stopped": true]

        case "camera_status":
            guard let cameraServer else {
                throw VPhoneControl.ControlError.protocolError("camera server unavailable")
            }
            return [
                "connected": cameraServer.isConnected,
                "source": cameraServer.sourceKind.rawValue,
                "streaming": cameraServer.isStreaming,
                "width": VPhoneCameraServer.defaultWidth,
                "height": VPhoneCameraServer.defaultHeight,
                "fps": VPhoneCameraServer.defaultFPS,
            ] as [String: Any]

        case "camera_source":
            guard let cameraServer else {
                throw VPhoneControl.ControlError.protocolError("camera server unavailable")
            }
            let source = try string("source")
            switch source {
            case "off":
                cameraServer.setSource(.off)
            case "testPattern", "test_pattern":
                cameraServer.setSource(.testPattern)
            case "videoFile", "video_file":
                let hostPath = try string("host_path")
                cameraServer.setSource(.videoFile, videoURL: URL(fileURLWithPath: hostPath))
            default:
                throw VPhoneControl.ControlError.protocolError(
                    "camera_source source must be off, test_pattern, or video_file"
                )
            }
            return ["source": cameraServer.sourceKind.rawValue]

        case "camera_start":
            guard let cameraServer else {
                throw VPhoneControl.ControlError.protocolError("camera server unavailable")
            }
            cameraServer.startStreaming()
            return ["streaming": cameraServer.isStreaming]

        case "camera_stop":
            guard let cameraServer else {
                throw VPhoneControl.ControlError.protocolError("camera server unavailable")
            }
            cameraServer.stopStreaming()
            return ["streaming": cameraServer.isStreaming]

        case "recording_status":
            return ["recording": screenRecorder?.isRecording ?? false]

        case "recording_start":
            guard let recorder = screenRecorder, let captureView else {
                throw VPhoneControl.ControlError.protocolError("screen recorder unavailable")
            }
            if !recorder.isRecording { try recorder.startRecording(view: captureView) }
            return ["recording": recorder.isRecording]

        case "recording_stop":
            guard let recorder = screenRecorder else {
                throw VPhoneControl.ControlError.protocolError("screen recorder unavailable")
            }
            let url = await recorder.stopRecording()
            var result: [String: Any] = ["recording": false]
            result["path"] = url?.path ?? NSNull() as Any
            return result

        case "touchid_status":
            guard let monitor = touchIDMonitor else {
                throw VPhoneControl.ControlError.protocolError("Touch ID monitor unavailable")
            }
            return ["enabled": monitor.isEnabled]

        case "touchid_set":
            guard let monitor = touchIDMonitor, let enabled = json["enabled"] as? Bool else {
                throw VPhoneControl.ControlError.protocolError("touchid_set requires enabled")
            }
            monitor.isEnabled = enabled
            return ["enabled": monitor.isEnabled]

        case "battery_set":
            guard let vm = virtualMachine else {
                throw VPhoneControl.ControlError.protocolError("virtual machine unavailable")
            }
            let charge = try number("charge")
            guard (0 ... 100).contains(charge) else {
                throw VPhoneControl.ControlError.protocolError("battery charge must be 0...100")
            }
            let connectivity = (json["connectivity"] as? NSNumber)?.intValue ?? 2
            guard connectivity == 1 || connectivity == 2 else {
                throw VPhoneControl.ControlError.protocolError(
                    "battery connectivity must be 1 (charging) or 2 (disconnected)"
                )
            }
            vm.setBattery(charge: charge, connectivity: connectivity)
            return ["charge": charge, "connectivity": connectivity]

        case "raw_request":
            guard var request = json["request"] as? [String: Any], request["t"] != nil else {
                throw VPhoneControl.ControlError.protocolError("raw_request requires request with t")
            }
            request.removeValue(forKey: "id")
            request.removeValue(forKey: "v")
            let (response, rawData) = try await ctl.sendRequest(request)
            var result: [String: Any] = ["response": response]
            if let rawData {
                result["raw_bytes"] = rawData.count
                if let hostPath = json["host_output_path"] as? String {
                    try writeHostData(rawData, to: hostPath)
                    result["host_output_path"] = hostPath
                }
            }
            return result

        default:
            throw VPhoneControl.ControlError.protocolError("unknown rpc op: \(op)")
        }
    }

    // MARK: - Socket I/O

    private nonisolated static func readLine(from fd: Int32) -> String? {
        let maxRequestBytes = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()

        while accumulated.count < maxRequestBytes {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            accumulated.append(contentsOf: buffer[..<n])
            if accumulated.contains(0x0A) { break }
        }

        if let nlRange = accumulated.firstIndex(of: 0x0A) {
            return String(data: accumulated[..<nlRange], encoding: .utf8)
        }
        return accumulated.isEmpty ? nil : String(data: accumulated, encoding: .utf8)
    }

    private nonisolated static func writeResponse(
        _ fd: Int32, ok: Bool, path: String? = nil, error: String? = nil, image: String? = nil,
        data: Any? = nil
    ) {
        var dict: [String: Any] = ["ok": ok]
        if let path { dict["path"] = path }
        if let error { dict["error"] = error }
        if let image { dict["image"] = image }
        if let data { dict["data"] = data }

        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              var json = String(data: data, encoding: .utf8)
        else { return }

        json += "\n"
        json.withCString { ptr in
            var remaining = strlen(ptr)
            var offset = 0
            while remaining > 0 {
                let written = write(fd, ptr.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }
}
