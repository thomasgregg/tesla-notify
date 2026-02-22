#!/usr/bin/env swift
import Foundation
import Darwin

struct Config: Codable {
    var targetRecipient: String
    var messagePrefix: String
    var includeSenderInMessage: Bool
    var forwardingGateMode: String
    var forwardingGateFailOpen: Bool
    var senderAllowlist: [String]
    var dedupeWindowSeconds: Int
    var maxMessageLength: Int
    var logPath: String
    var statePath: String
    var debugNotificationDump: Bool
    var whatsappDBPath: String
    var pollIntervalSeconds: Int
    var teslaFleetVehicleDataURL: String
    var teslaFleetBearerToken: String
    var teslaFleetCacheSeconds: Int
    var teslaFleetAllowWhenUserPresent: Bool

    static func `default`(home: String) -> Config {
        let base = "\(home)/Library/Application Support/TeslaNotifier"
        return Config(
            targetRecipient: "+15555555555",
            messagePrefix: "[WA->Tesla]",
            includeSenderInMessage: true,
            forwardingGateMode: "always",
            forwardingGateFailOpen: true,
            senderAllowlist: [],
            dedupeWindowSeconds: 90,
            maxMessageLength: 500,
            logPath: "\(base)/forwarder.log",
            statePath: "\(base)/state.json",
            debugNotificationDump: false,
            whatsappDBPath: "\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite",
            pollIntervalSeconds: 5,
            teslaFleetVehicleDataURL: "",
            teslaFleetBearerToken: "",
            teslaFleetCacheSeconds: 20,
            teslaFleetAllowWhenUserPresent: true
        )
    }
}

struct State: Codable {
    var sentCount: Int
    var skippedCount: Int
    var failedCount: Int
    var recent: [String: Int]
    var lastSeenMessagePK: Int

    static let empty = State(sentCount: 0, skippedCount: 0, failedCount: 0, recent: [:], lastSeenMessagePK: 0)
}

struct IncomingMessage {
    let pk: Int
    let senderName: String
    let text: String
    let fromJid: String
    let chatJid: String
}

struct SendResult {
    let success: Bool
    let status: Int32
    let stdout: String
    let stderr: String
}

final class InstanceLock {
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

final class Forwarder {
    private var config: Config
    private var state: State
    private var gateCache: (allowed: Bool, ts: Int, reason: String)?

    init(config: Config, state: State) {
        self.config = config
        self.state = state
    }

    func start() {
        log("START forwarder initialized")

        if state.lastSeenMessagePK == 0 {
            if let maxPk = fetchMaxMessagePK() {
                state.lastSeenMessagePK = maxPk
                saveState()
                log("INIT lastSeenMessagePK=\(maxPk)")
            }
        }

        pollAndForward()
        Timer.scheduledTimer(withTimeInterval: TimeInterval(max(2, config.pollIntervalSeconds)), repeats: true) { [weak self] _ in
            self?.pollAndForward()
        }

        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.pruneRecent(now: Int(Date().timeIntervalSince1970))
            self?.saveState()
        }

        RunLoop.main.run()
    }

    private func pollAndForward() {
        let messages = fetchNewMessages(afterPK: state.lastSeenMessagePK)
        if messages.isEmpty { return }

        for message in messages {
            state.lastSeenMessagePK = max(state.lastSeenMessagePK, message.pk)

            if !senderAllowed(message.senderName) {
                state.skippedCount += 1
                log("SKIP allowlist sender=\(message.senderName)")
                continue
            }

            let gateDecision = shouldForwardNow()
            if !gateDecision.allowed {
                state.skippedCount += 1
                log("SKIP gate sender=\(message.senderName) pk=\(message.pk) reason=\(gateDecision.reason)")
                continue
            }
            log("PASS gate sender=\(message.senderName) pk=\(message.pk) reason=\(gateDecision.reason)")

            let sender = sanitize(message.senderName)
            let normalizedMessage = buildForwardMessage(sender: sender, message: message.text)
            let msgHash = shortHash(normalizedMessage)
            let msgLen = normalizedMessage.count

            if shouldSkipDuplicate(sender: sender, message: normalizedMessage) {
                state.skippedCount += 1
                log("SKIP duplicate sender=\(sender) pk=\(message.pk) hash=\(msgHash) len=\(msgLen)")
                continue
            }

            let result = sendViaMessages(recipient: config.targetRecipient, body: normalizedMessage)
            if result.success {
                state.sentCount += 1
                log("SENT to=\(config.targetRecipient) sender=\(sender) pk=\(message.pk) hash=\(msgHash) len=\(msgLen) status=\(result.status) detail=\(sanitizeLogValue(result.stdout))")
            } else {
                state.failedCount += 1
                log("FAIL to=\(config.targetRecipient) sender=\(sender) pk=\(message.pk) hash=\(msgHash) len=\(msgLen) status=\(result.status) stderr=\(sanitizeLogValue(result.stderr)) stdout=\(sanitizeLogValue(result.stdout))")
            }
        }

        saveState()
    }

