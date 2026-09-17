import AppKit
import ArgumentParser
import Foundation
import Darwin

// Socket peers (guest vsock, host-control clients, serial consumers) may close
// independently during boot/reconnect. Treat EPIPE as a normal I/O error rather
// than allowing SIGPIPE to terminate the persistent worker process.
signal(SIGPIPE, SIG_IGN)

do {
    let command = try VPhoneCLI.parseAsRoot()

    switch command {
    case let boot as VPhoneBootCLI:
        let app = NSApplication.shared
        let delegate = VPhoneAppDelegate(cli: boot)
        app.delegate = delegate
        app.run()

    default:
        var runnable = command
        try runnable.run()
    }
} catch {
    VPhoneCLI.exit(withError: error)
}
