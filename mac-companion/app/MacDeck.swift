// MacDeck 選單列 App：啟動 / 停止 Companion、切換 Live、複製 Kobo 設定、看 log
// 由這個 App 啟動 Companion，macOS 的權限（控制 Music、輔助使用）就會算在 MacDeck 身上，
// 不會因為是從 VS Code 終端機啟動而被靜默拒絕。
import AppKit
import SwiftUI

@MainActor
final class Companion: ObservableObject {
    enum State: Equatable { case stopped, starting, running, failed(String) }

    @Published var state: State = .stopped
    @Published var address = ""
    @Published var live: Bool {
        didSet {
            UserDefaults.standard.set(live, forKey: "live")
            if isRunning { restart() }
        }
    }

    let dir: URL
    let logURL: URL
    private var process: Process?
    private var stopping = false
    private var pending = ""

    init() {
        let path = Bundle.main.object(forInfoDictionaryKey: "MacDeckCompanionDir") as? String ?? ""
        dir = URL(fileURLWithPath: path)
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacDeck")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("companion.log")
        live = UserDefaults.standard.bool(forKey: "live")
        if UserDefaults.standard.bool(forKey: "running") { start() } // 上次關 App 時是開著的就自動開
    }

    var isRunning: Bool { state == .running || state == .starting }

    var statusText: String {
        switch state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running · \(address)" + (live ? " · live" : " · dry-run")
        case .failed(let why): return "Stopped: \(why)"
        }
    }

    func start() {
        guard process == nil else { return }
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("macdeck_companion").path) else {
            state = .failed("companion folder not found")
            return
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-u", "-m", "macdeck_companion", "--lan"] + (live ? ["--live"] : [])
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" // App 啟動時 PATH 很短
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            log?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.exited(code) }
        }
        do {
            try p.run()
            process = p
            stopping = false
            state = .starting
            UserDefaults.standard.set(true, forKey: "running")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: "running")
        guard let p = process else { state = .stopped; return }
        stopping = true
        p.interrupt() // SIGINT：Companion 收到 KeyboardInterrupt 會正常結束
    }

    func restart() {
        guard let p = process else { return start() }
        stopping = true
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.start()
            }
        }
        p.interrupt()
    }

    private func consume(_ text: String) {
        pending += text
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending.removeSubrange(...nl)
            if let r = line.range(of: "listening on ") {
                address = String(line[r.upperBound...].split(separator: " ").first ?? "")
                state = .running
            } else if line.contains("Address already in use") {
                state = .failed("port 8765 in use (another Companion running?)")
            }
        }
    }

    private func exited(_ code: Int32) {
        process = nil
        if stopping || code == 0 {
            state = .stopped
        } else if case .failed = state {
            // 已經有更具體的原因
        } else {
            state = .failed("exited (\(code)), see log")
        }
        stopping = false
    }

    /// Kobo 的 macdeck.lua 內容（含 host 與 token），複製到剪貼簿
    func copyKoboSettings() {
        let token = (try? String(contentsOf: dir.appendingPathComponent("token.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = address.split(separator: ":").first.map(String.init) ?? ""
        let lua = """
        return {
            config = {
                transport = { preferred = "wifi", wifi = { host = "\(host)", token = "\(token)" } },
            },
        }

        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lua, forType: .string)
    }

    func openLog() { NSWorkspace.shared.open(logURL) }
    func openFolder() { NSWorkspace.shared.open(dir) }

    func quit() {
        let wasRunning = UserDefaults.standard.bool(forKey: "running")
        if let p = process {
            p.terminationHandler = nil
            p.interrupt()
            p.waitUntilExit()
        }
        UserDefaults.standard.set(wasRunning, forKey: "running") // 下次開 App 時照原樣恢復
        NSApp.terminate(nil)
    }
}

@main
struct MacDeckApp: App {
    @StateObject private var companion = Companion()

    var body: some Scene {
        MenuBarExtra {
            Text(companion.statusText)
            Divider()
            if companion.isRunning {
                Button("Stop Companion") { companion.stop() }
            } else {
                Button("Start Companion") { companion.start() }
            }
            Toggle("Live mode (control this Mac)", isOn: $companion.live)
            Divider()
            Button("Copy Kobo settings") { companion.copyKoboSettings() }
                .disabled(companion.state != .running)
            Button("Open log") { companion.openLog() }
            Button("Open companion folder") { companion.openFolder() }
            Divider()
            Button("Quit MacDeck") { companion.quit() }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: companion.state == .running ? "rectangle.connected.to.line.below" : "rectangle.dashed")
        }
    }
}
