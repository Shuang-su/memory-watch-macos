import AppKit
import UserNotifications
import Darwin

let GiB = Double(1 << 30)
let appID = "local.shuangsu.memory-watch"
let supportURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Memory Watch", isDirectory: true)

struct Reading {
    let pid: Int32
    let birth: UInt64
    let name: String
    let bytes: UInt64
    var executablePath: String = ""
    var gib: Double { Double(bytes) / GiB }
    var key: String { "\(pid):\(birth)" }
}

func readUsage(_ pid: Int32) -> rusage_info_v0? {
    var usage = rusage_info_v0()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
        }
    }
    return result == 0 ? usage : nil
}

func readProcess(_ pid: Int32) -> Reading? {
    guard let usage = readUsage(pid) else { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    let executable = length > 0 ? String(cString: path) : ""
    let name = executable.isEmpty ? "PID \(pid)" : (executable as NSString).lastPathComponent
    return Reading(pid: pid, birth: usage.ri_proc_start_abstime, name: name,
                   bytes: usage.ri_phys_footprint, executablePath: executable)
}

func snapshot() -> (items: [Reading], skipped: Int) {
    let capacity = max(Int(proc_listallpids(nil, 0)) + 512, 2048)
    var pids = [Int32](repeating: 0, count: capacity)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return ([], 0) }
    var items: [Reading] = []
    var skipped = 0
    for pid in pids.prefix(min(Int(count), capacity)) where pid > 0 && pid != getpid() {
        guard let reading = readProcess(pid) else { skipped += 1; continue }
        items.append(reading)
    }
    return (items.sorted { $0.bytes > $1.bytes }, skipped)
}

struct CheckedProcess {
    let reading: Reading
    let owner: uid_t
}

func checkedProcess(_ pid: Int32) -> CheckedProcess? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let count = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    guard count == Int32(size), let reading = readProcess(pid) else { return nil }
    return CheckedProcess(reading: reading, owner: info.pbi_uid)
}

func processHasExited(_ expected: Reading) -> Bool {
    if Darwin.kill(expected.pid, 0) != 0 && errno == ESRCH { return true }
    if let usage = readUsage(expected.pid), usage.ri_proc_start_abstime != expected.birth { return true }
    return false // Access failure is not proof that termination succeeded.
}

struct AutoExitAttempt {
    let reading: Reading
    let error: Int32?
}

final class SceneKitProtection {
    static let name = "SceneKitQLThumbnailExtension"
    static let path = "/System/Library/Frameworks/SceneKit.framework/PlugIns/SceneKitQLThumbnailExtension.appex/Contents/MacOS/SceneKitQLThumbnailExtension"
    static let limit: UInt64 = 4 * (1 << 30)
    private var attempts: [String: Double] = [:]

    private func matches(_ reading: Reading) -> Bool {
        reading.pid > 1 && reading.pid != getpid() && reading.name == Self.name
            && reading.executablePath == Self.path && reading.bytes >= Self.limit
    }

    func enforce(_ items: [Reading], now: Double, enabled: Bool,
                 probe: (Int32) -> CheckedProcess? = checkedProcess,
                 signal: (Int32, Int32) -> Int32 = Darwin.kill) -> [AutoExitAttempt] {
        let live = Set(items.map { $0.key })
        attempts = attempts.filter { live.contains($0.key) }
        guard enabled else { return [] }
        var results: [AutoExitAttempt] = []
        for candidate in items where matches(candidate) {
            guard now - (attempts[candidate.key] ?? -.infinity) >= 60 else { continue }
            // Re-read identity, ownership and footprint immediately before the signal.
            guard let current = probe(candidate.pid), current.owner == getuid(),
                  current.reading.pid == candidate.pid, current.reading.birth == candidate.birth,
                  matches(current.reading) else { continue }
            attempts[candidate.key] = now
            let result = signal(current.reading.pid, SIGKILL)
            results.append(AutoExitAttempt(reading: current.reading, error: result == 0 ? nil : errno))
        }
        return results
    }
}