    private func senderAllowed(_ sender: String) -> Bool {
        if config.senderAllowlist.isEmpty { return true }
        return config.senderAllowlist.contains(sender)
    }

    private func shouldForwardNow() -> (allowed: Bool, reason: String) {
        let mode = config.forwardingGateMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mode.isEmpty || mode == "always" || mode == "off" || mode == "none" {
            return (true, "gate=always")
        }
        if mode == "tesla_fleet" {
            return evaluateTeslaFleetGate()
        }
        return (true, "gate=unknown_mode_fallback")
    }

    private func evaluateTeslaFleetGate() -> (allowed: Bool, reason: String) {
        let now = Int(Date().timeIntervalSince1970)
        let cacheSeconds = max(1, config.teslaFleetCacheSeconds)
        if let cached = gateCache, now - cached.ts < cacheSeconds {
            return (cached.allowed, "cached:\(cached.reason)")
        }

        let urlText = config.teslaFleetVehicleDataURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = config.teslaFleetBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlText.isEmpty || token.isEmpty {
            let allowed = config.forwardingGateFailOpen
            let reason = "tesla_fleet_missing_config failOpen=\(config.forwardingGateFailOpen)"
            gateCache = (allowed, now, reason)
            return (allowed, reason)
        }

        guard let url = URL(string: urlText) else {
            let allowed = config.forwardingGateFailOpen
            let reason = "tesla_fleet_bad_url failOpen=\(config.forwardingGateFailOpen)"
            gateCache = (allowed, now, reason)
            return (allowed, reason)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var statusCode = -1
        var responseData: Data?
        var requestError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
            }
            responseData = data
            requestError = error
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let err = requestError {
            let allowed = config.forwardingGateFailOpen
            let reason = "tesla_fleet_request_error=\(err.localizedDescription) failOpen=\(config.forwardingGateFailOpen)"
            gateCache = (allowed, now, reason)
            return (allowed, reason)
        }

        guard statusCode >= 200 && statusCode < 300 else {
            let allowed = config.forwardingGateFailOpen
            let reason = "tesla_fleet_http_status=\(statusCode) failOpen=\(config.forwardingGateFailOpen)"
            gateCache = (allowed, now, reason)
            return (allowed, reason)
        }

        guard
            let body = responseData,
            let rootAny = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            let allowed = config.forwardingGateFailOpen
            let reason = "tesla_fleet_bad_json failOpen=\(config.forwardingGateFailOpen)"
            gateCache = (allowed, now, reason)
            return (allowed, reason)
        }

