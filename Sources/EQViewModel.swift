import SwiftUI

/// Observable UI state for the popover. The StatusBarController pushes state in via
/// `update(...)` and a display timer feeds `spectrum`; the SwiftUI view reads it.
@available(macOS 14.2, *)
@MainActor
final class EQViewModel: ObservableObject {
    // Core state
    @Published var userWantsEQ = false
    @Published var isRunning = false
    @Published var bypassReason: String? = nil
    @Published var autoOn = false
    /// True only when auto mode is on AND a real audio source is currently detected.
    /// When auto is on but nothing is playing ("Ses kaynağı yok"), this is false so the
    /// chips show NO pinned selection instead of a stale manual pick.
    @Published var autoHasSource = false
    @Published var presetName = EQPreset.flat.name
    @Published var detection = "—"
    @Published var outputName = "—"
    @Published var spotifyConnected = false
    @Published var loginEnabled = false

    // Now playing
    @Published var nowArtist: String = ""
    @Published var nowTitle: String = ""
    @Published var detectionSource: String = ""   // "Spotify" | "katalog" | "analiz" | "ön-yükleme"
    @Published var artwork: NSImage?
    @Published var artworkAccent: Color?

    // EQ curve
    @Published var freqs: [Double] = []
    @Published var responseDB: [Double] = []

    // Live spectrum (0...1 per band)
    @Published var spectrum: [Float] = []

    let presets: [EQPreset] = EQPreset.builtIn

    /// Accent color: prefer the color extracted from album art (Apple-Music style),
    /// then the active preset's genre color, then idle.
    var accent: Color {
        if let art = artworkAccent { return art }
        guard userWantsEQ else { return Theme.idleAccent }
        return Theme.accent(forPresetName: presetName)
    }

    /// The genre color for the small genre dot/label — always reflects the detected
    /// preset's genre color (informative even when EQ is off).
    var genreAccent: Color {
        Theme.accent(forPresetName: presetName)
    }

    // Actions wired by the controller.
    var onToggleEQ: () -> Void = {}
    var onToggleAuto: () -> Void = {}
    var onSelectPreset: (String) -> Void = { _ in }
    var onPrevious: () -> Void = {}
    var onPlayPause: () -> Void = {}
    var onNext: () -> Void = {}
    var onConnectSpotify: () -> Void = {}
    var onTestAutomation: () -> Void = {}
    var onTestYTMusic: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onQuit: () -> Void = {}

    func parseNowPlaying(from detection: String) {
        // Detection source for the visible genre line. Only updated when the detection
        // string carries a source tag — same-track polls rebuild the line WITHOUT a tag,
        // so the nil-guard keeps the last real source instead of blanking it every second.
        if let s = Self.deriveSource(detection) { detectionSource = s }

        // detection lines look like "Source: Artist — Title [tag] → Preset"
        // Extract the "Artist — Title" middle for the now-playing card.
        guard let colon = detection.firstIndex(of: ":") else {
            nowArtist = ""; nowTitle = ""; detectionSource = ""
            return
        }
        var mid = String(detection[detection.index(after: colon)...])
        for sep in [" [", " →", "  ⤴"] {
            if let r = mid.range(of: sep) { mid = String(mid[..<r.lowerBound]) }
        }
        mid = mid.trimmingCharacters(in: .whitespaces)
        if let dash = mid.range(of: " — ") {
            nowArtist = String(mid[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            nowTitle = String(mid[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            nowArtist = ""
            nowTitle = mid
        }
    }

    /// Infers the genre SOURCE from a detection string, or nil when the line has no tag
    /// (a same-track poll), so callers can keep the previous value. Order matters: the
    /// Spotify "♫" marker wins, then pre-fetch, then the classifier, then plain catalog.
    private static func deriveSource(_ d: String) -> String? {
        if d.contains("♪")            { return "MusicBrainz" }   // tag "[genre ♪]"
        if d.contains("pre-fetch")    { return "ön-yükleme" }
        if d.contains("ses analizi")  { return "analiz…" }   // classifier pending
        if d.contains("%]")           { return "analiz" }    // classifier done "[style · NN%]"
        if d.contains("[") && d.contains("→") { return "katalog" }  // iTunes / Music.app tag
        return nil
    }
}