struct Alert {
    let reading: Reading
    let level: Int
    let reason: String
    var text: String { String(format: "%@ · PID %d · %.2f GiB\n%@", reading.name, reading.pid, reading.gib, reason) }
}

struct Track {
    var history: [(Double, Double)] = []
    var highSamples = 0
    var lastAlert = -Double.infinity
    var lastLevel = 0
}

final class Detector {
    var warn: Double = 2
    var critical: Double = 4
    var tracks: [String: Track] = [:]
    var hasProblem = false
    func update(_ items: [Reading], now: Double) -> [Alert] {
        hasProblem = false
        var next: [String: Track] = [:]
        var alerts: [Alert] = []
        for item in items {
            var track = tracks[item.key] ?? Track()
            track.history.removeAll { now - $0.0 > 60 }
            track.history.append((now, item.gib))
            let elapsed = now - track.history[0].0
            let growth = item.gib - track.history[0].1
            track.highSamples = item.gib >= warn ? track.highSamples + 1 : 0
            var level = 0
            var reason = ""
            if item.gib >= critical {
                level = 3; reason = "达到严重阈值 \(Int(critical)) GiB，请检查活动监视器。"
            } else if track.highSamples >= 2 {
                level = 2; reason = "连续两次超过 \(Int(warn)) GiB。"
            } else if item.gib >= 1 && elapsed >= 10 && growth >= 0.5 {
                level = 1; reason = String(format: "%.0f 秒内增长 %.0f MiB。", elapsed, growth * 1024)
            }
            if level > 0 { hasProblem = true }
            if level > 0 && (now - track.lastAlert >= 300 || level > track.lastLevel) {
                alerts.append(Alert(reading: item, level: level, reason: reason))
                track.lastAlert = now; track.lastLevel = level
            }
            next[item.key] = track
        }
        tracks = next
        return alerts.sorted { $0.level == $1.level ? $0.reading.bytes > $1.reading.bytes : $0.level > $1.level }
    }
}