        let payload = (rootAny["response"] as? [String: Any]) ?? rootAny
        let userPresent = boolAtPath(payload, path: ["vehicle_state", "is_user_present"]) ?? false
        let byUserPresent = config.teslaFleetAllowWhenUserPresent && userPresent
        let allowed = byUserPresent
        let reason = "tesla_fleet userPresent=\(userPresent)"
        gateCache = (allowed, now, reason)
        return (allowed, reason)
    }

    private func boolAtPath(_ root: [String: Any], path: [String]) -> Bool? {
        guard let value = valueAtPath(root, path: path) else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            let lower = s.lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
        }
        return nil
    }

    private func valueAtPath(_ root: [String: Any], path: [String]) -> Any? {
        var current: Any = root
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func buildForwardMessage(sender: String, message: String) -> String {
        var content = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { content = "(non-text message)" }
        if content.count > config.maxMessageLength {
            content = String(content.prefix(config.maxMessageLength)) + "..."
        }
        var parts: [String] = []
        let prefix = config.messagePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty {
            parts.append(prefix)
        }

        if config.includeSenderInMessage {
            parts.append("\(sender): \(content)")
        } else {
            parts.append(content)
        }

        return parts.joined(separator: " ")
    }

    private func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private func shouldSkipDuplicate(sender: String, message: String) -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        pruneRecent(now: now)

        let key = "\(sender)|\(message)"
        if let last = state.recent[key], now - last <= config.dedupeWindowSeconds {
            return true
        }
        state.recent[key] = now
        return false
    }

    private func pruneRecent(now: Int) {
        state.recent = state.recent.filter { (_, ts) in
            now - ts <= config.dedupeWindowSeconds
        }
    }

    private func sendViaMessages(recipient: String, body: String) -> SendResult {
        let escapedRecipient = appleScriptEscape(recipient)
        let escapedBody = appleScriptEscape(body)
        let script = """
        tell application \"Messages\"
          set targetService to missing value
          try
            set targetService to first service whose service type = iMessage and enabled is true
          end try
          if targetService is missing value then
            set targetService to first service whose enabled is true
          end if

          set targetParticipant to participant \"\(escapedRecipient)\" of targetService
          send \"\(escapedBody)\" to targetParticipant
          return \"method=service_participant service=\" & (id of targetService as text)
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmedOut = outText.trimmingCharacters(in: .whitespacesAndNewlines)
            let scriptReportedError = trimmedOut.lowercased().hasPrefix("error ")
            let ok = process.terminationStatus == 0 && !scriptReportedError
            return SendResult(
                success: ok,
                status: process.terminationStatus,
                stdout: trimmedOut,
                stderr: errText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return SendResult(
                success: false,
                status: -1,
                stdout: "",
                stderr: "osascript_run_failed:\(error.localizedDescription)"
            )
        }
    }

    private func fetchMaxMessagePK() -> Int? {
        let sql = "SELECT COALESCE(MAX(Z_PK), 0) FROM ZWAMESSAGE;"
        let lines = runSQLite(sql: sql)
        guard let first = lines.first else { return nil }
        return Int(first.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func fetchNewMessages(afterPK: Int) -> [IncomingMessage] {
        let sql = """
        SELECT
          m.Z_PK,
          COALESCE(NULLIF(TRIM(s.ZPARTNERNAME), ''), m.ZFROMJID, s.ZCONTACTJID, 'Unknown') AS sender,
          REPLACE(REPLACE(COALESCE(m.ZTEXT, ''), char(10), ' '), char(9), ' ') AS msg,
          COALESCE(m.ZFROMJID, '') AS from_jid,
          COALESCE(s.ZCONTACTJID, '') AS chat_jid
        FROM ZWAMESSAGE m
        LEFT JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
        WHERE m.ZISFROMME = 0
          AND m.Z_PK > \(afterPK)
        ORDER BY m.Z_PK ASC
        LIMIT 100;
        """

        let rows = runSQLite(sql: sql)
        var out: [IncomingMessage] = []

        for line in rows {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count < 5 { continue }
            guard let pk = Int(parts[0]) else { continue }

            let sender = parts[1]
            let text = parts[2]
            let fromJid = parts[3]
            let chatJid = parts[4]

            if shouldIgnoreRow(sender: sender, fromJid: fromJid, chatJid: chatJid) { continue }

            out.append(IncomingMessage(pk: pk, senderName: sender, text: text, fromJid: fromJid, chatJid: chatJid))
        }

        if config.debugNotificationDump && !out.isEmpty {
            log("DEBUG fetched_messages=\(out.count) last_pk=\(out.last?.pk ?? 0)")
        }

        return out
    }

    private func shouldIgnoreRow(sender: String, fromJid: String, chatJid: String) -> Bool {
        let s = sender.lowercased()
        let f = fromJid.lowercased()
        let c = chatJid.lowercased()

        if s == "whatsapp" { return true }
        if c.contains("@status") || f.contains("@status") { return true }
        if c == "0@status" || f == "0@status" { return true }
        return false
    }

    private func runSQLite(sql: String) -> [String] {
        let dbPath = config.whatsappDBPath
        if !FileManager.default.fileExists(atPath: dbPath) {
            log("ERROR whatsapp db missing path=\(dbPath)")
            return []
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-tabs", dbPath, sql]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("ERROR sqlite run failed err=\(error.localizedDescription)")
            return []
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            log("ERROR sqlite status=\(process.terminationStatus) err=\(errText)")
            return []
        }

        let text = String(data: outData, encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func appleScriptEscape(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\\", with: "\\\\")
        value = value.replacingOccurrences(of: "\"", with: "\\\"")
        return value
    }

    private func shortHash(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = data.withUnsafeBytes { ptr in
            var h: UInt64 = 1469598103934665603
            for b in ptr {
                h ^= UInt64(b)
                h = h &* 1099511628211
            }
            return h
        }
        return String(format: "%016llx", digest)
    }

    private func sanitizeLogValue(_ text: String) -> String {
        if text.isEmpty { return "-" }
        var cleaned = text.replacingOccurrences(of: "\n", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\t", with: " ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveState() {
        let stateURL = URL(fileURLWithPath: config.statePath)
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            log("ERROR saveState failed err=\(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(message)\n"

        let url = URL(fileURLWithPath: config.logPath)
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                handle.write(Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url)
            }
        } catch {
            fputs("\(line)", stderr)
        }
    }
}

func loadConfig(path: String?) -> Config {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var cfg = Config.default(home: home)
    guard let path else { return cfg }

    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        return cfg
    }

    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return cfg
    }

    if let v = raw["targetRecipient"] as? String { cfg.targetRecipient = v }
    if let v = raw["messagePrefix"] as? String { cfg.messagePrefix = v }
    if let v = raw["includeSenderInMessage"] as? Bool { cfg.includeSenderInMessage = v }
    if let v = raw["forwardingGateMode"] as? String { cfg.forwardingGateMode = v }
    if let v = raw["forwardingGateFailOpen"] as? Bool { cfg.forwardingGateFailOpen = v }
    if let v = raw["senderAllowlist"] as? [String] { cfg.senderAllowlist = v }
    if let v = raw["dedupeWindowSeconds"] as? Int { cfg.dedupeWindowSeconds = v }
    if let v = raw["maxMessageLength"] as? Int { cfg.maxMessageLength = v }
    if let v = raw["logPath"] as? String { cfg.logPath = v }
    if let v = raw["statePath"] as? String { cfg.statePath = v }
    if let v = raw["debugNotificationDump"] as? Bool { cfg.debugNotificationDump = v }
    if let v = raw["whatsappDBPath"] as? String { cfg.whatsappDBPath = v }
    if let v = raw["pollIntervalSeconds"] as? Int { cfg.pollIntervalSeconds = v }
    if let v = raw["teslaFleetVehicleDataURL"] as? String { cfg.teslaFleetVehicleDataURL = v }
    if let v = raw["teslaFleetBearerToken"] as? String { cfg.teslaFleetBearerToken = v }
    if let v = raw["teslaFleetCacheSeconds"] as? Int { cfg.teslaFleetCacheSeconds = v }
    if let v = raw["teslaFleetAllowWhenUserPresent"] as? Bool { cfg.teslaFleetAllowWhenUserPresent = v }

    return cfg
}

func loadState(path: String) -> State {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        return .empty
    }
    return (try? JSONDecoder().decode(State.self, from: data)) ?? .empty
}

let configPath = CommandLine.arguments.dropFirst().first
let lockPath = NSHomeDirectory() + "/Library/Application Support/TeslaNotifier/forwarder.lock"
let instanceLock = InstanceLock()
if !instanceLock.acquire(lockPath: lockPath) {
    fputs("Another tesla-notifier-forwarder instance is already running.\n", stderr)
    exit(0)
}

let config = loadConfig(path: configPath)
let state = loadState(path: config.statePath)
let app = Forwarder(config: config, state: state)
app.start()
