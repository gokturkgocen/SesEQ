import Foundation

/// Outcome of an AppleScript run. Distinguishes between "no data" (success but empty
/// because e.g. the app isn't playing) and "permission/error" so the caller can decide
/// whether to surface a user-visible diagnostic.
enum AppleScriptResult {
    case success(String)
    case permissionDenied
    case appNotRunning
    case otherError(Int, String)
}

/// Thin wrapper for running short AppleScript snippets and parsing string returns.
/// AppleScript blocks the main thread, so we run on a dedicated background queue
/// and bridge back via async.
enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "com.gokturkgocen.SesEQ.applescript", qos: .userInitiated)

    /// Returns just the string output, or nil on any failure. Use `run(_:)` for diagnostics.
    static func runString(_ source: String) async -> String? {
        if case .success(let s) = await run(source) { return s.isEmpty ? nil : s }
        return nil
    }

    /// Returns a categorized result for diagnostics.
    static func run(_ source: String) async -> AppleScriptResult {
        await withCheckedContinuation { (cont: CheckedContinuation<AppleScriptResult, Never>) in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(returning: .otherError(-1, "NSAppleScript init failed")); return
                }
                var errorDict: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorDict)
                if let err = errorDict {
                    let code = (err[NSAppleScript.errorNumber] as? Int) ?? -1
                    let msg  = (err[NSAppleScript.errorMessage] as? String) ?? ""
                    // -1743: User didn't grant automation permission (TCC denied)
                    // -1728: Object not found / app not running
                    if code == -1743 {
                        cont.resume(returning: .permissionDenied); return
                    }
                    if code == -1728 || msg.lowercased().contains("isn't running") {
                        cont.resume(returning: .appNotRunning); return
                    }
                    cont.resume(returning: .otherError(code, msg)); return
                }
                cont.resume(returning: .success(descriptor.stringValue ?? ""))
            }
        }
    }
}
