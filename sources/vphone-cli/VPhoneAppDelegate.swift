import AppKit
import Foundation
import Virtualization

class VPhoneAppDelegate: NSObject, NSApplicationDelegate {
    private let cli: VPhoneBootCLI
    private var vm: VPhoneVirtualMachine?
    private var control: VPhoneControl?
    private var windowController: VPhoneWindowController?
    private var menuController: VPhoneMenuController?
    private var fileWindowController: VPhoneFileWindowController?
    private var keychainWindowController: VPhoneKeychainWindowController?
    private var appWindowController: VPhoneAppWindowController?
    private var locationProvider: VPhoneLocationProvider?
    private var hostControl: VPhoneHostControl?
    private var cameraServer: VPhoneCameraServer?
    // Retained only in headless mode. VPhoneHostControl keeps weak references
    // so the hidden VZ view and key helper must live for the VM lifetime.
    private var headlessControlView: VPhoneVirtualMachineView?
    private var headlessControlWindow: NSWindow?
    private var headlessKeyHelper: VPhoneKeyHelper?
    private var sigintSource: DispatchSourceSignal?
    private var didAttemptAutoInstall = false

    init(cli: VPhoneBootCLI) {
        self.cli = cli
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(cli.noGraphics ? .prohibited : .regular)

        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            print("\n[vphone] SIGINT — shutting down")
            NSApp.terminate(nil)
        }
        src.activate()
        sigintSource = src

