import AppKit
import UserNotifications
import Darwin

let GiB = Double(1 << 30)
let appID = "local.shuangsu.memory-watch"
let appVersion = "1.2.0"
let supportURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Memory Watch", isDirectory: true)

struct Reading {
    let pid: Int32
    let birth: UInt64
    let name: String
    let bytes: UInt64
    var executablePath: String = ""
    var residentBytes: UInt64? = nil
    var virtualBytes: UInt64? = nil
    var gib: Double { Double(bytes) / GiB }
    var key: String { "\(pid):\(birth)" }
}

struct Thresholds {
    let ramGiB: Double
    init(ramGiB: Double = Double(ProcessInfo.processInfo.physicalMemory) / GiB) { self.ramGiB = ramGiB }
    var limit: Double { min(20, max(4, 4 + (ramGiB - 16) * 16 / 496)) }
    var virtualGrowth: Double { min(80, max(8, 8 + (ramGiB - 16) * 72 / 496)) }
    var limitBytes: UInt64 { UInt64(ceil(limit * GiB)) }
}

func gibText(_ bytes: UInt64?) -> String {
    bytes.map { String(format: "%.2f GiB", Double($0) / GiB) } ?? "不可用"
}

func migratedProtectionPreference(_ defaults: UserDefaults = .standard) -> Bool {
    if defaults.object(forKey: "autoExitPreview") == nil {
        let enabled = defaults.object(forKey: "autoExitSceneKit") == nil ? true : defaults.bool(forKey: "autoExitSceneKit")
        defaults.set(enabled, forKey: "autoExitPreview")
    }
    return defaults.bool(forKey: "autoExitPreview")
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
    var task = proc_taskinfo()
    let taskSize = MemoryLayout<proc_taskinfo>.size
    let taskCount = withUnsafeMutablePointer(to: &task) {
        proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(taskSize))
    }
    // Bind the extra metrics to the same process instance, even if a PID was reused during sampling.
    guard let after = readUsage(pid), after.ri_proc_start_abstime == usage.ri_proc_start_abstime else { return nil }
    return Reading(pid: pid, birth: usage.ri_proc_start_abstime, name: name,
                   bytes: after.ri_phys_footprint, executablePath: executable,
                   residentBytes: after.ri_resident_size,
                   virtualBytes: taskCount == Int32(taskSize) ? task.pti_virtual_size : nil)
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
    let threshold: UInt64
    let error: Int32?
}

final class PreviewProtection {
    static let name = "SceneKitQLThumbnailExtension"
    static let path = "/System/Library/Frameworks/SceneKit.framework/PlugIns/SceneKitQLThumbnailExtension.appex/Contents/MacOS/SceneKitQLThumbnailExtension"
    static let paths: [String: String] = [
        name: path,
        "SceneKitQLPreviewExtension": "/System/Library/Frameworks/SceneKit.framework/PlugIns/SceneKitQLPreviewExtension.appex/Contents/MacOS/SceneKitQLPreviewExtension",
        "HydraQLThumbnailExtension": "/System/Library/PrivateFrameworks/Hydra.framework/Plugins/HydraQLThumbnailExtension.appex/Contents/MacOS/HydraQLThumbnailExtension",
        "HydraQLPreviewExtension": "/System/Library/PrivateFrameworks/Hydra.framework/Plugins/HydraQLPreviewExtension.appex/Contents/MacOS/HydraQLPreviewExtension",
        "HydraRenderingService": "/System/Library/PrivateFrameworks/Hydra.framework/Versions/C/XPCServices/HydraRenderingService.xpc/Contents/MacOS/HydraRenderingService"
    ]
    let limit: UInt64
    init(limit: UInt64 = Thresholds().limitBytes) { self.limit = limit }
    private var attempts: [String: Double] = [:]

