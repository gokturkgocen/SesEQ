import AppKit
import CoreAudio
import Darwin
import Foundation

/// Inspects Core Audio's process object list to determine which user-facing apps
/// are currently producing audio output. Used by AutoPresetSelector to decide
/// which Now-Playing provider (Spotify / Music / browser) to query.
enum AudioSourceMonitor {

    /// Returns the bundle identifier of an app currently producing audio output,
    /// preferring known media apps (Spotify, Music, browsers) over background noise
    /// (notification sounds, system effects, our own process).
    static func currentSourceBundleID() -> String? {
        let pids = activeAudioOutputPIDs()
        guard !pids.isEmpty else { return nil }

        let myPID = ProcessInfo.processInfo.processIdentifier
        var candidates: [(bundle: String, priority: Int)] = []

        for pid in pids where pid != myPID {
            // Chrome / Safari / Spotify route audio through helper/renderer sub-processes
            // whose own bundle id is "*.helper" or nil. Walk up the parent chain until
            // we find an ancestor that NSRunningApplication recognises as a user-facing app.
            guard let bundle = resolveUserFacingBundleID(startingAt: pid) else { continue }
            candidates.append((bundle, priority(for: bundle)))
        }

        candidates.sort { ($0.priority, $1.bundle) > ($1.priority, $0.bundle) }
        return candidates.first?.bundle
    }

    /// Returns the names of all currently-audio-producing apps for diagnostics.
    static func diagnosticReport() -> [String] {
        let pids = activeAudioOutputPIDs()
        if pids.isEmpty { return ["(hiç ses kaynağı bulunamadı — Core Audio process listesi boş)"] }
        var lines: [String] = []
        for pid in pids {
            var info = "PID \(pid)"
            if let app = NSRunningApplication(processIdentifier: pid) {
                info += " — \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "no bundle"))"
            }
            if let resolved = resolveUserFacingBundleID(startingAt: pid), resolved != NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                info += " → ancestor: \(resolved)"
            }
            lines.append(info)
        }
        return lines
    }

    /// Walks up the parent process chain looking for the first ancestor that
    /// `NSRunningApplication` recognises (i.e. has a `bundleIdentifier`).
    /// Caps the search at 6 hops to avoid edge-case loops.
    private static func resolveUserFacingBundleID(startingAt pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: current),
               let bundle = app.bundleIdentifier,
               // Helpers often have a bundle id but no activation policy → skip them.
               app.activationPolicy != .prohibited {
                return bundle
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// POSIX sysctl call to fetch the parent PID of an arbitrary process.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(ptr.baseAddress, UInt32(ptr.count), &info, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Process priority. Higher = more likely the user is intentionally listening.
    /// Negative priorities are filtered out (system sounds, our own helpers).
    private static func priority(for bundle: String) -> Int {
        switch bundle {
        case "com.spotify.client":                     return 100
        case "com.apple.Music":                        return 95
        case "com.google.Chrome",
             "company.thebrowser.Browser",        // Arc
             "com.brave.Browser",
             "com.microsoft.edgemac":                  return 80
        case "com.apple.Safari":                       return 75
        case "org.mozilla.firefox":                    return 70
        case "us.zoom.xos",
             "com.microsoft.teams",
             "com.tinyspeck.slackmacgap",
             "com.apple.FaceTime",
             "com.hnc.Discord",
             "net.whatsapp.WhatsApp":                  return 60
        case "org.videolan.vlc",
             "io.mpv",
             "com.apple.QuickTimePlayerX",
             "com.netflix.Netflix":                    return 50
        case "com.apple.coreaudiod",
             "com.apple.systemuiserver",
             "com.apple.notificationcenterui":         return -1
        default:                                       return 10  // unknown but plausible
        }
    }

    /// Queries Core Audio for processes producing OUTPUT audio right now.
    private static func activeAudioOutputPIDs() -> [pid_t] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects
        ) == noErr else { return [] }

        var pids: [pid_t] = []
        for object in objects {
            guard isRunningOutput(object) else { continue }
            if let pid = pid(for: object) {
                pids.append(pid)
            }
        }
        return pids
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private static func pid(for object: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }
}
