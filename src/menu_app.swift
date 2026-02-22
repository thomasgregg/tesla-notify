import AppKit
import Foundation
import Darwin

final class AppInstanceLock {
    private var fd: Int32 = -1

    func acquire(lockPath: String) -> Bool {
        let lockURL = URL(fileURLWithPath: lockPath)
        let dirURL = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            return false
        }

        fd = open(lockPath, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        if fd < 0 { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            fd = -1
            return false
        }
        return true
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}

final class OutputWindowController: NSWindowController {
    private let textView = NSTextView()

    init(title: String, content: String) {
        let rect = NSRect(x: 0, y: 0, width: 860, height: 520)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: rect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.frame = rect
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.string = content
        scrollView.documentView = textView

        window.contentView = scrollView
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(_ content: String) {
        textView.string = content
        textView.scrollToEndOfDocument(nil)
    }
}

final class LogWindowController: NSWindowController {
    private let logPath: String
    private let textView = NSTextView()
    private var timer: Timer?
    private var lastRendered = ""

    init(logPath: String) {
        self.logPath = logPath
        let rect = NSRect(x: 0, y: 0, width: 980, height: 560)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = "Tesla Notifier Live Logs"
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: rect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.frame = rect
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView

        window.contentView = scrollView
        super.init(window: window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let lines = tailLines(filePath: logPath, maxLines: 400)
        let rendered = lines.joined(separator: "\n")
        if rendered == lastRendered { return }
        lastRendered = rendered
        textView.string = rendered
        textView.scrollToEndOfDocument(nil)
    }

    private func tailLines(filePath: String, maxLines: Int) -> [String] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let text = String(data: data, encoding: .utf8) else {
            return ["Log file not found:", filePath]
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count <= maxLines { return lines }
        return Array(lines.suffix(maxLines))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appLock = AppInstanceLock()
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusLineItem: NSMenuItem!
    private var toggleForwarderItem: NSMenuItem!
    private var restartForwarderItem: NSMenuItem!
    private var logWindow: LogWindowController?
    private var outputWindow: OutputWindowController?
    private var statusTimer: Timer?

    private let home = NSHomeDirectory()
    private var appSupportDir: String { "\(home)/Library/Application Support/TeslaNotifier" }
    private var configPath: String { "\(appSupportDir)/config.json" }
    private var logPath: String { "\(appSupportDir)/forwarder.log" }
    private var verifyScriptPath: String { "\(appSupportDir)/verify_tesla_setup.sh" }
    private var launchAgentsDir: String { "\(home)/Library/LaunchAgents" }
    private var forwarderPlistPath: String { "\(launchAgentsDir)/com.tesla.notifier.forwarder.plist" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lockPath = NSHomeDirectory() + "/Library/Application Support/TeslaNotifier/menu.lock"
        if !appLock.acquire(lockPath: lockPath) {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let icon = NSImage(named: "AppIcon") {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = false
                button.image = icon
            } else {
                button.title = "T"
            }
            button.toolTip = "Tesla Notifier"
        }

        statusMenu = NSMenu()
        statusLineItem = NSMenuItem(title: "Status: checking...", action: nil, keyEquivalent: "")
        statusMenu.addItem(statusLineItem)
        statusMenu.addItem(NSMenuItem.separator())
        toggleForwarderItem = NSMenuItem(title: "▶ Start Forwarder", action: #selector(toggleForwarder), keyEquivalent: "s")
        restartForwarderItem = NSMenuItem(title: "↻ Restart Forwarder", action: #selector(restartForwarder), keyEquivalent: "r")
        statusMenu.addItem(toggleForwarderItem)
        statusMenu.addItem(restartForwarderItem)
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: "c"))
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Run Setup Check", action: #selector(runSetupCheck), keyEquivalent: "v"))
        statusMenu.addItem(NSMenuItem(title: "Live Logs", action: #selector(openLiveLogs), keyEquivalent: "l"))
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit Menu App", action: #selector(quitApp), keyEquivalent: "q"))

        for item in statusMenu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = statusMenu

        updateStatusLine()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStatusLine()
        }
    }

    private func updateStatusLine() {
        let running = isForwarderRunning()
        statusLineItem.title = running ? "Status: running" : "Status: not running"
        toggleForwarderItem.title = running ? "⏸ Stop Forwarder" : "▶ Start Forwarder"
        restartForwarderItem.isEnabled = running
    }

    private func isForwarderRunning() -> Bool {
        let result = runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/com.tesla.notifier.forwarder"]
        )
        return result.status == 0
    }

    @objc private func runSetupCheck() {
        guard FileManager.default.fileExists(atPath: verifyScriptPath) else {
            showAlert(title: "Setup Check Script Missing", message: verifyScriptPath)
            return
        }

        let loading = OutputWindowController(
            title: "Tesla Setup Check",
            content: "Running setup check...\n\nIf macOS permission dialogs appear, allow them and wait up to 45 seconds."
        )
        outputWindow = loading
        loading.showWindow(nil)
        loading.window?.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runProcess(
                executable: "/bin/bash",
                arguments: [self.verifyScriptPath, self.configPath],
                timeoutSeconds: 45
            )
            var output = ""
            if !result.stdout.isEmpty { output += result.stdout }
            if !result.stderr.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += result.stderr
            }
            if output.isEmpty {
                output = "No output. Exit status: \(result.status)"
            } else {
                output += "\n\nExit status: \(result.status)"
            }
            if result.timedOut {
                output += "\n\nTimed out after 45 seconds. This usually means a permission dialog is waiting for input."
            }

            DispatchQueue.main.async {
                self.outputWindow?.setContent(output)
                self.outputWindow?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.updateStatusLine()
            }
        }
    }

    @objc private func openLiveLogs() {
        if logWindow == nil {
            logWindow = LogWindowController(logPath: logPath)
        }
        logWindow?.showWindow(nil)
        logWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logWindow?.start()
    }

    @objc private func restartForwarder() {
        let result = runProcess(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", "gui/\(getuid())/com.tesla.notifier.forwarder"]
        )
        updateStatusLine()
        if result.status == 0 {
            showAlert(title: "Forwarder Restarted", message: "The forwarder is running.")
        } else {
            showAlert(title: "Restart Failed", message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    @objc private func toggleForwarder() {
        if isForwarderRunning() {
            stopForwarder()
        } else {
            startForwarder()
        }
    }

    private func startForwarder() {
        _ = runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", forwarderPlistPath]
        )
        let result = runProcess(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", "gui/\(getuid())/com.tesla.notifier.forwarder"]
        )
        updateStatusLine()
        if result.status == 0 {
            showAlert(title: "Forwarder Started", message: "The forwarder is running.")
        } else {
            showAlert(title: "Start Failed", message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func stopForwarder() {
        let result = runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())", forwarderPlistPath]
        )
        updateStatusLine()
        if result.status == 0 {
            showAlert(title: "Forwarder Stopped", message: "The forwarder has been stopped.")
        } else {
            showAlert(title: "Stop Failed", message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var timedOut = false
        do {
            try process.run()
            if let timeoutSeconds {
                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in semaphore.signal() }
                let wait = semaphore.wait(timeout: .now() + timeoutSeconds)
                if wait == .timedOut {
                    timedOut = true
                    process.terminate()
                    _ = semaphore.wait(timeout: .now() + 2)
                }
            } else {
                process.waitUntilExit()
            }
        } catch {
            return (-1, "", "Process launch failed: \(error.localizedDescription)", false)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err, timedOut)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