    static func isPreview(_ reading: Reading) -> Bool {
        reading.pid > 1 && reading.pid != getpid() && paths[reading.name] == reading.executablePath
    }
    private func matches(_ reading: Reading) -> Bool {
        Self.isPreview(reading) && reading.bytes >= limit
    }

    func enforce(_ items: [Reading], now: Double, enabled: Bool,
                 probe: (Int32) -> CheckedProcess? = checkedProcess,
                 signal: (Int32, Int32) -> Int32 = Darwin.kill) -> [AutoExitAttempt] {
        let live = Set(items.map { $0.key })
        attempts = attempts.filter { live.contains($0.key) || now - $0.value < 60 }
        guard enabled else { return [] }
        var results: [AutoExitAttempt] = []
        for candidate in items where matches(candidate) {
            guard now - (attempts[candidate.key] ?? -.infinity) >= 60 else { continue }
            // Re-read identity, ownership and footprint immediately before the signal.
            guard let current = probe(candidate.pid), current.owner == getuid(),
                  current.reading.pid == candidate.pid, current.reading.birth == candidate.birth,
                  current.reading.executablePath == candidate.executablePath,
                  matches(current.reading) else { continue }
            attempts[candidate.key] = now
            let result = signal(current.reading.pid, SIGKILL)
            results.append(AutoExitAttempt(reading: current.reading, threshold: limit, error: result == 0 ? nil : errno))
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
                level = 3; reason = String(format: "内存足迹达到严重阈值 %.2f GiB，请检查活动监视器。", critical)
            } else if track.highSamples >= 2 {
                level = 2; reason = String(format: "内存足迹连续两次达到 %.2f GiB。", warn)
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

struct VirtualTrack {
    var baseline: UInt64?
    var lastAlert = -Double.infinity
}

final class VirtualDetector {
    let threshold: Double
    var tracks: [String: VirtualTrack] = [:]
    var hasProblem = false
    init(threshold: Double = Thresholds().virtualGrowth) { self.threshold = threshold }
    func reset() { tracks.removeAll(); hasProblem = false }
    func update(_ items: [Reading], now: Double) -> [Alert] {
        hasProblem = false
        var next: [String: VirtualTrack] = [:]
        var alerts: [Alert] = []
        for item in items where PreviewProtection.isPreview(item) {
            var track = tracks[item.key] ?? VirtualTrack()
            if let value = item.virtualBytes {
                if track.baseline == nil { track.baseline = value }
                let baseline = track.baseline!
                let growth = value >= baseline ? Double(value - baseline) / GiB : 0
                if growth >= threshold {
                    hasProblem = true
                    if now - track.lastAlert >= 300 {
                        let reason = String(format: "虚拟空间较首次采样增长 %.2f GiB（提醒线 %.2f GiB）；仅提醒，地址保留不等于 RAM 或 Swap。", growth, threshold)
                        alerts.append(Alert(reading: item, level: 1, reason: reason))
                        track.lastAlert = now
                    }
                }
            }
            next[item.key] = track
        }
        tracks = next
        return alerts
    }
}

struct SystemReading {
    var swapBytes: UInt64?
    var pressure: UInt32?
    var pressureText: String {
        switch pressure {
        case 1: return "正常"
        case 2: return "警告"
        case 4: return "严重"
        default: return "不可用"
        }
    }
}

func systemSnapshot() -> SystemReading {
    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 && swapSize == MemoryLayout<xsw_usage>.size
    var pressure: UInt32 = 0
    var pressureSize = MemoryLayout<UInt32>.size
    let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 && pressureSize == MemoryLayout<UInt32>.size
    return SystemReading(swapBytes: swapOK ? swap.xsu_used : nil, pressure: pressureOK ? pressure : nil)
}

final class SystemDetector {
    var history: [(Double, UInt64)] = []
    var abnormalSamples = 0
    var lastPressureAlert = -Double.infinity
    var lastPressureLevel = 0
    var lastSwapAlert = -Double.infinity
    var swapGrowth: Double? = nil
    var hasProblem = false
    func update(_ reading: SystemReading, now: Double) -> String? {
        if let previous = history.last, now - previous.0 > 60 { history.removeAll() }
        while history.count > 1 && history[1].0 <= now - 60 { history.removeFirst() }
        swapGrowth = nil
        if let swap = reading.swapBytes {
            history.append((now, swap))
            if let first = history.first, now - first.0 >= 60 {
                swapGrowth = max(0, (Double(swap) - Double(first.1)) / GiB)
            }
        } else { history.removeAll() }
        let abnormal = reading.pressure == 2 || reading.pressure == 4
        abnormalSamples = abnormal ? abnormalSamples + 1 : 0
        let pressureProblem = abnormalSamples >= 2
        let swapProblem = (swapGrowth ?? 0) >= 1
        let pressureLevel = reading.pressure == 4 ? 3 : 2
        hasProblem = pressureProblem || swapProblem
        var reasons: [String] = []
        if pressureProblem && (now - lastPressureAlert >= 300 || pressureLevel > lastPressureLevel) {
            reasons.append("内存压力连续两轮\(reading.pressureText)")
            lastPressureAlert = now; lastPressureLevel = pressureLevel
        }
        if swapProblem && now - lastSwapAlert >= 300 {
            reasons.append(String(format: "约 60 秒窗口内 Swap 净增 %.2f GiB", swapGrowth!))
            lastSwapAlert = now
        }
        guard !reasons.isEmpty else { return nil }
        return "系统内存：\(reasons.joined(separator: "；"))。Swap 当前 \(gibText(reading.swapBytes))；系统数据不能归因到单个进程。"
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
    let thresholds = Thresholds()
    let detector = Detector()
    let previewProtection = PreviewProtection()
    let virtualDetector = VirtualDetector()
    var systemDetector = SystemDetector()
    var systemReading = SystemReading()
    let worker = DispatchQueue(label: "memory-watch.sampling", qos: .utility)
    var busy = false
    var paused = false
    var samplingEpoch = 0
    var readings: [Reading] = []
    var skipped = 0
    var sampled = false
    var latest = "尚无告警"
    var notificationState = "正在检查通知权限…"
    var relaxed = UserDefaults.standard.bool(forKey: "relaxed")
    var autoExitPreview = migratedProtectionPreference()
    var agentURL: URL { FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(appID).plist") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(problem: false)
        status.button?.imagePosition = .imageOnly
        status.button?.title = ""
        status.button?.setAccessibilityLabel("内存提醒")
        status.button?.setAccessibilityIdentifier("\(appID).status")
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, error in
            DispatchQueue.main.async {
                self.notificationState = allowed ? "通知已允许" : "通知未允许：点击打开设置"
                logEvent("notificationAuthorization allowed=\(allowed) error=\(error?.localizedDescription ?? "none")")
            }
        }
        logEvent("started version=\(appVersion) interval=5s ramGiB=\(thresholds.ramGiB) previewAutoExit=\(autoExitPreview) thresholdGiB=\(thresholds.limit) virtualGrowthGiB=\(thresholds.virtualGrowth) otherProcessesAlertsOnly=true")
        applyThresholds()
        tick()
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening a menu-bar app should expose its controls even if its icon is hidden by other extras.
        status.button?.performClick(nil)
        return true
    }

    func tick() {
        guard !busy && !paused else { return }
        busy = true
        let epoch = samplingEpoch
        worker.async {
            let result = snapshot()
            let system = systemSnapshot()
            DispatchQueue.main.async {
                self.busy = false
                guard !self.paused && epoch == self.samplingEpoch else { return }
                self.readings = result.items; self.skipped = result.skipped
                self.systemReading = system
                if !self.sampled {
                    logEvent("firstSample readable=\(result.items.count) unavailable=\(result.skipped)")
                    self.sampled = true
                }
                let now = ProcessInfo.processInfo.systemUptime
                let actions = self.previewProtection.enforce(result.items, now: now, enabled: self.autoExitPreview)
                let handled = Set(actions.map { $0.reading.key })
                let alerts = (self.detector.update(result.items, now: now)
                    + self.virtualDetector.update(result.items, now: now)).filter { !handled.contains($0.reading.key) }
                let systemAlert = self.systemDetector.update(system, now: now)
                self.setStatusIcon(problem: result.items.isEmpty || self.detector.hasProblem || self.virtualDetector.hasProblem || self.systemDetector.hasProblem || !actions.isEmpty)
                if let highest = result.items.first {
                    self.status.button?.toolTip = String(format: "最高内存足迹：%@ · %.2f GiB\nSwap %@ · 内存压力 %@", highest.name, highest.gib, gibText(system.swapBytes), system.pressureText)
                } else {
                    self.status.button?.toolTip = "未能读取进程；下一轮会重试。\nSwap \(gibText(system.swapBytes)) · 压力\(system.pressureText)"
                }
                if !alerts.isEmpty || systemAlert != nil {
                    for alert in alerts { logEvent("ALERT level=\(alert.level) \(alert.text)") }
                    if let systemAlert { logEvent("SYSTEM_ALERT \(systemAlert)") }
                    let messages = alerts.map { $0.text } + (systemAlert.map { [$0] } ?? [])
                    self.latest = messages[0]
                    var text = messages.prefix(2).joined(separator: "\n")
                    if messages.count > 2 { text += "\n另有 \(messages.count - 2) 项，详情见日志。" }
                    self.sendNotification(text)
                }
                self.reportAutoExits(actions)
            }
        }
    }

    func reportAutoExits(_ actions: [AutoExitAttempt]) {
        guard !actions.isEmpty else { return }
        for action in actions {
            logEvent("AUTO_EXIT_ATTEMPT name=\(action.reading.name) pid=\(action.reading.pid) birth=\(action.reading.birth) footprintGiB=\(action.reading.gib) rss=\(gibText(action.reading.residentBytes)) vsz=\(gibText(action.reading.virtualBytes)) thresholdGiB=\(Double(action.threshold) / GiB) reason=footprint signal=SIGKILL errno=\(action.error ?? 0)")
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
                    ? String(format: "已自动强制退出：%@（内存足迹阈值 %.2f GiB）", detail, Double(action.threshold) / GiB)
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
            row.toolTip = "内存足迹 \(gibText(reading.bytes)) · RSS \(gibText(reading.residentBytes)) · 虚拟空间 \(gibText(reading.virtualBytes))。点击打开活动监视器。"
        }
        menu.addItem(.separator())
        _ = item(menu, "最近告警：\(latest.replacingOccurrences(of: "\n", with: " · "))")
        _ = item(menu, String(format: "内存足迹告警 %.2f / %.2f GiB · 60 秒增长 512 MiB", detector.warn, detector.critical))
        _ = item(menu, String(format: "三维预览虚拟空间增长提醒 ≥ %.2f GiB", thresholds.virtualGrowth))
        let swapDelta = systemDetector.swapGrowth.map { String(format: "%+.2f GiB", $0) } ?? "不可用"
        _ = item(menu, "Swap \(gibText(systemReading.swapBytes)) · 约 60 秒净增 \(swapDelta) · 压力\(systemReading.pressureText)")
        let mode = item(menu, "宽松告警阈值（自适应值 ×2）", #selector(toggleRelaxed)); mode.state = relaxed ? .on : .off
        let protection = item(menu, String(format: "自动退出过大三维预览组件（≥%.2f GiB）", thresholds.limit), #selector(togglePreviewProtection))
        protection.state = autoExitPreview ? .on : .off
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

    func applyThresholds() {
        detector.warn = thresholds.limit / 2 * (relaxed ? 2 : 1)
        detector.critical = thresholds.limit * (relaxed ? 2 : 1)
    }
    @objc func togglePreviewProtection() {
        autoExitPreview.toggle()
        UserDefaults.standard.set(autoExitPreview, forKey: "autoExitPreview")
        logEvent("previewAutoExit=\(autoExitPreview) thresholdGiB=\(thresholds.limit)")
        if autoExitPreview { tick() }
    }
    @objc func toggleRelaxed() {
        relaxed.toggle(); UserDefaults.standard.set(relaxed, forKey: "relaxed")
        detector.tracks.removeAll(); applyThresholds(); tick()
    }
    @objc func togglePause() {
        paused.toggle(); detector.tracks.removeAll()
        samplingEpoch += 1
        virtualDetector.reset(); systemDetector = SystemDetector()
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
    let limit: UInt64 = 4 * (1 << 30)
    func target(_ bytes: UInt64 = 4 * (1 << 30), birth: UInt64 = 1) -> Reading {
        Reading(pid: 42, birth: birth, name: PreviewProtection.name, bytes: bytes,
                executablePath: PreviewProtection.path)
    }
    let candidate = target()
    var signals = 0
    let signal: (Int32, Int32) -> Int32 = { pid, value in
        precondition(pid == 42 && value == SIGKILL); signals += 1; return 0
    }
    let probe: (Int32) -> CheckedProcess? = { _ in CheckedProcess(reading: candidate, owner: getuid()) }
    let guardrail = PreviewProtection(limit: limit)
    precondition(guardrail.enforce([target(4 * (1 << 30) - 1)], now: 0, enabled: true, probe: probe, signal: signal).isEmpty)
    precondition(guardrail.enforce([candidate], now: 0, enabled: false, probe: probe, signal: signal).isEmpty)
    precondition(signals == 0)
    precondition(guardrail.enforce([candidate], now: 0, enabled: true, probe: probe, signal: signal).count == 1)
    precondition(signals == 1)
    precondition(guardrail.enforce([candidate], now: 5, enabled: true, probe: probe, signal: signal).isEmpty)
    precondition(guardrail.enforce([], now: 10, enabled: true, probe: probe, signal: signal).isEmpty)
    precondition(guardrail.enforce([candidate], now: 15, enabled: true, probe: probe, signal: signal).isEmpty)
    precondition(guardrail.enforce([candidate], now: 60, enabled: true, probe: probe, signal: signal).count == 1)
    precondition(signals == 2)

    let wrongPath = Reading(pid: 42, birth: 1, name: PreviewProtection.name,
                            bytes: 4 * (1 << 30), executablePath: "/tmp/SceneKitQLThumbnailExtension")
    let preview = Reading(pid: 42, birth: 1, name: "SceneKitQLPreviewExtension",
                          bytes: 16 * (1 << 30), executablePath: PreviewProtection.path)
    let other = Reading(pid: 42, birth: 1, name: "WeChat", bytes: 16 * (1 << 30))
    for item in [wrongPath, preview, other] {
        precondition(PreviewProtection(limit: limit).enforce([item], now: 0, enabled: true, probe: probe, signal: signal).isEmpty)
    }
    let changedPID = Reading(pid: 43, birth: 1, name: PreviewProtection.name,
                            bytes: 4 * (1 << 30), executablePath: PreviewProtection.path)
    let checks: [CheckedProcess?] = [nil,
        CheckedProcess(reading: target(birth: 2), owner: getuid()),
        CheckedProcess(reading: target(4 * (1 << 30) - 1), owner: getuid()),
        CheckedProcess(reading: candidate, owner: getuid() + 1),
        CheckedProcess(reading: wrongPath, owner: getuid()),
        CheckedProcess(reading: changedPID, owner: getuid())]
    for check in checks {
        precondition(PreviewProtection(limit: limit).enforce([candidate], now: 0, enabled: true,
                     probe: { _ in check }, signal: signal).isEmpty)
    }
    precondition(signals == 2)

    let failing = PreviewProtection(limit: limit)
    let denied: (Int32, Int32) -> Int32 = { _, _ in errno = EPERM; return -1 }
    precondition(failing.enforce([candidate], now: 0, enabled: true, probe: probe, signal: denied).first?.error == EPERM)
    precondition(failing.enforce([candidate], now: 5, enabled: true, probe: probe, signal: signal).isEmpty)
    let restarted = target(birth: 2)
    precondition(failing.enforce([restarted], now: 5, enabled: true,
                 probe: { _ in CheckedProcess(reading: restarted, owner: getuid()) }, signal: signal).count == 1)

    // Every allowed component is gated by footprint, never by VSZ.
    for (name, path) in PreviewProtection.paths {
        let item = Reading(pid: 42, birth: 1, name: name, bytes: limit,
                           executablePath: path, virtualBytes: UInt64(600 * GiB))
        let result = PreviewProtection(limit: limit).enforce([item], now: 0, enabled: true,
            probe: { _ in CheckedProcess(reading: item, owner: getuid()) }, signal: signal)
        precondition(result.count == 1 && result[0].threshold == limit)
        let low = Reading(pid: item.pid, birth: item.birth, name: item.name,
            bytes: limit - 1, executablePath: item.executablePath, virtualBytes: item.virtualBytes)
        precondition(PreviewProtection(limit: limit).enforce([low], now: 0, enabled: true,
            probe: { _ in CheckedProcess(reading: low, owner: getuid()) }, signal: signal).isEmpty)
    }

    // Real SIGKILL delivery to a disposable child only. Footprint and target identity
    // are injected fixtures; no large allocation or actual SceneKit process is used.
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["10"]
    try! child.run()
    defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
    let identity = checkedProcess(child.processIdentifier)!
    let fixture = Reading(pid: child.processIdentifier, birth: identity.reading.birth,
                          name: PreviewProtection.name, bytes: 4 * (1 << 30),
                          executablePath: PreviewProtection.path)
    precondition(!processHasExited(fixture))
    let result = PreviewProtection(limit: limit).enforce([fixture], now: 0, enabled: true,
        probe: { pid in
            guard let current = checkedProcess(pid), current.reading.birth == identity.reading.birth else { return nil }
            return CheckedProcess(reading: fixture, owner: current.owner)
        })
    precondition(result.count == 1 && result[0].error == nil)
    child.waitUntilExit()
    precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
    precondition(processHasExited(fixture))
    print("PASS: preview footprint boundary, identity/owner recheck, disabled state, cooldown, restart, failure, real child SIGKILL and exit confirmation")
}

func adaptiveSelfTest() {
    for (ram, limit, virtual) in [(8.0, 4.0, 8.0), (16, 4, 8), (64, 5.548387096774194, 14.967741935483872),
                                (128, 7.612903225806452, 24.258064516129032),
                                (256, 11.741935483870968, 42.83870967741935), (512, 20, 80), (1024, 20, 80)] {
        let policy = Thresholds(ramGiB: ram)
        precondition(abs(policy.limit - limit) < 0.000001)
        precondition(abs(policy.virtualGrowth - virtual) < 0.000001)
    }
    let suite = "memory-watch-self-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "autoExitSceneKit")
    precondition(!migratedProtectionPreference(defaults))
    defaults.set(true, forKey: "autoExitSceneKit")
    precondition(!migratedProtectionPreference(defaults)) // New preference wins after migration.
    defaults.removePersistentDomain(forName: suite)
    precondition(migratedProtectionPreference(defaults))

    func preview(_ vsz: Double?, birth: UInt64 = 1) -> Reading {
        Reading(pid: 42, birth: birth, name: "HydraRenderingService", bytes: UInt64(0.2 * GiB),
                executablePath: PreviewProtection.paths["HydraRenderingService"]!,
                virtualBytes: vsz.map { UInt64($0 * GiB) })
    }
    let virtual = VirtualDetector(threshold: 8)
    precondition(virtual.update([preview(nil)], now: 0).isEmpty)
    precondition(virtual.update([preview(492)], now: 5).isEmpty)
    precondition(virtual.update([preview(499.99)], now: 10).isEmpty)
    precondition(virtual.update([preview(500)], now: 15).count == 1)
    precondition(virtual.hasProblem)
    precondition(virtual.update([preview(501)], now: 20).isEmpty)
    precondition(virtual.update([preview(nil)], now: 25).isEmpty)
    precondition(virtual.update([preview(501)], now: 315).count == 1)
    precondition(virtual.update([preview(700, birth: 2)], now: 320).isEmpty)
    virtual.reset() // Pause/resume discards the old baseline.
    precondition(virtual.update([preview(800, birth: 2)], now: 325).isEmpty)
    _ = virtual.update([], now: 330); precondition(virtual.tracks.isEmpty)
    var fake = preview(1000); fake.executablePath = "/tmp/HydraRenderingService"
    precondition(virtual.update([fake], now: 335).isEmpty && virtual.tracks.isEmpty)

    let system = SystemDetector()
    precondition(system.update(SystemReading(swapBytes: UInt64(20 * GiB), pressure: 1), now: 0) == nil)
    precondition(system.update(SystemReading(swapBytes: UInt64(20.5 * GiB), pressure: 2), now: 5) == nil)
    precondition(system.update(SystemReading(swapBytes: UInt64(21 * GiB), pressure: 2), now: 10) != nil)
    precondition(system.update(SystemReading(swapBytes: UInt64(21 * GiB), pressure: 4), now: 15) != nil) // Escalation.
    precondition(system.update(SystemReading(swapBytes: UInt64(21 * GiB), pressure: 4), now: 20) == nil)
    precondition(system.update(SystemReading(), now: 25) == nil && !system.hasProblem && system.swapGrowth == nil)
    let gap = SystemDetector()
    _ = gap.update(SystemReading(swapBytes: 0, pressure: 1), now: 0)
    precondition(gap.update(SystemReading(swapBytes: UInt64(10 * GiB), pressure: 1), now: 100) == nil)
    let swapOnly = SystemDetector()
    _ = swapOnly.update(SystemReading(swapBytes: 0, pressure: 1), now: 0)
    precondition(swapOnly.update(SystemReading(swapBytes: UInt64(GiB), pressure: 1), now: 5) == nil)
    precondition(swapOnly.update(SystemReading(swapBytes: UInt64(GiB), pressure: 1), now: 60) != nil)
    let jitter = SystemDetector()
    for i in 0...12 {
        _ = jitter.update(SystemReading(swapBytes: UInt64(Double(i) / 12 * GiB), pressure: 1), now: Double(i) * 5.01)
    }
    precondition(jitter.hasProblem)
    print("PASS: independent linear RAM/VSZ interpolation, preference migration, virtual baseline/boundary/cooldown/PID reuse/pause, missing metrics, swap/pressure/escalation/window jitter")
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
    adaptiveSelfTest()
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
    let policy = Thresholds()
    let system = systemSnapshot()
    print("version=\(appVersion) readable=\(result.items.count) unavailable=\(result.skipped)")
    print(String(format: "ramGiB=%.2f warnGiB=%.2f criticalGiB=%.2f autoExitGiB=%.2f virtualGrowthGiB=%.2f", policy.ramGiB, policy.limit / 2, policy.limit, policy.limit, policy.virtualGrowth))
    print("swap=\(gibText(system.swapBytes)) pressure=\(system.pressureText)")
    let top = Array(result.items.prefix(15))
    let keys = Set(top.map { $0.key })
    for item in top + result.items.filter({ PreviewProtection.isPreview($0) && !keys.contains($0.key) }) {
        print("\(item.pid) \(item.name) footprint=\(gibText(item.bytes)) rss=\(gibText(item.residentBytes)) vsz=\(gibText(item.virtualBytes)) previewTarget=\(PreviewProtection.isPreview(item))")
    }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
