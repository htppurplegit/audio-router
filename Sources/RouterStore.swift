import AppKit
import CoreAudio
import Foundation
import ServiceManagement

/// Keeps the list of apps/devices up to date, remembers which app goes where,
/// and keeps the live routes in sync with that.
@MainActor
final class RouterStore: ObservableObject {
    struct AppEntry: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
        var processObjects: Set<AudioObjectID>
        var isPlaying: Bool
        var isBackgroundProcess = false
        var isRunning: Bool { !processObjects.isEmpty }
    }

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var devices: [OutputDevice] = []
    /// bundleID -> output device UID. Saved between launches.
    @Published private(set) var assignments: [String: String] = [:]
    /// bundleID -> last error, shown under the app's row.
    @Published private(set) var errors: [String: String] = [:]
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    private var routes: [String: AppAudioRouter] = [:]
    private var timer: Timer?
    private static let defaultsKey = "assignments"

    init() {
        assignments = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        refresh()
        listen(kAudioHardwarePropertyProcessObjectList)
        listen(kAudioHardwarePropertyDevices)
        // Cheap poll so the "playing" dots and new helper processes stay current.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Public

    func device(for bundleID: String) -> String? { assignments[bundleID] }

    func setDevice(_ uid: String?, for bundleID: String) {
        assignments[bundleID] = uid
        UserDefaults.standard.set(assignments, forKey: Self.defaultsKey)
        errors[bundleID] = nil
        refresh()
    }

    func deviceName(uid: String) -> String {
        devices.first { $0.uid == uid }?.name ?? "Disconnected device"
    }

    func refresh() {
        devices = CA.outputDevices()
        apps = buildApps()
        reconcile()
    }

    // MARK: Private

    private func listen(_ selector: AudioObjectPropertySelector) {
        var addr = CA.address(selector)
        AudioObjectAddPropertyListenerBlock(kSystemObject, &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Groups Core Audio processes under the visible app that owns them
    /// (e.g. Chrome's helper processes count as Chrome).
    private func buildApps() -> [AppEntry] {
        let regularApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var byBundle: [String: AppEntry] = [:]

        for p in CA.audioProcesses() where p.pid != myPID {
            var owner = NSRunningApplication(processIdentifier: p.pid)
            if owner?.activationPolicy != .regular {
                // Helper with a matching bundle ID (e.g. com.google.Chrome.helper)...
                owner = p.bundleID.flatMap { bid in
                    regularApps.first { bid.hasPrefix($0.bundleIdentifier! + ".") }
                }
                // ...or the app macOS holds responsible for it (what Activity Monitor uses)...
                if owner == nil { owner = Self.responsibleApp(of: p.pid) }
                // ...or a parent process of the app (e.g. Firefox's plugin-container).
                if owner == nil { owner = Self.regularAncestor(of: p.pid) }
            }

            let bid: String
            if let owner, let ownerID = owner.bundleIdentifier {
                bid = ownerID
                if byBundle[bid] == nil {
                    byBundle[bid] = AppEntry(bundleID: bid,
                                             name: owner.localizedName ?? bid,
                                             icon: owner.icon,
                                             processObjects: [],
                                             isPlaying: false)
                }
            } else {
                // Couldn't tie it to an app: still show it (while it makes sound, or if saved)
                // under its own name rather than hiding it.
                let name = Self.processName(p.pid)
                bid = p.bundleID ?? "process:" + name
                guard p.isPlaying || assignments[bid] != nil || byBundle[bid] != nil else { continue }
                if byBundle[bid] == nil {
                    byBundle[bid] = AppEntry(bundleID: bid,
                                             name: name,
                                             icon: NSRunningApplication(processIdentifier: p.pid)?.icon,
                                             processObjects: [],
                                             isPlaying: false,
                                             isBackgroundProcess: true)
                }
            }
            byBundle[bid]!.processObjects.insert(p.object)
            byBundle[bid]!.isPlaying = byBundle[bid]!.isPlaying || p.isPlaying
        }

        // Keep saved apps visible even when they're closed, so the choice can be changed.
        for bid in assignments.keys where byBundle[bid] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
            let name = url.map { FileManager.default.displayName(atPath: $0.path) }
                ?? bid.replacingOccurrences(of: "process:", with: "")
            byBundle[bid] = AppEntry(bundleID: bid,
                                     name: name.replacingOccurrences(of: ".app", with: ""),
                                     icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                                     processObjects: [],
                                     isPlaying: false)
        }

        return byBundle.values.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private typealias ResponsiblePIDFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsiblePIDFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsiblePIDFn.self)
    }()

    private static func responsibleApp(of pid: pid_t) -> NSRunningApplication? {
        guard let fn = responsiblePID else { return nil }
        let r = fn(pid)
        guard r > 0, r != pid,
              let app = NSRunningApplication(processIdentifier: r),
              app.activationPolicy == .regular else { return nil }
        return app
    }

    private static func processName(_ pid: pid_t) -> String {
        if let n = NSRunningApplication(processIdentifier: pid)?.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let n = String(cString: buf)
        return n.isEmpty ? "PID \(pid)" : n
    }

    /// Walks up the parent-process chain to the first normal (Dock) app.
    private static func regularAncestor(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<6 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                return app
            }
            current = parent
        }
        return nil
    }

    /// Makes live routes match the saved choices: creates, rebuilds or removes them.
    private func reconcile() {
        let presentDevices = Set(devices.map(\.uid))
        var wanted: [String: (uid: String, procs: Set<AudioObjectID>)] = [:]
        for app in apps where app.isRunning {
            if let uid = assignments[app.bundleID], presentDevices.contains(uid) {
                wanted[app.bundleID] = (uid, app.processObjects)
            }
        }

        for (bid, route) in routes {
            let w = wanted[bid]
            if w == nil || w!.uid != route.deviceUID || w!.procs != route.processObjects {
                route.stop()
                routes[bid] = nil
            }
        }

        for (bid, w) in wanted where routes[bid] == nil {
            do {
                routes[bid] = try AppAudioRouter(bundleID: bid, processObjects: w.procs, deviceUID: w.uid)
                errors[bid] = nil
            } catch {
                errors[bid] = error.localizedDescription
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login: \(error)")
        }
    }

    func stopAll() {
        routes.values.forEach { $0.stop() }
        routes.removeAll()
    }
}
