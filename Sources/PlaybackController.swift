import Foundation

/// Drives transport controls (previous / play-pause / next) on whichever supported
/// player is currently producing audio. Each source uses its own channel:
///   • Spotify / Apple Music   → AppleScript (`tell application id … to next track`)
///   • YouTube Music (browser) → JS click in the player bar (`YouTubeMusicService`)
///
/// Routing is by the current audio-source bundle (`AudioSourceMonitor`), the same
/// signal the preset selector uses — so a press always targets what you're hearing.
/// On an unsupported source the action is a silent no-op.
@available(macOS 14.2, *)
@MainActor
enum PlaybackController {

    enum Action { case previous, playPause, next }

    /// Browser bundle → YT Music browser kind, for routing browser audio to YT Music.
    private static let browsers: [String: YouTubeMusicService.BrowserKind] = [
        "com.google.Chrome":          .chrome,
        "company.thebrowser.Browser": .arc,
        "com.brave.Browser":          .brave,
        "com.microsoft.edgemac":      .edge,
        "com.apple.Safari":           .safari,
    ]

    /// Resolves the current audio source and performs the action on it.
    /// Returns true on a confirmed action, false if nothing controllable is playing.
    @discardableResult
    static func perform(_ action: Action) async -> Bool {
        switch source() {
        case .spotify:    return await runAppleScript(bundleID: "com.spotify.client", action: action)
        case .appleMusic: return await runAppleScript(bundleID: "com.apple.Music", action: action)
        case .youtubeMusic(let browser):
            return await YouTubeMusicService.sendControl(action.ytControl, browser: browser)
        case .none:
            return false
        }
    }

    // MARK: - Source resolution

    private enum Source {
        case spotify, appleMusic
        case youtubeMusic(YouTubeMusicService.BrowserKind)
        case none
    }

    private static func source() -> Source {
        guard let bundle = AudioSourceMonitor.currentSourceBundleID() else { return .none }
        switch bundle {
        case "com.spotify.client": return .spotify
        case "com.apple.Music":    return .appleMusic
        default:
            if let browser = browsers[bundle] { return .youtubeMusic(browser) }
            return .none
        }
    }

    // MARK: - AppleScript transport (Spotify / Apple Music)

    /// Both Spotify and Music expose the same transport verbs in their AppleScript
    /// dictionaries: `next track`, `previous track`, `playpause`.
    private static func runAppleScript(bundleID: String, action: Action) async -> Bool {
        let verb: String
        switch action {
        case .previous:  verb = "previous track"
        case .playPause: verb = "playpause"
        case .next:      verb = "next track"
        }
        let script = """
        tell application id "\(bundleID)"
            if it is running then
                \(verb)
                return "OK"
            end if
            return "NOT_RUNNING"
        end tell
        """
        let out = await AppleScriptRunner.runString(script)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
    }
}

@available(macOS 14.2, *)
private extension PlaybackController.Action {
    var ytControl: YouTubeMusicService.Control {
        switch self {
        case .previous:  return .previous
        case .playPause: return .playPause
        case .next:      return .next
        }
    }
}