// Event-only logging, bounded to two 256 KiB files; process arguments are never collected.
func logEvent(_ message: String) {
    try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
    let url = supportURL.appendingPathComponent("events.log")
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    if size > 256 * 1024 {
        let previous = supportURL.appendingPathComponent("events.previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message.replacingOccurrences(of: "\n", with: " | "))\n"
    guard let data = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                      attributes: [.posixPermissions: 0o600])
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var status: NSStatusItem!
    var timer: Timer?
    let detector = Detector()
    let sceneKitProtection = SceneKitProtection()
    let worker = DispatchQueue(label: "memory-watch.sampling", qos: .utility)
    var busy = false
    var paused = false
    var readings: [Reading] = []
    var skipped = 0
    var sampled = false
    var latest = "尚无告警"
    var notificationState = "正在检查通知权限…"
    var relaxed = UserDefaults.standard.bool(forKey: "relaxed")
    var autoExitSceneKit = UserDefaults.standard.object(forKey: "autoExitSceneKit") == nil
        ? true : UserDefaults.standard.bool(forKey: "autoExitSceneKit")
    var agentURL: URL { FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(appID).plist") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(problem: false)
        status.button?.imagePosition = .imageOnly
        status.button?.title = ""
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, error in
            DispatchQueue.main.async {
                self.notificationState = allowed ? "通知已允许" : "通知未允许：点击打开设置"
                logEvent("notificationAuthorization allowed=\(allowed) error=\(error?.localizedDescription ?? "none")")
            }
        }
        logEvent("started version=1.1.0 interval=5s sceneKitAutoExit=\(autoExitSceneKit) thresholdGiB=4 otherProcessesAlertsOnly=true")
        applyThresholds()
        tick()
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func tick() {
        guard !busy && !paused else { return }
        busy = true
        worker.async {
            let result = snapshot()
            DispatchQueue.main.async {
                self.busy = false
                guard !self.paused else { return }
                self.readings = result.items; self.skipped = result.skipped
                if !self.sampled {
                    logEvent("firstSample readable=\(result.items.count) unavailable=\(result.skipped)")
                    self.sampled = true
                }
                guard !result.items.isEmpty else {
                    self.setStatusIcon(problem: true)
                    self.status.button?.toolTip = "未能读取进程；下一轮会重试。"
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                let actions = self.sceneKitProtection.enforce(result.items, now: now, enabled: self.autoExitSceneKit)
                let handled = Set(actions.map { $0.reading.key })
                let alerts = self.detector.update(result.items, now: now).filter { !handled.contains($0.reading.key) }
                let highest = result.items.first!
                self.setStatusIcon(problem: self.detector.hasProblem || !actions.isEmpty)
                self.status.button?.toolTip = String(format: "最高：%@ · %.2f GiB\n每 5 秒检查，点击查看进程。", highest.name, highest.gib)
                if !alerts.isEmpty {
                    for alert in alerts { logEvent("ALERT level=\(alert.level) \(alert.text)") }
                    self.latest = alerts[0].text
                    var text = alerts.prefix(2).map { $0.text }.joined(separator: "\n")
                    if alerts.count > 2 { text += "\n另有 \(alerts.count - 2) 个进程，详情见日志。" }
                    self.sendNotification(text)
                }
                self.reportAutoExits(actions)
            }
        }
    }

    func reportAutoExits(_ actions: [AutoExitAttempt]) {
        guard !actions.isEmpty else { return }
        for action in actions {
            logEvent("AUTO_EXIT_ATTEMPT pid=\(action.reading.pid) footprintGiB=\(action.reading.gib) signal=SIGKILL errno=\(action.error ?? 0)")
        }
        // Check after the OS has had time to reap the process; do not block the UI.
        worker.asyncAfter(deadline: .now() + 0.5) {
            let messages = actions.map { action -> String in
                let detail = String(format: "%@ · PID %d · %.2f GiB", action.reading.name, action.reading.pid, action.reading.gib)
                if let error = action.error {
                    if error == ESRCH { return "进程已自行退出：\(detail)" }
                    return "自动强制退出失败（errno \(error)）：\(detail)"
                }
                return processHasExited(action.reading)
                    ? "已自动强制退出：\(detail)（阈值 4 GiB）"
                    : "已发送强制退出信号，尚未确认退出：\(detail)"
            }
            DispatchQueue.main.async {
                for message in messages { logEvent("AUTO_EXIT_RESULT \(message)") }
                self.latest = messages[0]
                var text = messages.prefix(2).joined(separator: "\n")
                if messages.count > 2 { text += "\n另有 \(messages.count - 2) 项处理结果，详情见日志。" }
                self.sendNotification(text)
            }
        }
    }

    func setStatusIcon(problem: Bool) {
        let symbol = paused ? "pause.circle" : "memorychip"
        let description = paused ? "内存提醒已暂停" : (problem ? "内存异常" : "内存提醒")
        var icon = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if problem && !paused {
            icon = icon?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            icon?.isTemplate = false
        } else {
            icon?.isTemplate = true
        }
        status.button?.image = icon
    }

    func sendNotification(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "进程内存提醒"; content.body = text; content.sound = .default
        // Reuse the identifier so Notification Center does not accumulate hundreds of alerts.
        let request = UNNotificationRequest(identifier: "memory-watch-current", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { DispatchQueue.main.async { logEvent("notificationError \(error.localizedDescription)") } }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        DispatchQueue.main.async { self.openActivityMonitor() }; completion()
    }

    func item(_ menu: NSMenu, _ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self; menu.addItem(entry); return entry
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        _ = item(menu, paused ? "内存监控 · 已暂停" : "内存监控 · 每 5 秒检查")
        _ = item(menu, "\(readings.count) 个可读进程 · \(skipped) 个不可读/已退出")
        menu.addItem(.separator())
        for reading in readings.prefix(7) {
            let row = item(menu, String(format: "%.2f GiB  %@  [PID %d]", reading.gib, reading.name, reading.pid), #selector(openActivityMonitor))
            row.toolTip = "打开活动监视器，可按 PID 查找此进程。"
        }
        menu.addItem(.separator())
        _ = item(menu, "最近告警：\(latest.replacingOccurrences(of: "\n", with: " · "))")
        _ = item(menu, "\(Int(detector.warn))/\(Int(detector.critical)) GiB 告警 · 60 秒内增长 512 MiB")
        let mode = item(menu, "宽松阈值（4 / 8 GiB）", #selector(toggleRelaxed)); mode.state = relaxed ? .on : .off
        let protection = item(menu, "自动退出过大 SceneKit 缩略图（≥4 GiB）", #selector(toggleSceneKitProtection))
        protection.state = autoExitSceneKit ? .on : .off
        _ = item(menu, paused ? "恢复监控" : "暂停监控", #selector(togglePause))
        menu.addItem(.separator())
        _ = item(menu, "发送测试通知", #selector(testNotification))
        _ = item(menu, notificationState, #selector(openNotifications))
        _ = item(menu, "打开活动监视器", #selector(openActivityMonitor))
        _ = item(menu, "查看告警日志", #selector(openLogs))
        let login = item(menu, "登录时自动启动", #selector(toggleLogin))
        login.state = FileManager.default.fileExists(atPath: agentURL.path) ? .on : .off
        _ = item(menu, "退出内存提醒", #selector(quit))
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationState = settings.authorizationStatus == .authorized ? "通知已允许" : "通知未允许：点击打开设置"
            }
        }
    }

    func applyThresholds() { detector.warn = relaxed ? 4 : 2; detector.critical = relaxed ? 8 : 4 }
    @objc func toggleSceneKitProtection() {
        autoExitSceneKit.toggle()
        UserDefaults.standard.set(autoExitSceneKit, forKey: "autoExitSceneKit")
        logEvent("sceneKitAutoExit=\(autoExitSceneKit) thresholdGiB=4")
        if autoExitSceneKit { tick() }
    }
    @objc func toggleRelaxed() {
        relaxed.toggle(); UserDefaults.standard.set(relaxed, forKey: "relaxed")
        detector.tracks.removeAll(); applyThresholds(); tick()
    }
    @objc func togglePause() {
        paused.toggle(); detector.tracks.removeAll()
        setStatusIcon(problem: false)
        if paused { status.button?.toolTip = "内存监控已暂停，点击菜单恢复。" }
        logEvent(paused ? "paused" : "resumed"); if !paused { tick() }
    }
    @objc func testNotification() { sendNotification("这是一条测试通知。内存提醒正在运行；点击通知可打开活动监视器。") }
    @objc func openActivityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
    @objc func openNotifications() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
    @objc func openLogs() { NSWorkspace.shared.open(supportURL) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() {
        do {
            if FileManager.default.fileExists(atPath: agentURL.path) {
                try FileManager.default.removeItem(at: agentURL)
                runLaunchctl(["bootout", "gui/\(getuid())/\(appID)"])
            } else {
                let plist: [String: Any] = ["Label": appID, "RunAtLoad": true,
                    "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath]]
                try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL, options: .atomic)
                runLaunchctl(["enable", "gui/\(getuid())/\(appID)"])
                runLaunchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
            }
            logEvent("loginItem enabled=\(FileManager.default.fileExists(atPath: agentURL.path))")
        } catch { latest = "自启动设置失败：\(error.localizedDescription)"; logEvent(latest) }
    }
    func runLaunchctl(_ arguments: [String]) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run(); process.waitUntilExit()
            if process.terminationStatus != 0 {
                latest = "自启动命令返回 \(process.terminationStatus)，请查看日志。"
                logEvent("launchctl \(arguments.joined(separator: " ")) exit=\(process.terminationStatus)")
            }
        } catch { latest = "自启动设置失败"; logEvent("launchctl error \(error.localizedDescription)") }
    }
}

func protectionSelfTest() {
    func target(_ bytes: UInt64 = SceneKitProtection.limit, birth: UInt64 = 1) -> Reading {
        Reading(pid: 42, birth: birth, name: SceneKitProtection.name, bytes: bytes,
                executablePath: SceneKitProtection.path)
    }
    let candidate = target()
    var signals = 0
    let signal: (Int32, Int32) -> Int32 = { pid, value in
        precondition(pid == 42 && value == SIGKILL); signals += 1; return 0
    }
    let probe: (Int32) -> CheckedProcess? = { _ in CheckedProcess(reading: candidate, owner: getuid()) }
    let guardrail = SceneKitProtection()
    precondition(guardrail.enforce([target(SceneKitProtection.limit - 1)], now: 0, enabled: true, probe: probe, signal: signal).isEmpty)
    precondition(guardrail.enforce([candidate], now: 0, enabled: false, probe: probe, signal: signal).isEmpty)
    precondition(signals == 0)
    precondition(guardrail.enforce([candidate], now: 0, enabled: true, probe: probe, signal: signal).count == 1)
    precondition(signals == 1)
    precondition(guardrail.enforce([candidate], now: 5, enabled: true, probe: probe, signal: signal).isEmpty)
    precondition(guardrail.enforce([candidate], now: 60, enabled: true, probe: probe, signal: signal).count == 1)
    precondition(signals == 2)

    let wrongPath = Reading(pid: 42, birth: 1, name: SceneKitProtection.name,
                            bytes: SceneKitProtection.limit, executablePath: "/tmp/SceneKitQLThumbnailExtension")
    let preview = Reading(pid: 42, birth: 1, name: "SceneKitQLPreviewExtension",
                          bytes: 16 * (1 << 30), executablePath: SceneKitProtection.path)
    let other = Reading(pid: 42, birth: 1, name: "WeChat", bytes: 16 * (1 << 30))
    for item in [wrongPath, preview, other] {
        precondition(SceneKitProtection().enforce([item], now: 0, enabled: true, probe: probe, signal: signal).isEmpty)
    }
    let changedPID = Reading(pid: 43, birth: 1, name: SceneKitProtection.name,
                            bytes: SceneKitProtection.limit, executablePath: SceneKitProtection.path)
    let checks: [CheckedProcess?] = [nil,
        CheckedProcess(reading: target(birth: 2), owner: getuid()),
        CheckedProcess(reading: target(SceneKitProtection.limit - 1), owner: getuid()),
        CheckedProcess(reading: candidate, owner: getuid() + 1),
        CheckedProcess(reading: wrongPath, owner: getuid()),
        CheckedProcess(reading: changedPID, owner: getuid())]
    for check in checks {
        precondition(SceneKitProtection().enforce([candidate], now: 0, enabled: true,
                     probe: { _ in check }, signal: signal).isEmpty)
    }
    precondition(signals == 2)

    let failing = SceneKitProtection()
    let denied: (Int32, Int32) -> Int32 = { _, _ in errno = EPERM; return -1 }
    precondition(failing.enforce([candidate], now: 0, enabled: true, probe: probe, signal: denied).first?.error == EPERM)
    precondition(failing.enforce([candidate], now: 5, enabled: true, probe: probe, signal: signal).isEmpty)
    let restarted = target(birth: 2)
    precondition(failing.enforce([restarted], now: 5, enabled: true,
                 probe: { _ in CheckedProcess(reading: restarted, owner: getuid()) }, signal: signal).count == 1)

    // Real SIGKILL delivery to a disposable child only. Footprint and target identity
    // are injected fixtures; no large allocation or actual SceneKit process is used.
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["10"]
    try! child.run()
    defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
    let identity = checkedProcess(child.processIdentifier)!
    let fixture = Reading(pid: child.processIdentifier, birth: identity.reading.birth,
                          name: SceneKitProtection.name, bytes: SceneKitProtection.limit,
                          executablePath: SceneKitProtection.path)
    precondition(!processHasExited(fixture))
    let result = SceneKitProtection().enforce([fixture], now: 0, enabled: true,
        probe: { pid in
            guard let current = checkedProcess(pid), current.reading.birth == identity.reading.birth else { return nil }
            return CheckedProcess(reading: fixture, owner: current.owner)
        })
    precondition(result.count == 1 && result[0].error == nil)
    child.waitUntilExit()
    precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
    precondition(processHasExited(fixture))
    print("PASS: SceneKit 4 GiB boundary, identity/owner recheck, disabled state, cooldown, restart, failure, real child SIGKILL and exit confirmation")
}

func selfTest() {
    func r(_ gib: Double, _ birth: UInt64 = 1) -> Reading {
        Reading(pid: 42, birth: birth, name: "test", bytes: UInt64(gib * GiB))
    }
    let d = Detector()
    precondition(d.update([r(2.5)], now: 0).isEmpty)
    precondition(d.update([r(2.5)], now: 5).first?.level == 2)
    precondition(d.hasProblem)
    precondition(d.update([r(2.6)], now: 10).isEmpty)
    precondition(d.hasProblem) // Icon remains red during notification cooldown.
    precondition(d.update([r(16)], now: 15).first?.level == 3)
    precondition(d.update([r(16)], now: 20).isEmpty)
    precondition(d.update([r(16)], now: 315).count == 1)
    precondition(d.update([r(2.5, 2)], now: 320).isEmpty)
    _ = d.update([], now: 325); precondition(d.tracks.isEmpty)
    precondition(!d.hasProblem)
    let growth = Detector()
    _ = growth.update([r(0.9)], now: 0)
    precondition(growth.update([r(1.5)], now: 30).first?.level == 1)
    let stale = Detector()
    _ = stale.update([r(0.9)], now: 0)
    precondition(stale.update([r(1.8)], now: 65).isEmpty)
    let noise = Detector()
    _ = noise.update([r(0.1)], now: 0)
    precondition(noise.update([r(0.8)], now: 30).isEmpty)
    let transient = Detector()
    _ = transient.update([r(2.1)], now: 0)
    precondition(transient.update([r(1.9)], now: 5).isEmpty)
    precondition(transient.update([r(2.1)], now: 10).isEmpty)
    print("PASS: threshold, escalation, cooldown, PID reuse, exit, growth, stale window, noise, transient spike")
    protectionSelfTest()
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if CommandLine.arguments.contains("--test-notification") {
    // Diagnostic CLI: verify the real notification pipeline without allocating memory.
    let center = UNUserNotificationCenter.current()
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        fputs("Notification verification timed out\n", stderr); exit(2)
    }
    center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized else {
            print("Notification permission is not authorized"); exit(2)
        }
        let content = UNMutableNotificationContent()
        content.title = "进程内存提醒 · 测试"
        content.body = "提醒功能已启用。顶栏现在只保留小图标，检测到异常时变红。"
        content.sound = .default
        let id = "memory-watch-test"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error = error { print(error.localizedDescription); exit(2) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                center.getDeliveredNotifications { notifications in
                    let delivered = notifications.contains { $0.request.identifier == id }
                    print("authorized=true delivered=\(delivered)")
                    exit(delivered ? 0 : 2)
                }
            }
        }
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--snapshot") {
    let result = snapshot()
    print("readable=\(result.items.count) unavailable=\(result.skipped)")
    for item in result.items.prefix(15) { print(String(format: "%d %.3f GiB %@", item.pid, item.gib, item.name)) }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
