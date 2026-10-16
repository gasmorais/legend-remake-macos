import AppKit
import Foundation
import IOKit.ps

enum Server {
    static let api = URL(string: "https://servidor.legendremake.com/launcher/api/")!
    static let game = URL(string: "http://servidor.legendremake.com/")!
    static let recharge = URL(string: "https://legendremake.com/recarga")!
    static let site = URL(string: "https://legendremake.com")!
}

struct Paths {
    let support: URL
    let logs: URL
    let cache: URL
    let legacyCache: URL
    let engineRoot: URL
    let engineDescriptor: URL
    let adl: URL
    let accounts: URL

    static let shared = Paths()

    private init() {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        support = library.appending(path: "Application Support/Legend Remake", directoryHint: .isDirectory)
        logs = library.appending(path: "Logs/Legend Remake", directoryHint: .isDirectory)
        cache = library.appending(path: "Caches/com.legendremake.mac/Arquivos", directoryHint: .isDirectory)
        legacyCache = library.appending(path: "Caches/com.legendremake.mac/Recursos", directoryHint: .isDirectory)
        let resources = Bundle.main.resourceURL!
        engineRoot = resources.appending(path: "engine", directoryHint: .isDirectory)
        engineDescriptor = engineRoot.appending(path: "application.xml")
        adl = resources.appending(path: "AIRSDK/bin/adl")
        accounts = support.appending(path: "accounts.json")
        for dir in [support, logs, cache] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let commit = Bundle.main.object(forInfoDictionaryKey: "LRCommit") as? String ?? "dev"
    static let fullVersion = "\(version) (\(commit))"
    static let gameVersion = Bundle.main.object(forInfoDictionaryKey: "LRGameVersion") as? String ?? version
    static let userAgent = "LegendOnline/\(gameVersion) (macOS; launcher)"
}

final class LogFile: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(_ url: URL, limit: UInt64 = 2 << 20) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > limit {
            try? fm.removeItem(at: url.appendingPathExtension("old"))
            try? fm.moveItem(at: url, to: url.appendingPathExtension("old"))
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ message: String) {
        let line = "\(Self.stamp.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}

let launcherLog = LogFile(Paths.shared.logs.appending(path: "launcher.log"))

func log(_ message: String) {
    launcherLog.write(message)
}

enum PowerSource {
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

enum WindowVisibility {
    static func onscreenProcesses() -> Set<pid_t> {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result = Set<pid_t>()
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 200, height > 200
            else { continue }
            result.insert(pid)
        }
        return result
    }
}

extension NSRunningApplication {
    @MainActor
    func bringToFront() {
        NSApp.yieldActivation(to: self)
        activate(options: [.activateAllWindows])
    }
}

enum Formatting {
    private static let locale = Locale(identifier: "pt_BR")

    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start)) / 60)
        if minutes < 1 { return "menos de 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", rest)) min"
    }

    static func playTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        if hours >= 1 { return "\(hours.formatted(.number.locale(locale))) h de jogo" }
        return "\(max(1, seconds / 60)) min de jogo"
    }

    static func lastAccess(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        if calendar.isDateInToday(date) { return "hoje às \(time)" }
        if calendar.isDateInYesterday(date) { return "ontem às \(time)" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        let style = Date.FormatStyle(locale: locale).day(.twoDigits).month(.twoDigits)
        let day = date.formatted(sameYear ? style : style.year(.defaultDigits))
        return "\(day) às \(time)"
    }
}

enum Quarantine {
    private static let attribute = "com.apple.quarantine"

    static func clearBundle() {
        let root = Bundle.main.bundleURL
        guard getxattr(Paths.shared.adl.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return }
        removexattr(root.path, attribute, XATTR_NOFOLLOW)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            removexattr(url.path, attribute, XATTR_NOFOLLOW)
        }
        log("[launcher] quarentena removida dos arquivos do app")
    }
}