        Task { @MainActor in
            do {
                try await self.startVirtualMachine()
            } catch {
                print("[vphone] Fatal: \(error)")
                exit(EXIT_FAILURE)
            }
        }
    }

    @MainActor
    private func startVirtualMachine() async throws {
        let options = try cli.resolveOptions()

        guard options.romURL == nil || FileManager.default.fileExists(atPath: options.romURL!.path) else {
            throw VPhoneError.romNotFound(options.romURL!.path)
        }

        print("=== vphone-cli ===")
        print("Variant : \(options.variant)")
        print("ROM     : \(options.romURL?.path ?? "None")")
        print("Disk    : \(options.diskURL.path)")
        print("NVRAM   : \(options.nvramURL.path)")
        print("Config  : \(options.configURL.path)")
        print("CPU     : \(options.cpuCount)")
        print("Memory  : \(options.memorySize / 1024 / 1024) MB")
        print(
            "Screen: \(options.screenWidth)x\(options.screenHeight) @ \(options.screenPPI) PPI (scale \(options.screenScale)x)"
        )
        if let kernelDebugPort = options.kernelDebugPort {
            print("Kernel debug stub : 127.0.0.1:\(kernelDebugPort)")
        } else {
            print("Kernel debug stub : auto-assigned")
        }
        print("SEP               : enabled")
        print("  storage         : \(options.sepStorageURL.path)")
        print("  rom             : \(options.sepRomURL?.path ?? "None")")
        print("")

        let vm = try VPhoneVirtualMachine(options: options)
        self.vm = vm

        try await vm.start(forceDFU: cli.dfu)

        let control = VPhoneControl(variant: options.variant)
        self.control = control
        if !cli.dfu {
            let vphonedURL = URL(fileURLWithPath: cli.vphonedBin)
            if FileManager.default.fileExists(atPath: vphonedURL.path) {
                control.guestBinaryURL = vphonedURL
            }

            let provider = VPhoneLocationProvider(control: control)
            locationProvider = provider

            let camServer = VPhoneCameraServer()
            cameraServer = camServer

            if let device = vm.virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                control.connect(device: device)
                // A cold-boot headless worker must not block its MainActor on
                // the optional camera port before the guest camera service is
                // ready. Retain the device and connect lazily when a camera
                // source is explicitly selected.
                camServer.connect(device: device, deferred: cli.noGraphics)
            }
        }

        if !cli.noGraphics {
            let keyHelper = VPhoneKeyHelper(vm: vm, control: control)
            let wc = VPhoneWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
                screenScale: options.screenScale,
                keyHelper: keyHelper,
                control: control,
                ecid: vm.ecidHex
            )
            windowController = wc

            let fileWC = VPhoneFileWindowController()
            fileWindowController = fileWC

            let keychainWC = VPhoneKeychainWindowController()
            keychainWindowController = keychainWC

            let appWC = VPhoneAppWindowController()
            appWindowController = appWC

            let mc = VPhoneMenuController(keyHelper: keyHelper, control: control)
            mc.vm = vm
            mc.captureView = wc.captureView
            mc.touchIDMonitor = wc.touchIDMonitor
            mc.onFilesPressed = { [weak fileWC, weak control] in
                guard let fileWC, let control else { return }
                fileWC.showWindow(control: control)
            }
            mc.onKeychainPressed = { [weak keychainWC, weak control] in
                guard let keychainWC, let control else { return }
                keychainWC.showWindow(control: control)
            }
            mc.onAppsPressed = { [weak appWC, weak control] in
                guard let appWC, let control else { return }
                appWC.showWindow(control: control)
            }
            if let provider = locationProvider {
                mc.locationProvider = provider
            }
            if let camServer = cameraServer {
                mc.cameraServer = camServer
                camServer.onConnectionStateChange = { [weak mc] connected in
                    Task { @MainActor in
                        mc?.updateCameraConnectionState(connected: connected)
                    }
                }
            }
            let recorder = VPhoneScreenRecorder()
            mc.screenRecorder = recorder
            menuController = mc

            let socketPath = options.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("vphone.sock").path
            let hc = VPhoneHostControl(socketPath: socketPath)
            hc.start(
                captureView: wc.captureView!,
                screenRecorder: recorder,
                control: control,
                cameraServer: cameraServer,
                touchIDMonitor: wc.touchIDMonitor,
                virtualMachine: vm,
                keyHelper: keyHelper,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight
            )
            hostControl = hc

            // Wire location toggle through onConnect/onDisconnect
            control.onConnect = { [weak mc, weak provider = locationProvider] caps in
                mc?.updateConnectAvailability(available: true)
                mc?.updateInstallAvailability(available: caps.contains("ipa_install"))
                mc?.updateAppsAvailability(available: caps.contains("apps"))
                mc?.updateURLAvailability(available: caps.contains("url"))
                mc?.updateClipboardAvailability(available: caps.contains("clipboard"))
                mc?.updateSettingsAvailability(available: true)
                if caps.contains("location") {
                    mc?.updateLocationCapability(available: true)
                    // Auto-resume if user had toggle on
                    if mc?.locationMenuItem?.state == .on {
                        provider?.startForwarding()
                    }
                } else {
                    print("[location] guest does not support location simulation")
                }
                mc?.syncBatteryFromHost()
                mc?.syncLowPowerModeFromHost()
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak mc, weak provider = locationProvider] in
                mc?.updateConnectAvailability(available: false)
                mc?.updateInstallAvailability(available: false)
                mc?.updateAppsAvailability(available: false)
                mc?.updateURLAvailability(available: false)
                mc?.updateClipboardAvailability(available: false)
                mc?.updateSettingsAvailability(available: false)
                provider?.stopReplay()
                provider?.stopForwarding()
                mc?.updateLocationCapability(available: false)
            }
        } else if !cli.dfu {
            // Headless worker mode owns a VZVirtualMachineView attached to a
            // nonactivating off-screen window. Virtualization's native multitouch
            // path needs a window-backed view on iOS 27, but the worker must never
            // expose an onscreen phone surface or steal focus from the user.
            let keyHelper = VPhoneKeyHelper(vm: vm, control: control)
            headlessKeyHelper = keyHelper

            let hiddenView = VPhoneVirtualMachineView(
                frame: NSRect(
                    x: 0, y: 0,
                    width: CGFloat(options.screenWidth) / CGFloat(options.screenScale),
                    height: CGFloat(options.screenHeight) / CGFloat(options.screenScale)
                )
            )
            hiddenView.virtualMachine = vm.virtualMachine
            hiddenView.capturesSystemKeys = true
            hiddenView.keyHelper = keyHelper
            hiddenView.control = control
            hiddenView.headlessAutomation = true
            headlessControlView = hiddenView

            let offscreenWindow = NSWindow(
                contentRect: hiddenView.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            offscreenWindow.isReleasedWhenClosed = false
            offscreenWindow.ignoresMouseEvents = true
            offscreenWindow.isOpaque = false
            offscreenWindow.backgroundColor = .clear
            offscreenWindow.alphaValue = 0.01
            offscreenWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            offscreenWindow.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            offscreenWindow.contentView = hiddenView
            offscreenWindow.orderFront(nil)
            headlessControlWindow = offscreenWindow

            let recorder = VPhoneScreenRecorder()
            let socketPath = options.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("vphone.sock").path
            let hc = VPhoneHostControl(socketPath: socketPath)
            hc.start(
                captureView: hiddenView,
                screenRecorder: recorder,
                control: control,
                cameraServer: cameraServer,
                touchIDMonitor: nil,
                virtualMachine: vm,
                keyHelper: keyHelper,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight
            )
            hostControl = hc

            // Headless semantic workers must keep the control channel responsive.
            // Do not auto-forward host CoreLocation on connect: the guest's private
            // simulation path can block vphoned's serial request loop during boot.
            // Explicit MCP `location_set` remains available when location is needed.
            control.onConnect = { [weak self] caps in
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak provider = locationProvider] in
                provider?.stopReplay()
                provider?.stopForwarding()
            }
        }
    }

    @MainActor
    private func installPackageIfRequested(caps: [String]) async {
        guard !didAttemptAutoInstall else { return }
        guard let packageURL = cli.installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            didAttemptAutoInstall = true
            print("[install] requested package not found: \(packageURL.path)")
            return
        }
        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            didAttemptAutoInstall = true
            print("[install] unsupported package type: \(packageURL.path)")
            return
        }
        guard caps.contains("ipa_install") else {
            print(
                "[install] guest does not advertise ipa_install; reconnect or reboot the guest so the updated daemon can take over"
            )
            return
        }
        guard let control else {
            print("[install] control channel is not ready")
            return
        }

        didAttemptAutoInstall = true
        print("[install] auto-installing \(packageURL.lastPathComponent)")
        do {
            let result = try await control.installIPA(localURL: packageURL)
            print("[install] \(result)")
        } catch {
            print("[install] failed: \(error)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        hostControl?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !cli.noGraphics
    }
}
