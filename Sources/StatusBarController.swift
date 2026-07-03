import Cocoa
import ServiceManagement
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let audio = AudioEngine()
    private let loginItem = SMAppService.mainApp
    private lazy var autoSelector = AutoPresetSelector(audio: audio)

    private let vm = EQViewModel()
    private var panel: NSPanel!
    private var hostingView: NSHostingView<PopoverView>!
    private var clickMonitor: Any?
    private let spectrum = SpectrumAnalyzer()
    private var displayTimer: Timer?
    private var lastCurvePreset: String = ""
    private var lastLoadedArtURL: String?

    private let presetDefaultsKey = "SesEQ.activePresetName"
    private let autoDefaultsKey   = "SesEQ.autoEnabled"

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        wireActions()
        buildPanel()

        restoreActivePreset()
        audio.onStateChange = { [weak self] in self?.syncVM() }
        autoSelector.onStatusChange = { [weak self] in self?.syncVM() }
        if UserDefaults.standard.bool(forKey: autoDefaultsKey) {
            autoSelector.enabled = true
        }
        vm.freqs = FrequencyResponse.frequencyAxis(points: 160)
        recomputeCurve()
        syncVM()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SesEQ")
        button.image?.isTemplate = true
        button.action = #selector(togglePanel)
        button.target = self
    }

    private func wireActions() {
        vm.onToggleEQ      = { [weak self] in self?.toggleEnabled() }
        vm.onToggleAuto    = { [weak self] in self?.toggleAuto() }
        vm.onSelectPreset  = { [weak self] name in self?.selectPreset(name) }
        vm.onPrevious      = { [weak self] in self?.transport(.previous) }
        vm.onPlayPause     = { [weak self] in self?.transport(.playPause) }
        vm.onNext          = { [weak self] in self?.transport(.next) }
        vm.onConnectSpotify = { [weak self] in self?.spotifyMenu() }
        vm.onTestAutomation = { [weak self] in self?.testPermissions() }
        vm.onTestYTMusic    = { [weak self] in self?.testYouTubeMusic() }
        vm.onToggleLogin    = { [weak self] in self?.toggleLoginItem() }
        vm.onQuit           = { NSApplication.shared.terminate(nil) }
    }

    /// Routes a transport press to whatever supported player is currently playing.
    private func transport(_ action: PlaybackController.Action) {
        Task { await PlaybackController.perform(action) }
    }

    // MARK: Floating panel (precise positioning under the menu-bar item)

    private func buildPanel() {
        // HARD width via Auto Layout: a width constraint is not a "proposal" SwiftUI can
        // ignore (unlike .frame on a raw NSHostingView, which auto-sizes wider and gets
        // clipped). Pinning the hosting view to exactly 318 forces SwiftUI to lay out at
        // 318 → long text truncates instead of overflowing.
        let hv = NSHostingView(rootView: PopoverView(vm: vm))
        hv.translatesAutoresizingMaskIntoConstraints = false
        hostingView = hv

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 420))
        container.addSubview(hv)
        // Pin ONLY leading+top+width. NOT trailing/bottom — pinning both edges to a
        // possibly-wider container would force the hosting view to stretch and break the
        // 318 width (the bug that made content overflow). With leading+width only, the
        // hosting view is ALWAYS exactly 318 and the container hugs it.
        NSLayoutConstraint.activate([
            hv.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            hv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hv.topAnchor.constraint(equalTo: container.topAnchor),
            container.trailingAnchor.constraint(equalTo: hv.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: hv.bottomAnchor),
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 420),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = container
        p.delegate = self
        panel = p
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    static let panelWidth: CGFloat = 318

    private func showPanel() {
        syncVM()
        guard let button = statusItem.button, let bw = button.window else { return }

        // Measure content height with the width hard-pinned to 318.
        hostingView.layoutSubtreeIfNeeded()
        let contentH = max(hostingView.fittingSize.height, 1)
        let screenH = (bw.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let panelH = min(contentH, screenH - 24)
        panel.setContentSize(NSSize(width: Self.panelWidth, height: panelH))

        let inWindow = button.convert(button.bounds, to: nil)
        let onScreen = bw.convertToScreen(inWindow)
        var x = onScreen.maxX - Self.panelWidth
        var y = onScreen.minY - panelH - 6
        if let screen = bw.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            x = min(max(vis.minX + 8, x), vis.maxX - Self.panelWidth - 8)
            if y < vis.minY + 8 { y = vis.minY + 8 }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panelTopY = y + panelH
        panel.makeKeyAndOrderFront(nil)

        startDisplayTimer()
        installClickMonitor()
    }

    private var panelTopY: CGFloat = 0

    /// Re-fit when content height changes (e.g. settings expands), keeping the top pinned
    /// under the menu bar. Called from the display timer while the panel is open.
    private func syncPanelSize() {
        guard panel.isVisible, panelTopY > 0 else { return }
        let contentH = max(hostingView.fittingSize.height, 1)
        let screenH = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let panelH = min(contentH, screenH - 24)
        if abs(panelH - panel.frame.height) > 0.5 {
            panel.setContentSize(NSSize(width: Self.panelWidth, height: panelH))
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: panelTopY - panelH))
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        stopDisplayTimer()
        removeClickMonitor()
    }

    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    /// Dismiss when the user clicks outside the panel (in another app or the desktop).
    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: Live spectrum

    private func startDisplayTimer() {
        stopDisplayTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickSpectrum() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        spectrum?.reset()
    }

    private func tickSpectrum() {
        guard panel.isVisible else { return }
        syncPanelSize()
        if audio.isRunning,
           let (samples, rate) = audio.snapshotAnalysisAudio(seconds: 0.06),
           let analyzer = spectrum {
            vm.spectrum = analyzer.process(samples: samples, sampleRate: rate)
        } else if !vm.spectrum.isEmpty {
            // Decay to flat when nothing is playing / EQ bypassed.
            vm.spectrum = vm.spectrum.map { $0 * 0.8 }
            if (vm.spectrum.max() ?? 0) < 0.01 { vm.spectrum = [] }
        }
    }

    // MARK: Actions

    private func toggleEnabled() {
        audio.setEnabled(!audio.userWantsEQ)
        syncVM()
    }

    private func selectPreset(_ name: String) {
        guard let preset = EQPreset.builtIn.first(where: { $0.name == name }) else { return }
        if autoSelector.enabled {
            autoSelector.enabled = false
            UserDefaults.standard.set(false, forKey: autoDefaultsKey)
        }
        audio.activePreset = preset
        UserDefaults.standard.set(name, forKey: presetDefaultsKey)
        syncVM()
    }

    private func toggleAuto() {
        autoSelector.enabled.toggle()
        UserDefaults.standard.set(autoSelector.enabled, forKey: autoDefaultsKey)
        syncVM()
    }

    private func toggleLoginItem() {
        do {
            if loginItem.status == .enabled { try loginItem.unregister() }
            else { try loginItem.register() }
        } catch {
            presentAlert(title: "Login öğesi güncellenemedi", body: error.localizedDescription)
        }
        syncVM()
    }

    // MARK: State sync → view model

    private func restoreActivePreset() {
        let savedName = UserDefaults.standard.string(forKey: presetDefaultsKey) ?? EQPreset.flat.name
        if let preset = EQPreset.builtIn.first(where: { $0.name == savedName }) {
            audio.activePreset = preset
        }
    }

    private func recomputeCurve() {
        let preset = audio.activePreset
        vm.responseDB = FrequencyResponse.responseDB(
            bands: preset.bands, globalGainDB: preset.globalGainDB,
            sampleRate: 48000, freqs: vm.freqs)
        lastCurvePreset = preset.name
    }

    private func syncVM() {
        vm.userWantsEQ = audio.userWantsEQ
        vm.isRunning = audio.isRunning
        vm.bypassReason = audio.bypassReason
        vm.autoOn = autoSelector.enabled
        // "Has a live source" = auto is on and the last detection resolved to an actual track/
        // source (not the idle "Ses kaynağı yok" / "—"). Drives whether chips show a pinned pick.
        let det = autoSelector.lastDetection
        vm.autoHasSource = autoSelector.enabled && det != "—" && !det.contains("Ses kaynağı yok")
        vm.presetName = audio.activePreset.name
        vm.outputName = audio.outputDeviceName
        vm.spotifyConnected = autoSelector.spotifyAuth.isConnected
        vm.loginEnabled = (loginItem.status == .enabled)
        vm.detection = autoSelector.enabled ? autoSelector.lastDetection : "—"
        vm.parseNowPlaying(from: autoSelector.lastDetection)

        if lastCurvePreset != audio.activePreset.name {
            recomputeCurve()
        }
        loadArtworkIfChanged()
        configureButtonState()
    }

    private func loadArtworkIfChanged() {
        let url = autoSelector.lastArtworkURL
        guard url != lastLoadedArtURL else { return }
        lastLoadedArtURL = url
        guard let url else { vm.artwork = nil; vm.artworkAccent = nil; return }
        Task { [weak self] in
            guard let data = await ArtworkLoader.loadData(url) else { return }
            guard let self, self.autoSelector.lastArtworkURL == url, let img = NSImage(data: data) else { return }
            self.vm.artwork = img
            self.vm.artworkAccent = ArtworkLoader.vibrantColor(from: img)
        }
    }

    private func configureButtonState() {
        guard let button = statusItem.button else { return }
        let symbol = audio.isRunning ? "waveform.path.ecg" : "waveform"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SesEQ")
        button.image?.isTemplate = true
    }

    private func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }

    // MARK: Diagnostics / Spotify (unchanged behavior, invoked from popover menu)

    private func testPermissions() {
        let apps: [(String, String)] = [
            ("Spotify",     #"tell application id "com.spotify.client" to if it is running then return name of current track"#),
            ("Apple Music", #"tell application id "com.apple.Music"    to if it is running then return name of current track"#),
            ("Chrome",      #"tell application id "com.google.Chrome"  to if it is running then if (count of windows) > 0 then return URL of active tab of front window"#),
            ("Safari",      #"tell application "Safari"                to if it is running then if (count of windows) > 0 then return URL of current tab of front window"#),
            ("Arc",         #"tell application id "company.thebrowser.Browser" to if it is running then if (count of windows) > 0 then return URL of active tab of front window"#),
            ("Brave",       #"tell application id "com.brave.Browser"  to if it is running then if (count of windows) > 0 then return URL of active tab of front window"#),
            ("Edge",        #"tell application id "com.microsoft.edgemac" to if it is running then if (count of windows) > 0 then return URL of active tab of front window"#),
        ]
        Task { @MainActor in
            var report = "Her satır bir kaynak. ✓ = izinli, ⚠ = izin yok, • = kapalı/yok\n\n"
            for (name, script) in apps {
                switch await AppleScriptRunner.run(script) {
                case .success(let s):      report += "✓ \(name): \(s.isEmpty ? "(çalmıyor)" : String(s.prefix(50)))\n"
                case .permissionDenied:    report += "⚠ \(name): otomasyon izni REDDEDİLDİ\n"
                case .appNotRunning:       report += "• \(name): yüklü değil veya çalışmıyor\n"
                case .otherError(let c, let m): report += "✗ \(name): hata \(c) — \(m.prefix(60))\n"
                }
            }
            report += "\n⚠ varsa: Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon → SesEQ"
            let alert = NSAlert()
            alert.messageText = "Otomasyon erişim durumu"
            alert.informativeText = report
            alert.addButton(withTitle: "Tamam")
            alert.addButton(withTitle: "Ayarları Aç")
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func testYouTubeMusic() {
        Task { @MainActor in
            var report = "Her satır bir tarayıcı. ✓ = okuyor, ⚠ = ayar eksik\n\n"
            for browser in [YouTubeMusicService.BrowserKind.chrome, .arc, .brave, .edge, .safari] {
                report += "\(browser.appName): \(await YouTubeMusicService.diagnose(browser: browser))\n"
            }
            report += "\nEğer ⚠ görüyorsan tarayıcıda:\n"
            report += "  • Chrome/Brave/Edge/Arc: View → Developer → 'Allow JavaScript from Apple Events'\n"
            report += "  • Safari: Settings → Advanced → 'Show Develop menu' → Develop → aynısı\n"
            let alert = NSAlert()
            alert.messageText = "YouTube Music erişim durumu"
            alert.informativeText = report
            alert.runModal()
        }
    }

    private func spotifyMenu() {
        let auth = autoSelector.spotifyAuth
        if auth.isConnected {
            let alert = NSAlert()
            alert.messageText = "Spotify bağlantısı"
            alert.informativeText = "SesEQ Spotify hesabına bağlı. Pre-fetch aktif.\n\nBağlantıyı kaldırmak ister misin?"
            alert.addButton(withTitle: "Bağlı tut")
            alert.addButton(withTitle: "Bağlantıyı kaldır")
            if alert.runModal() == .alertSecondButtonReturn { auth.disconnect(); syncVM() }
            return
        }
        if auth.clientID == nil || auth.clientID?.isEmpty == true { promptForClientID(); return }
        startConnectFlow()
    }

    private func promptForClientID() {
        let alert = NSAlert()
        alert.messageText = "Spotify Client ID gerekli"
        alert.informativeText = """
        Spotify Developer dashboard'da bir uygulama oluştur:

        1. https://developer.spotify.com/dashboard
        2. "Create app" → ad: SesEQ
        3. Redirect URI: \(SpotifyAuth.redirectURI)
        4. Web API'yi seç → Save
        5. Settings'ten Client ID'yi kopyala ve aşağıya yapıştır
        """
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        input.placeholderString = "32 karakterlik hex Client ID"
        alert.accessoryView = input
        alert.addButton(withTitle: "Devam")
        alert.addButton(withTitle: "Dashboard'u Aç")
        alert.addButton(withTitle: "Vazgeç")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let id = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            autoSelector.spotifyAuth.setClientID(id)
            startConnectFlow()
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://developer.spotify.com/dashboard") { NSWorkspace.shared.open(url) }
        default: break
        }
    }

    private func startConnectFlow() {
        Task { @MainActor in
            do {
                try await autoSelector.spotifyAuth.connect()
                presentAlert(title: "Spotify bağlandı ✓",
                             body: "Pre-fetch aktif. Otomatik preset modunda sıradaki şarkı önceden hazırlanır.")
                syncVM()
            } catch {
                presentAlert(title: "Bağlantı başarısız", body: error.localizedDescription)
            }
        }
    }
}
