import SwiftUI
import AppKit

/// The conversation-mode canvas. Every element is layered around a central orb that
/// IS the agent. Backdrop, nebulae, orbital rings, satellites, particles, and ripple
/// waves all react to the same state machine (idle / listening / thinking / interpreting
/// / speaking), so the whole scene "breathes" together.
///
/// Interaction is push-to-talk on the orb (mouse or spacebar). VoiceOver users get
/// tap-to-toggle and every state change is announced.
struct OrbConversationView: View {
    @ObservedObject var session: ClaudeChatSession
    @ObservedObject var speechInput: SpeechInput
    @ObservedObject var speechOutput: SpeechOutput
    let onExit: () -> Void

    @State private var isPressing: Bool = false
    @State private var lastAnnouncedState: OrbState = .idle
    @State private var savedSilenceInterval: TimeInterval = 0.9
    @State private var crawlBeats: [CrawlBeat] = []
    @State private var isFullscreen: Bool = false
    @FocusState private var orbFocused: Bool

    var body: some View {
        GeometryReader { geo in
            // Big central sphere. The refracted CLI text inside is much more legible
            // at this scale — small numbers meant the log inside was unreadable.
            let side = min(geo.size.width, geo.size.height)
            let orbRadius = min(side * 0.24, 260)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.36)
            // Crawl now spans nearly the full screen — beats rise from just above the
            // bottom HUD all the way up past the orb (which sits IN FRONT of them
            // and occludes as they pass), fading gradually as they approach the top.
            let crawlBottomY = geo.size.height - 60
            let crawlTopY: CGFloat = 70

            ZStack {
                // ── 1. Deep-space backdrop ────────────────────────────────────
                DeepSpaceBackdrop(state: orbState)

                // ── 2. Slow-drifting nebula clouds ────────────────────────────
                NebulaField(state: orbState, focus: center)
                    .blendMode(.plusLighter)

                // ── 3. Starfield with subtle parallax + twinkle ───────────────
                StarField(state: orbState, focus: center)

                // ── 4. Concentric orbital rings on multiple planes ────────────
                OrbitalPlanes(state: orbState, center: center, radius: orbRadius)

                // ── 4b. Unified crawl BEHIND the orb ──────────────────────────
                //  Beats spawn at the bottom, drift up the full height of the screen,
                //  pass BEHIND the sphere (the sphere occludes them), and fade slowly
                //  over the last ~250 pt before the top. No border boxes — just text
                //  with a strong drop-shadow so it reads over the busy backdrop.
                SkywardCrawl(
                    beats: crawlBeats,
                    liveText: liveCaptionText,
                    bottomY: crawlBottomY,
                    topY: crawlTopY,
                    centerX: geo.size.width / 2,
                    state: orbState
                )
                .allowsHitTesting(false)

                // ── 5. Rear satellites (behind orb) ───────────────────────────
                SatelliteField(
                    labels: satellites,
                    orbRadius: orbRadius,
                    center: center,
                    state: orbState,
                    side: .back
                )

                // ── 5b. Processing ring — visible during thinking/interpreting ─
                ProcessingRing(state: orbState, center: center, orbRadius: orbRadius)
                    .allowsHitTesting(false)

                // ── 6. The orb itself ─────────────────────────────────────────
                OrbSphere(
                    state: orbState,
                    isPressing: isPressing,
                    level: audioLevel,
                    rawLog: session.rawLog
                )
                    .frame(width: orbRadius * 2, height: orbRadius * 2)
                    .position(center)
                    .gesture(pressGesture)
                    .focusable(true)
                    .focused($orbFocused)
                    // Kill macOS's default blue focus rectangle around the sphere.
                    // Keyboard focus still works — this just hides the visual box.
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .up]) { press in
                        // Escape is reserved: exit fullscreen if we're in fullscreen,
                        // do nothing otherwise. Explicitly NOT push-to-talk.
                        if press.key == .escape {
                            if press.phase == .down, isFullscreen {
                                toggleFullscreen()
                            }
                            return .handled
                        }
                        // Any other key (letters, digits, arrows, spacebar, return…)
                        // acts as a push-to-talk trigger while held.
                        switch press.phase {
                        case .down: startPressing()
                        case .up:   endPressing()
                        default:    break
                        }
                        return .handled
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Claudette orb")
                    .accessibilityValue(orbState.description)
                    .accessibilityHint("Hold to speak. Release to send.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleTapForVoiceOver() }

                // ── 6b. Sub-agent spheres — pop out of the main orb, orbit ────
                SubagentField(
                    subagents: session.subagents,
                    center: center,
                    orbRadius: orbRadius,
                    state: orbState
                )
                .allowsHitTesting(false)

                // ── 7. Ripple rings — TTS-driven ──────────────────────────────
                RippleRings(state: orbState, center: center, orbRadius: orbRadius)
                    .allowsHitTesting(false)

                // ── 8. Front satellites (in front of orb) ─────────────────────
                SatelliteField(
                    labels: satellites,
                    orbRadius: orbRadius,
                    center: center,
                    state: orbState,
                    side: .front
                )

                // ── 9. Particle motes — rise from orb, drift out ──────────────
                ParticleField(state: orbState, center: center, orbRadius: orbRadius)
                    .allowsHitTesting(false)

                // ── 10. Foreground UI ─────────────────────────────────────────
                VStack {
                    topBar
                    Spacer()
                }

                // Compact state chip pinned just under the sphere. This replaces the
                // old caption block — the actual text lives in the crawl now.
                StateChip(state: orbState)
                    .position(x: geo.size.width / 2, y: center.y + orbRadius + 12)
                    .allowsHitTesting(false)

                HUDLayer(session: session, state: orbState)
                    .allowsHitTesting(false)

                // ── 10b. Side panels: Todos (right) + Monitor (left) ──────────
                if !session.todos.isEmpty {
                    TodoPanel(todos: session.todos, state: orbState)
                        .position(x: geo.size.width - 160, y: geo.size.height * 0.42)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if let mon = session.latestMonitor {
                    MonitorPanel(event: mon, state: orbState)
                        .position(x: 160, y: geo.size.height * 0.42)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // ── 11. Vignette + film grain ─────────────────────────────────
                VignetteOverlay()
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            orbFocused = true
            savedSilenceInterval = speechInput.silenceInterval
            speechInput.silenceInterval = 999
            // Sync fullscreen state with the current window in case orb mode is
            // entered while the window is already fullscreen.
            isFullscreen = currentWindow()?.styleMask.contains(.fullScreen) ?? false
            announce("Conversation mode. Hold any key to speak.")
        }
        .onDisappear {
            speechInput.silenceInterval = savedSilenceInterval
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
        .onChange(of: orbState) { _, new in
            if new != lastAnnouncedState {
                lastAnnouncedState = new
                announce(new.announcement)
            }
        }
        // Feed the crawl. Each unique live beat spawns a rising line; the final
        // interpretation lands as a bigger, more prominent beat that lingers.
        .onReceive(session.$liveNarration) { beat in
            guard let beat, !beat.isEmpty else { return }
            addCrawlBeat(text: beat, kind: .live)
        }
        // Claude's own streaming assistant text, chunked at sentence boundaries.
        // These beats show his real-time planning prose — "I'll check the auth
        // middleware first…", "Looks like it stores tokens in a way that…" — so
        // the crawl feels like a live thought stream, not a delayed summary.
        .onReceive(session.$streamingChunk) { chunk in
            guard let chunk, !chunk.isEmpty else { return }
            addCrawlBeat(text: chunk, kind: .streaming)
        }
        .onReceive(session.$interpretation) { interp in
            guard let interp, !interp.narration.isEmpty else { return }
            addCrawlBeat(text: interp.narration, kind: .narration)
        }
    }

    /// Push a beat onto the crawl. Guarantees vertical spacing between beats by
    /// coalescing rapid-fire additions:
    /// - Exact duplicates in the last 3 beats are dropped.
    /// - If the last beat is younger than 0.9 s (i.e. it hasn't travelled far enough
    ///   to leave clear space above the bottom), we MERGE this text into it rather
    ///   than stacking a second beat right on top. This is what stops the "wall of
    ///   overlapping paragraphs" the user saw when streaming text arrived quickly.
    /// Exceptions: `narration` (final interpreter reply) always gets its own beat.
    private func addCrawlBeat(text: String, kind: CrawlBeat.Kind) {
        if crawlBeats.suffix(3).contains(where: { $0.text == text }) { return }

        let now = Date()
        if kind != .narration,
           let lastIdx = crawlBeats.indices.last,
           now.timeIntervalSince(crawlBeats[lastIdx].spawnedAt) < 0.9,
           crawlBeats[lastIdx].kind == kind {
            let combined = crawlBeats[lastIdx].text + " " + text
            crawlBeats[lastIdx].text = combined
            crawlBeats[lastIdx].spawnedAt = now
            return
        }

        crawlBeats.append(CrawlBeat(text: text, spawnedAt: now, kind: kind))
        if crawlBeats.count > 16 {
            crawlBeats.removeFirst(crawlBeats.count - 16)
        }
    }

    // MARK: - Foreground UI

    private var topBar: some View {
        HStack {
            Button(action: onExit) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Exit")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            // Escape is now owned by our onKeyPress handler — it exits fullscreen
            // if fullscreen, so we can't bind it here too.
            .accessibilityHint("Return to the timeline view.")

            Spacer()

            Button(action: toggleFullscreen) {
                Image(systemName: isFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .frame(width: 32, height: 26)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(isFullscreen ? "Exit fullscreen (Esc)" : "Enter fullscreen")
            .accessibilityLabel(isFullscreen ? "Exit fullscreen" : "Enter fullscreen")
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
    }

    /// The text shown as the "live" (in-flight) beat at the bottom of the crawl —
    /// the mic transcript while listening, the current tool intent while thinking,
    /// otherwise nil. This is what the user sees updating in real time; committed
    /// beats live in `crawlBeats` and rise up the screen from there.
    private var liveCaptionText: String? {
        if speechInput.isListening {
            let t = speechInput.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Listening…" : t
        }
        if session.isRunning {
            if let a = session.activeAction { return a.humanTitle }
            return nil  // liveNarration already goes into crawlBeats
        }
        if session.isInterpreting { return "Composing…" }
        if crawlBeats.isEmpty { return "Hold the orb to speak." }
        return nil
    }

    // MARK: - Satellites

    private var satellites: [SatelliteLabel] {
        var out: [SatelliteLabel] = []
        if let live = session.activeAction, session.isRunning {
            out.append(SatelliteLabel(text: live.humanTitle.lowercased(), kind: .live))
        }
        if let interp = session.interpretation {
            for tag in interp.tags {
                out.append(SatelliteLabel(text: tag, kind: .tag))
            }
            for snippet in interp.snippets {
                out.append(SatelliteLabel(text: snippet, kind: .snippet))
            }
        }
        return Array(out.prefix(9))
    }

    // MARK: - State

    private var orbState: OrbState {
        if speechInput.isListening { return .listening }
        if session.isRunning { return .thinking }
        if speechOutput.isSpeaking { return .speaking }
        if session.isInterpreting { return .interpreting }
        return .idle
    }

    /// Rough audio level in 0…1 used to drive orb pulsing. We don't tap the raw audio
    /// buffer — we synthesise a plausible level from state instead so the visuals feel
    /// responsive without adding another audio observer.
    private var audioLevel: Double {
        switch orbState {
        case .listening: return 0.8
        case .speaking:  return 0.7
        case .thinking:  return 0.5
        case .interpreting: return 0.4
        case .idle: return 0.25
        }
    }

    // MARK: - Gesture

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isPressing { startPressing() }
            }
            .onEnded { _ in
                endPressing()
            }
    }

    private func startPressing() {
        guard !isPressing else { return }
        isPressing = true
        if speechOutput.isSpeaking { speechOutput.stop() }
        if !speechInput.isListening {
            Task { await speechInput.start() }
        }
    }

    private func endPressing() {
        guard isPressing else { return }
        isPressing = false
        let text = speechInput.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        speechInput.stop()
        guard !text.isEmpty else { return }
        // Hard interrupt: if Claude is still churning through the previous turn,
        // kill that process before sending the new message so the CLI processes
        // the interrupt immediately. `sessionId` is preserved on the session
        // object, so the next spawn resumes the same Claude Code session via
        // --resume and keeps full context.
        if session.isRunning { session.stop() }
        session.send(text)
    }

    private func toggleTapForVoiceOver() {
        if isPressing { endPressing() } else { startPressing() }
    }

    /// Toggle the frontmost app window's native macOS fullscreen. Escape (owned by
    /// our onKeyPress handler) calls this when `isFullscreen == true`.
    private func toggleFullscreen() {
        guard let window = currentWindow() else { return }
        window.toggleFullScreen(nil)
    }

    /// Best-effort lookup of the window hosting the orb — keyWindow first, main next,
    /// then the first visible window. Called during onAppear to sync `isFullscreen`
    /// with whatever the system state actually is.
    private func currentWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
    }

    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

// MARK: - Orb state

enum OrbState: Equatable {
    case idle, listening, thinking, interpreting, speaking

    /// Primary hue. Chosen so each state reads as a distinct emotional temperature.
    var hue: Color {
        switch self {
        case .idle:         return Color(hex: 0xC96442)   // warm amber
        case .listening:    return Color(hex: 0x5AC8E5)   // clear cyan
        case .thinking:     return Color(hex: 0xE38A3F)   // deep orange
        case .interpreting: return Color(hex: 0xA680E5)   // amethyst
        case .speaking:     return Color(hex: 0x64D9AF)   // aurora green
        }
    }

    /// Complementary highlight used deep in the orb + on rim lights.
    var accent: Color {
        switch self {
        case .idle:         return Color(hex: 0xF6C29A)
        case .listening:    return Color(hex: 0xB6E9F7)
        case .thinking:     return Color(hex: 0xFFCD8B)
        case .interpreting: return Color(hex: 0xD5BFF7)
        case .speaking:     return Color(hex: 0xB2ECD3)
        }
    }

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .interpreting: return "Composing"
        case .speaking: return "Speaking"
        }
    }

    var announcement: String {
        switch self {
        case .idle: return "Ready. Hold the orb to speak."
        case .listening: return "Listening."
        case .thinking: return "Claude is working."
        case .interpreting: return "Composing a reply."
        case .speaking: return "Speaking."
        }
    }
}

// MARK: - Backdrop

/// Deep vertical gradient with a warm/cool bias driven by state — like the sky
/// tinting at different times of day.
private struct DeepSpaceBackdrop: View {
    let state: OrbState

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(hex: 0x02030A),
                    Color(hex: 0x090612),
                    Color(hex: 0x0E0A18)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                gradient: Gradient(colors: [
                    state.hue.opacity(0.18),
                    state.hue.opacity(0.05),
                    .clear
                ]),
                center: .center,
                startRadius: 60,
                endRadius: 700
            )
            .animation(.easeInOut(duration: 1.6), value: state)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Nebula clouds

/// A handful of huge blurred colour blobs that drift with different periods, giving
/// the whole scene a soft "the room has weather" feel.
private struct NebulaField: View {
    let state: OrbState
    let focus: CGPoint

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                nebula(index: 0, t: t, color: state.hue,     radius: 320, opacity: 0.30)
                nebula(index: 1, t: t, color: state.accent,  radius: 260, opacity: 0.24)
                nebula(index: 2, t: t, color: Color(hex: 0x6B3EAE), radius: 220, opacity: 0.20)
                nebula(index: 3, t: t, color: Color(hex: 0x2A6A9B), radius: 200, opacity: 0.18)
            }
        }
    }

    private func nebula(index: Int, t: Double, color: Color, radius: CGFloat, opacity: Double) -> some View {
        let seed = Double(index) * 2.7
        let dx = cos(t * (0.06 + Double(index) * 0.02) + seed) * 220
        let dy = sin(t * (0.05 + Double(index) * 0.017) + seed * 1.3) * 120
        return Circle()
            .fill(color)
            .frame(width: radius * 2, height: radius * 2)
            .blur(radius: 90)
            .opacity(opacity)
            .position(x: focus.x + dx, y: focus.y + dy)
    }
}

// MARK: - Star field

/// Deterministic star positions with time-varying twinkle. Drawn via Canvas for cost.
private struct StarField: View {
    let state: OrbState
    let focus: CGPoint

    // Cached star seeds — a single computation, reused every frame.
    private static let stars: [Star] = (0..<180).map { i in
        var rng = SeededRNG(seed: UInt64(truncatingIfNeeded: i &* 1103515245 &+ 12345))
        return Star(
            u: rng.nextUnit(),
            v: rng.nextUnit(),
            baseAlpha: 0.22 + rng.nextUnit() * 0.55,
            twinkleSpeed: 0.8 + rng.nextUnit() * 2.4,
            twinklePhase: rng.nextUnit() * 6.28,
            size: 0.6 + rng.nextUnit() * 1.8,
            warm: rng.nextUnit() > 0.7
        )
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for s in Self.stars {
                    let x = s.u * size.width
                    let y = s.v * size.height
                    let twinkle = 0.5 + 0.5 * sin(t * s.twinkleSpeed + s.twinklePhase)
                    let alpha = s.baseAlpha * (0.4 + 0.6 * twinkle)
                    let color: Color = s.warm ? Color(hex: 0xFFE8C2) : Color.white
                    let rect = CGRect(x: x - s.size / 2, y: y - s.size / 2,
                                      width: s.size, height: s.size)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                    if s.size > 1.6 {
                        // Bright stars get a soft glow around them.
                        let glow = CGRect(x: x - s.size, y: y - s.size, width: s.size * 2, height: s.size * 2)
                        ctx.fill(Path(ellipseIn: glow), with: .color(color.opacity(alpha * 0.18)))
                    }
                }
            }
        }
        .drawingGroup(opaque: false)
    }

    private struct Star {
        let u: Double
        let v: Double
        let baseAlpha: Double
        let twinkleSpeed: Double
        let twinklePhase: Double
        let size: Double
        let warm: Bool
    }
}

// MARK: - Orbital planes

/// Three concentric orbit rings on tilted planes, drawn behind the orb and satellites.
/// Rotate at different speeds so the scene reads as depth-of-field.
private struct OrbitalPlanes: View {
    let state: OrbState
    let center: CGPoint
    let radius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ring(t: t, radiusMul: 1.85, tilt: 0.35, thickness: 0.6, speed: 0.05, opacity: 0.20)
                ring(t: t, radiusMul: 2.30, tilt: 0.50, thickness: 0.5, speed: -0.04, opacity: 0.14)
                ring(t: t, radiusMul: 2.85, tilt: 0.28, thickness: 0.4, speed: 0.03, opacity: 0.10)
            }
            .position(center)
        }
    }

    /// A single tilted ring drawn with a rotating tangential highlight so it feels
    /// like a real orbit and not a static ellipse.
    private func ring(t: Double, radiusMul: CGFloat, tilt: CGFloat, thickness: CGFloat,
                      speed: Double, opacity: Double) -> some View {
        let rx = radius * radiusMul
        let ry = rx * tilt
        let sweep = Angle.radians(t * speed * 2 * .pi)
        return ZStack {
            Ellipse()
                .stroke(state.hue.opacity(opacity), lineWidth: thickness)
                .frame(width: rx * 2, height: ry * 2)
            // Bright arc that sweeps around the ring, giving it motion.
            Ellipse()
                .trim(from: 0.0, to: 0.18)
                .stroke(
                    LinearGradient(
                        colors: [.clear, state.accent.opacity(0.9), state.accent.opacity(0.0)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: thickness + 1.5, lineCap: .round)
                )
                .rotationEffect(sweep)
                .frame(width: rx * 2, height: ry * 2)
                .blur(radius: 1.2)
        }
        .compositingGroup()
    }
}

// MARK: - Satellite field

private struct SatelliteLabel: Identifiable, Equatable {
    let text: String
    let kind: Kind
    var id: String { "\(kind.rawValue)-\(text)" }

    enum Kind: String, Equatable {
        case tag, snippet, live
    }
}

/// Renders satellites in either the back half or the front half of the orbit so they
/// occlude naturally around the sphere. Adds motion-blur "ghosts" behind moving labels
/// for a feeling of speed.
private struct SatelliteField: View {
    enum Side { case back, front }

    let labels: [SatelliteLabel]
    let orbRadius: CGFloat
    let center: CGPoint
    let state: OrbState
    let side: Side

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed = state.orbitSpeed
            let rotation = t * speed
            let rx = orbRadius * 1.85
            let ry = orbRadius * 0.62

            ZStack {
                ForEach(Array(labels.enumerated()), id: \.element.id) { idx, label in
                    let base = 2 * .pi * Double(idx) / Double(max(labels.count, 1))
                    let angle = base + rotation
                    // Depth: 1 at the near point (bottom of ellipse), 0 at the far point.
                    let depth = (cos(angle - .pi / 2) + 1) / 2
                    let isFront = depth > 0.5
                    let visible = (side == .front) ? isFront : !isFront
                    if visible {
                        satellite(label: label, angle: angle, rx: rx, ry: ry, depth: depth, t: t)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labels.isEmpty ? "" : "Ideas: " + labels.map(\.text).joined(separator: ", "))
    }

    /// One satellite plus its trailing motion-blur ghosts. Scale/opacity vary with depth
    /// so labels feel like they pass around a sphere.
    @ViewBuilder
    private func satellite(label: SatelliteLabel, angle: Double, rx: CGFloat, ry: CGFloat,
                           depth: Double, t: Double) -> some View {
        let scale = 0.68 + 0.44 * depth
        let alpha = 0.28 + 0.72 * depth
        let blur = (1 - depth) * 2.0
        let x = cos(angle) * Double(rx)
        let y = sin(angle) * Double(ry)

        ZStack {
            // Trailing ghosts — 3 dimmer copies at earlier angles.
            ForEach(1..<4) { g in
                let ga = angle - Double(g) * 0.06
                let gx = cos(ga) * Double(rx)
                let gy = sin(ga) * Double(ry)
                satelliteView(label)
                    .scaleEffect(scale * (1 - 0.05 * Double(g)))
                    .opacity(alpha * (0.20 - 0.05 * Double(g)))
                    .blur(radius: blur + 3 + CGFloat(g))
                    .offset(x: gx, y: gy)
            }
            satelliteView(label)
                .scaleEffect(scale)
                .opacity(alpha)
                .blur(radius: blur)
                .offset(x: x, y: y)
        }
        .position(center)
    }

    @ViewBuilder
    private func satelliteView(_ label: SatelliteLabel) -> some View {
        switch label.kind {
        case .tag:
            Text(label.text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.94))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(state.hue.opacity(0.55), lineWidth: 0.8)
                        )
                )
                .shadow(color: state.hue.opacity(0.35), radius: 8, y: 1)
        case .snippet:
            Text(label.text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(state.accent.opacity(0.95))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 4)
        case .live:
            HStack(spacing: 6) {
                Circle()
                    .fill(state.hue)
                    .frame(width: 6, height: 6)
                    .shadow(color: state.hue, radius: 6)
                Text(label.text)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(state.hue.opacity(0.24))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(state.hue.opacity(0.9), lineWidth: 1)
                    )
            )
            .shadow(color: state.hue.opacity(0.6), radius: 12, y: 2)
        }
    }
}

// MARK: - Orb sphere

/// Layered glowing sphere. Inside: a Canvas plasma of drifting colored blobs, clipped
/// to a circle. Outside: rim light + concentric halos + a soft iris.
private struct OrbSphere: View {
    let state: OrbState
    let isPressing: Bool
    let level: Double
    /// Raw Claude Code stdout, rendered as a refracted ticker inside the sphere.
    let rawLog: String

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathing = 1.0 + 0.03 * sin(t * 1.2)
            let pulse = 0.5 + 0.5 * sin(t * 2.4)

            ZStack {
                // Outer glow — a wide soft aura.
                Circle()
                    .fill(state.hue)
                    .opacity(state == .idle ? 0.14 : 0.28)
                    .blur(radius: 80)
                    .scaleEffect(1.6 * breathing)

                // Warm inner glow bleed.
                Circle()
                    .fill(state.accent)
                    .opacity(0.20)
                    .blur(radius: 40)
                    .scaleEffect(1.15)

                // Halos — thin rings that pulse outward when speaking or listening.
                Circle()
                    .stroke(state.hue.opacity(0.6), lineWidth: 1.2)
                    .scaleEffect(haloScale(t: t, phase: 0))
                    .opacity(haloOpacity(t: t, phase: 0))
                Circle()
                    .stroke(state.accent.opacity(0.4), lineWidth: 0.8)
                    .scaleEffect(haloScale(t: t, phase: 0.5))
                    .opacity(haloOpacity(t: t, phase: 0.5) * 0.6)

                // Plasma sphere body + refracted CLI ticker inside.
                GeometryReader { g in
                    let size = min(g.size.width, g.size.height)
                    ZStack {
                        Canvas { ctx, canvasSize in
                            Self.drawPlasma(context: &ctx, size: canvasSize, t: t, state: state, level: level)
                        }
                        .frame(width: size, height: size)

                        // Raw Claude Code stdout, refracted through a virtual glass
                        // lens. Sits ON TOP of the plasma so you can read it, but
                        // BELOW the rim/specular/shadow overlays so the highlights
                        // still sell the "3D sphere" illusion.
                        RefractionText(rawLog: rawLog, state: state)
                            .frame(width: size, height: size)
                            .opacity(0.85)
                            .blendMode(.screen)
                    }
                    .clipShape(Circle())
                    .overlay(
                        // Rim light — bright arc on the top-left, subtle glow all around.
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.55), state.accent.opacity(0.15), .clear],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.6
                            )
                    )
                    .overlay(
                        // Specular highlight — small bright spot on the top-left.
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.white.opacity(0.9), .clear],
                                    center: UnitPoint(x: 0.32, y: 0.28),
                                    startRadius: 2, endRadius: size * 0.28
                                )
                            )
                            .blendMode(.plusLighter)
                            .opacity(0.85)
                    )
                    .overlay(
                        // Deep shadow on the far side — anchors the orb visually.
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [.clear, .clear, Color.black.opacity(0.65)],
                                    center: UnitPoint(x: 0.72, y: 0.78),
                                    startRadius: size * 0.15, endRadius: size * 0.55
                                )
                            )
                    )
                }
                .scaleEffect(isPressing ? 0.94 : breathing)
                .animation(.easeInOut(duration: 0.18), value: isPressing)

                // Iris — a bright core that dilates with the state.
                Circle()
                    .fill(Color.white.opacity(state == .listening ? 0.85 : 0.55))
                    .frame(width: irisSize(t: t), height: irisSize(t: t))
                    .blur(radius: 8)
                    .blendMode(.plusLighter)

                // Sub-halo — very faint ring right at the orb boundary, always on.
                Circle()
                    .stroke(state.accent.opacity(0.35), lineWidth: 0.5)
                    .scaleEffect(1.02 + 0.02 * pulse)
            }
            .compositingGroup()
            .shadow(color: state.hue.opacity(0.55), radius: 40, x: 0, y: 0)
        }
    }

    /// Draws several drifting colored circles inside the orb — the "plasma" that
    /// makes it feel alive and volumetric. Clipped to a circle by the parent.
    private static func drawPlasma(context: inout GraphicsContext, size: CGSize, t: Double,
                                   state: OrbState, level: Double) {
        let w = size.width
        let h = size.height
        let cx = w / 2
        let cy = h / 2
        let R = min(w, h) / 2

        // Base fill — dark inner colour to give plasma something to sit on top of.
        context.fill(
            Path(ellipseIn: CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [
                    state.accent.opacity(0.9),
                    state.hue.opacity(0.75),
                    state.hue.opacity(0.35),
                    Color.black.opacity(0.75)
                ]),
                center: CGPoint(x: cx - R * 0.15, y: cy - R * 0.20),
                startRadius: 2,
                endRadius: R * 1.15
            )
        )

        // Six drifting "plasma" blobs — soft colored circles that orbit inside the sphere.
        let blobCount = 6
        for i in 0..<blobCount {
            let phase = Double(i) * (2 * .pi / Double(blobCount))
            let orbitR = R * (0.30 + 0.15 * sin(t * 0.7 + phase))
            let angle = t * (0.35 + Double(i) * 0.05) + phase
            let x = cx + cos(angle) * orbitR
            let y = cy + sin(angle * 1.1) * orbitR * 0.85
            let blobR = R * (0.55 + 0.12 * sin(t * 1.3 + phase))
            let color: Color = (i % 2 == 0) ? state.hue : state.accent
            let opacity = 0.28 + 0.18 * level

            context.fill(
                Path(ellipseIn: CGRect(x: x - blobR, y: y - blobR, width: blobR * 2, height: blobR * 2)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(opacity), .clear]),
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: blobR
                )
            )
        }
    }

    private func haloScale(t: Double, phase: Double) -> CGFloat {
        let period: Double
        switch state {
        case .listening: period = 1.4
        case .speaking:  period = 0.9
        case .thinking, .interpreting: period = 2.2
        case .idle:      period = 4.0
        }
        let cycle = (t + phase).truncatingRemainder(dividingBy: period) / period
        return 1.02 + 0.30 * CGFloat(cycle)
    }

    private func haloOpacity(t: Double, phase: Double) -> Double {
        switch state {
        case .listening, .speaking:
            let period = state == .speaking ? 0.9 : 1.4
            let cycle = (t + phase).truncatingRemainder(dividingBy: period) / period
            return 0.75 * (1 - cycle)
        case .thinking, .interpreting:
            return 0.35 + 0.15 * sin(t * 2.1 + phase)
        case .idle:
            return 0.24
        }
    }

    private func irisSize(t: Double) -> CGFloat {
        switch state {
        case .listening: return 42 + 10 * CGFloat(sin(t * 2.4))
        case .thinking, .interpreting: return 22 + 5 * CGFloat(sin(t * 3.4))
        case .speaking: return 30 + 12 * CGFloat(sin(t * 6.0))
        case .idle: return 24 + 3 * CGFloat(sin(t * 0.9))
        }
    }
}

// MARK: - Refraction text

/// Draws the raw Claude Code stdout log inside the sphere with three tricks that
/// together sell the "seen through curved glass" look:
///
/// - **Sine displacement** — each line is horizontally offset by two summed sine
///   waves parameterised on Y and time. Gives the shimmering water/heat-haze feel.
/// - **Radial pinch** — lines near the top/bottom edges of the sphere clip get
///   pulled toward the horizontal centre in proportion to their distance from the
///   equator. That's what mimics a fisheye lens's compression at the poles.
/// - **Chromatic aberration** — each line is drawn three times at slightly offset
///   positions, tinted red, cyan, and neutral. This is the RGB fringing you get
///   at the edges of a real lens.
///
/// The text is intentionally low-opacity + small so it reads as *inside* the orb
/// rather than a UI element on top of it.
private struct RefractionText: View {
    let rawLog: String
    let state: OrbState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                Canvas(rendersAsynchronously: true) { ctx, size in
                    drawLog(ctx: &ctx, size: size, t: t)
                }
                .blur(radius: 0.6)
            }
        }
    }

    private func drawLog(ctx: inout GraphicsContext, size: CGSize, t: Double) {
        // Trim each line to something visible; a full stream-json line can be 2 KB.
        // We show fewer, longer lines now that the sphere is bigger — legibility
        // beats density.
        let lines: [String] = rawLog
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0) }
            .suffix(28)
            .map { line in
                let clipped = line.count > 110 ? String(line.prefix(110)) + "…" : line
                return clipped
            }
        guard !lines.isEmpty else { return }

        let lineHeight: CGFloat = 14
        let bottomPad: CGFloat = 14
        let bottomY = size.height - bottomPad
        let cx = size.width / 2
        let halfH = size.height / 2

        for (i, line) in lines.enumerated() {
            let indexFromBottom = lines.count - 1 - i
            let baseY = bottomY - CGFloat(indexFromBottom) * lineHeight
            if baseY < -lineHeight || baseY > size.height + lineHeight { continue }

            // Distance from horizontal equator, normalized to −1…1.
            let dy = (baseY - halfH) / halfH
            // Radial pinch — as we approach the pole, lines get pulled toward
            // the vertical centreline. This is what breaks the illusion of a flat
            // text overlay and makes it feel wrapped around a curved surface.
            let pinch = 1.0 - Double(dy) * Double(dy) * 0.35

            // Two summed sine waves for the shimmer. Slightly different periods
            // so the pattern doesn't feel mechanical.
            let wave1 = 5.5 * sin(Double(baseY) * 0.055 + t * 0.6)
            let wave2 = 3.2 * sin(Double(baseY) * 0.14 - t * 0.9)
            let dx = CGFloat((wave1 + wave2))
            let baseX = cx + dx

            // Fade lines near the top/bottom clip edges so the text feels enclosed
            // by the sphere rather than hitting a hard boundary.
            let edgeFade = 1.0 - min(1.0, max(0.0, (abs(Double(dy)) - 0.75) * 4.0))

            // Chromatic aberration — offset red and cyan copies before the main.
            drawGlyph(&ctx, text: line, x: baseX - 2.0, y: baseY, scale: pinch,
                      color: Color(hex: 0xFF6188).opacity(0.40 * edgeFade))
            drawGlyph(&ctx, text: line, x: baseX + 2.0, y: baseY, scale: pinch,
                      color: Color(hex: 0x66E0FF).opacity(0.40 * edgeFade))
            drawGlyph(&ctx, text: line, x: baseX,       y: baseY, scale: pinch,
                      color: Color.white.opacity(0.85 * edgeFade))
        }
    }

    /// Draw a single line as a monospaced Text into the canvas, anchored to its
    /// centre so the aberration copies stack cleanly.
    private func drawGlyph(_ ctx: inout GraphicsContext, text: String, x: CGFloat,
                           y: CGFloat, scale: Double, color: Color) {
        let scaled = 11.5 * scale
        let t = Text(text)
            .font(.system(size: CGFloat(scaled), weight: .medium, design: .monospaced))
            .foregroundColor(color)
        ctx.draw(t, at: CGPoint(x: x, y: y), anchor: .center)
    }
}

// MARK: - Ripple rings

/// Wave rings that expand outward from the orb whenever it's speaking or listening.
/// Purely decorative, but they read as "audio going in / out" of the sphere.
private struct RippleRings: View {
    let state: OrbState
    let center: CGPoint
    let orbRadius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let show = (state == .speaking || state == .listening)
            Canvas { ctx, size in
                guard show else { return }
                let period: Double = state == .speaking ? 1.6 : 2.2
                let count = 4
                for i in 0..<count {
                    let phase = t / period + Double(i) / Double(count)
                    let p = phase.truncatingRemainder(dividingBy: 1.0)
                    let r = orbRadius * (1.05 + p * 2.5)
                    let alpha = (1 - p) * 0.55
                    let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    var path = Path()
                    path.addEllipse(in: rect)
                    ctx.stroke(
                        path,
                        with: .color(state.hue.opacity(alpha)),
                        style: StrokeStyle(lineWidth: 1.2 + (1 - p) * 1.4)
                    )
                }
            }
        }
    }
}

// MARK: - Particle field

/// Little motes that drift upward from around the orb, brighter when the agent is
/// actively doing something. Gives the whole scene a sense of energy release.
private struct ParticleField: View {
    let state: OrbState
    let center: CGPoint
    let orbRadius: CGFloat

    private static let particles: [Particle] = (0..<48).map { i in
        // `6364136223846793005` is a well-known LCG multiplier; it easily overflows
        // Int64 for i ≥ 2, so we route through the bit pattern instead of a checked
        // UInt64 cast (which would trap on the wrapped-negative value).
        let mixed = UInt64(truncatingIfNeeded: i) &* 6364136223846793005 &+ 1
        var rng = SeededRNG(seed: mixed)
        return Particle(
            angle: rng.nextUnit() * 2 * .pi,
            radius: 0.5 + rng.nextUnit() * 1.4,
            riseSpeed: 12 + rng.nextUnit() * 26,
            lifetime: 3.4 + rng.nextUnit() * 3.8,
            phase: rng.nextUnit() * 6.28,
            size: 1.0 + rng.nextUnit() * 2.4,
            warm: rng.nextUnit() > 0.5
        )
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let intensity = self.intensity(for: state)
            Canvas { ctx, _ in
                for p in Self.particles {
                    let localT = (t + p.phase).truncatingRemainder(dividingBy: p.lifetime)
                    let progress = localT / p.lifetime
                    let baseR = orbRadius * (1.02 + p.radius * 0.10)
                    let riseY = -CGFloat(progress) * CGFloat(p.riseSpeed) * 3
                    let sway = sin(t * 1.3 + p.phase) * 8
                    let x = center.x + cos(p.angle) * baseR + sway
                    let y = center.y + sin(p.angle) * baseR * 0.55 + riseY
                    let alpha = (1 - progress) * intensity * 0.75
                    let color: Color = p.warm ? state.accent : state.hue
                    let size = p.size * (1 + progress * 0.6)
                    let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                    // Soft glow around each mote.
                    let glow = CGRect(x: x - size, y: y - size, width: size * 2, height: size * 2)
                    ctx.fill(Path(ellipseIn: glow), with: .color(color.opacity(alpha * 0.2)))
                }
            }
        }
    }

    private func intensity(for state: OrbState) -> Double {
        switch state {
        case .idle: return 0.35
        case .listening: return 0.7
        case .thinking, .interpreting: return 1.0
        case .speaking: return 0.85
        }
    }

    private struct Particle {
        let angle: Double
        let radius: Double
        let riseSpeed: Double
        let lifetime: Double
        let phase: Double
        let size: Double
        let warm: Bool
    }
}

// MARK: - HUD

/// Ambient corner readouts — session model, tool tally, current state code, an
/// energy bar. All decorative, all soft, so they don't compete with the orb.
private struct HUDLayer: View {
    @ObservedObject var session: ClaudeChatSession
    let state: OrbState

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                topRight
            }
            Spacer()
            HStack(alignment: .bottom) {
                bottomLeft
                Spacer()
                bottomRight
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 60)
        .padding(.bottom, 20)
        .foregroundStyle(Color.white.opacity(0.6))
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    private var topRight: some View {
        VStack(alignment: .trailing, spacing: 6) {
            hudLine(k: "MODE", v: state.description.uppercased())
            hudLine(k: "TURNS", v: "\(turnCount)")
            if let sid = session.sessionId {
                hudLine(k: "SESSION", v: String(sid.prefix(6)).uppercased())
            }
        }
    }

    private var bottomLeft: some View {
        VStack(alignment: .leading, spacing: 6) {
            hudLine(k: "ACTIONS", v: "\(actionCount)")
            hudLine(k: "PROJECT", v: session.project.name)
        }
    }

    private var bottomRight: some View {
        VStack(alignment: .trailing, spacing: 6) {
            EnergyMeter(state: state)
                .frame(width: 120, height: 12)
            HStack(spacing: 4) {
                Text("ENERGY")
                    .tracking(1.2)
            }
        }
    }

    private var turnCount: Int {
        session.timeline.reduce(0) { count, item in
            if case .userText = item.kind { return count + 1 }
            return count
        }
    }

    private var actionCount: Int {
        session.timeline.reduce(0) { count, item in
            if case .action = item.kind { return count + 1 }
            return count
        }
    }

    private func hudLine(k: String, v: String) -> some View {
        HStack(spacing: 6) {
            Text(k)
                .tracking(1.6)
                .foregroundStyle(Color.white.opacity(0.35))
            Text(v)
                .foregroundStyle(state.accent)
                .shadow(color: state.hue.opacity(0.7), radius: 4)
        }
    }
}

/// Horizontal bar that swells and pulses with the current state — reads like a
/// health bar in a video game.
private struct EnergyMeter: View {
    let state: OrbState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = self.level(t: t)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [state.accent, state.hue],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: g.size.width * level)
                        .shadow(color: state.hue, radius: 6)
                }
            }
        }
    }

    private func level(t: Double) -> CGFloat {
        let base: Double
        switch state {
        case .idle: base = 0.30
        case .listening: base = 0.72
        case .thinking: base = 0.92
        case .interpreting: base = 0.85
        case .speaking: base = 0.78
        }
        let jitter = 0.06 * sin(t * 3.1)
        return CGFloat(min(1.0, max(0.0, base + jitter)))
    }
}

// MARK: - Vignette

private struct VignetteOverlay: View {
    var body: some View {
        RadialGradient(
            gradient: Gradient(colors: [.clear, .clear, Color.black.opacity(0.55)]),
            center: .center,
            startRadius: 220,
            endRadius: 700
        )
        .ignoresSafeArea()
        .blendMode(.multiply)
    }
}

// MARK: - Orbit speed helper

private extension OrbState {
    var orbitSpeed: Double {
        switch self {
        case .idle:         return 0.10
        case .listening:    return 0.16
        case .thinking:     return 0.38
        case .interpreting: return 0.32
        case .speaking:     return 0.20
        }
    }
}

// MARK: - Skyward crawl

/// One beat of narration in the crawl. Immutable — its position is derived from age
/// each frame, so the crawl doesn't need to mutate its entries after adding.
struct CrawlBeat: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var spawnedAt: Date
    let kind: Kind

    enum Kind: Equatable {
        case live       // short tool-fired beat ("Reading X.swift")
        case streaming  // Claude's own reply text, streamed sentence-by-sentence
        case narration  // final interpreter reply — bigger, lingers longer
    }
}

/// One unified text region under the sphere. New beats appear at the bottom (large
/// and bright), then rise upward, shrinking and fading as they approach the sphere.
/// Positions are deterministic functions of (now − spawnedAt), so we don't animate
/// individual view properties — we just re-render each frame under a TimelineView.
///
/// A fixed rise rate (`riseRate`) combined with the addCrawlBeat throttle guarantees
/// vertical spacing between beats — no more piling up on top of each other.
private struct SkywardCrawl: View {
    let beats: [CrawlBeat]
    /// Optional "in-flight" text at the very bottom (partial mic transcript, current
    /// tool title, etc). It doesn't age — it stays anchored at the bottom until the
    /// state changes.
    let liveText: String?
    /// Bottom edge of the crawl area — beats spawn here.
    let bottomY: CGFloat
    /// Top edge — beats fade out fully before crossing this Y (the sphere lives above).
    let topY: CGFloat
    let centerX: CGFloat
    let state: OrbState

    /// Points per second the beats rise. Slower now so text lingers long enough to
    /// read fully. Combined with the addCrawlBeat throttle, consecutive beats are
    /// still guaranteed ~30 pt of vertical spacing.
    private let riseRate: CGFloat = 34

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let now = context.date
            let travelDistance = bottomY - topY
            ZStack {
                ForEach(beats) { beat in
                    let age = now.timeIntervalSince(beat.spawnedAt)
                    let y = bottomY - CGFloat(age) * riseRate
                    // Once a beat has climbed past the top edge, drop it out entirely.
                    if y > topY - 40 {
                        let travelled = bottomY - y            // 0 at spawn, grows
                        let progress = travelled / max(1, travelDistance)
                        let scale = 1.0 - min(0.30, progress * 0.30)
                        crawlText(beat, isLive: false)
                            .opacity(opacity(age: age, y: y))
                            .scaleEffect(scale, anchor: .bottom)
                            .frame(maxWidth: 560)
                            .position(x: centerX, y: y)
                    }
                }
                if let live = liveText, !live.isEmpty {
                    liveView(text: live)
                        .frame(maxWidth: 560)
                        .position(x: centerX, y: bottomY)
                        .transition(.opacity)
                }
            }
            .compositingGroup()
        }
        .animation(.easeInOut(duration: 0.22), value: liveText)
    }

    /// Fade in over the first 0.5 s, then hold at full opacity through most of the
    /// travel, and fade out slowly over the LAST ~280 pt before reaching the top.
    /// The long fade zone is what makes the crawl feel like it's dissolving into
    /// space rather than being abruptly clipped.
    private func opacity(age: Double, y: CGFloat) -> Double {
        let fadeIn: Double = 0.5
        let intro = age < fadeIn ? age / fadeIn : 1.0
        let fadeOutRegion: CGFloat = 280
        let fadeOutStart = topY + fadeOutRegion
        if y > fadeOutStart { return intro }
        let outProgress = (fadeOutStart - y) / fadeOutRegion
        return intro * max(0, 1 - Double(outProgress))
    }

    @ViewBuilder
    private func crawlText(_ beat: CrawlBeat, isLive: Bool) -> some View {
        // No panels or borders around beats — just text with strong drop-shadows
        // for contrast. The shadows are what make the text legible over the busy
        // starfield/nebula backdrop.
        switch beat.kind {
        case .live:
            HStack(spacing: 8) {
                Circle()
                    .fill(state.hue)
                    .frame(width: 5, height: 5)
                    .shadow(color: state.hue, radius: 4)
                Text(beat.text)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .tracking(0.6)
                    .textCase(.uppercase)
            }
            .shadow(color: .black.opacity(0.9), radius: 6)
            .padding(.horizontal, 12)
        case .streaming:
            Text(beat.text)
                .font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .shadow(color: .black.opacity(0.95), radius: 8)
                .shadow(color: .black.opacity(0.75), radius: 3)
                .padding(.horizontal, 18)
        case .narration:
            VStack(spacing: 8) {
                Rectangle()
                    .fill(state.accent)
                    .frame(width: 42, height: 1.2)
                    .shadow(color: state.accent, radius: 4)
                Text(beat.text)
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .shadow(color: .black.opacity(0.95), radius: 10)
                    .shadow(color: state.hue.opacity(0.4), radius: 14)
            }
            .padding(.horizontal, 20)
        }
    }

    /// Live in-flight text at the bottom edge. No box — just heavy text-shadow so
    /// it reads over anything behind it.
    @ViewBuilder
    private func liveView(text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .medium, design: .serif))
            .foregroundStyle(Color.white)
            .italic(text.hasSuffix("…"))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .shadow(color: .black.opacity(0.95), radius: 10)
            .shadow(color: state.hue.opacity(0.5), radius: 12)
            .padding(.horizontal, 20)
            .frame(maxWidth: 620)
    }
}

// MARK: - State chip

/// Small pill directly under the sphere showing the current OrbState. Replaces the
/// old block caption — the caption text now lives in the crawl instead.
private struct StateChip: View {
    let state: OrbState

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.hue)
                .frame(width: 5, height: 5)
                .shadow(color: state.hue, radius: 5)
            Text(state.description)
                .font(.system(size: 10, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(state.hue.opacity(0.95))
                .textCase(.uppercase)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(state.hue.opacity(0.4), lineWidth: 0.6)
                )
        )
    }
}

// MARK: - Processing ring

/// A segmented arc that spins around the orb during thinking / interpreting states.
/// Reads instantly as "the machine is working." The ring is drawn via Canvas so we
/// can taper individual dashes for a proper "chasing light" pattern.
private struct ProcessingRing: View {
    let state: OrbState
    let center: CGPoint
    let orbRadius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let visible = (state == .thinking || state == .interpreting)
            let ringR = orbRadius * 1.32

            Canvas { ctx, _ in
                guard visible else { return }
                let rotation = t * (state == .thinking ? 1.6 : 1.2)
                let dashes = 42
                for i in 0..<dashes {
                    let base = Double(i) / Double(dashes) * (2 * .pi)
                    let angle = base
                    // Bright ridge that sweeps around — the "chase" band.
                    let ridge = (base - rotation).truncatingRemainder(dividingBy: 2 * .pi)
                    let ridgeNorm = ridge < 0 ? ridge + 2 * .pi : ridge
                    // Convert to 0..1 distance from the ridge head.
                    let d = ridgeNorm / (2 * .pi)
                    let brightness = pow(1 - d, 3.5)      // sharp fall-off
                    let alpha = 0.12 + brightness * 0.85

                    let x = center.x + cos(angle) * ringR
                    let y = center.y + sin(angle) * ringR
                    let dashLen: CGFloat = 6 + CGFloat(brightness) * 4
                    let dashW: CGFloat = 1.6 + CGFloat(brightness) * 1.8

                    // Draw a small arc dash — rotated to tangent.
                    let tangent = angle + .pi / 2
                    let x1 = x - cos(tangent) * dashLen / 2
                    let y1 = y - sin(tangent) * dashLen / 2
                    let x2 = x + cos(tangent) * dashLen / 2
                    let y2 = y + sin(tangent) * dashLen / 2

                    var p = Path()
                    p.move(to: CGPoint(x: x1, y: y1))
                    p.addLine(to: CGPoint(x: x2, y: y2))
                    ctx.stroke(
                        p,
                        with: .color(state.accent.opacity(alpha)),
                        style: StrokeStyle(lineWidth: dashW, lineCap: .round)
                    )
                }

                // Add an inner counter-rotating faint ring for depth.
                let innerR = orbRadius * 1.18
                let innerDashes = 60
                let innerRotation = -t * 0.9
                for i in 0..<innerDashes {
                    let base = Double(i) / Double(innerDashes) * (2 * .pi)
                    let ridge = (base - innerRotation).truncatingRemainder(dividingBy: 2 * .pi)
                    let ridgeNorm = ridge < 0 ? ridge + 2 * .pi : ridge
                    let d = ridgeNorm / (2 * .pi)
                    let brightness = pow(1 - d, 5.0)
                    let alpha = 0.05 + brightness * 0.35
                    let x = center.x + cos(base) * innerR
                    let y = center.y + sin(base) * innerR
                    let dot = CGRect(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8)
                    ctx.fill(Path(ellipseIn: dot), with: .color(state.hue.opacity(alpha)))
                }
            }
        }
    }
}

// MARK: - Subagent field

/// Renders each active sub-agent from `session.subagents` as a small sphere that
/// pops outward from the centre of the main orb on spawn, orbits at a distance
/// while running, then dissolves back into the main sphere on completion.
private struct SubagentField: View {
    let subagents: [ClaudeChatSession.SubagentState]
    let center: CGPoint
    let orbRadius: CGFloat
    let state: OrbState

    /// Small palette used to give concurrent sub-agents visually distinct hues.
    private static let palette: [Color] = [
        Color(hex: 0xE5A25A), // amber
        Color(hex: 0xA680E5), // purple
        Color(hex: 0x64D9AF), // aurora green
        Color(hex: 0x5AC8E5), // cyan
        Color(hex: 0xE85A9B)  // pink
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { context in
            let now = context.date
            let t = now.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(subagents.enumerated()), id: \.element.id) { idx, sub in
                    let age = now.timeIntervalSince(sub.startedAt)
                    // Spring-out animation: from centre to orbit radius over 0.6 s.
                    let spawnT = min(1.0, age / 0.6)
                    let orbitR = orbRadius * 0.20 + (orbRadius * 1.70 - orbRadius * 0.20) * easeOutBack(spawnT)
                    // Orbit angle drifts, and each sub-agent has a different phase.
                    let phase = Double(idx) * (2 * .pi / Double(max(subagents.count, 1)))
                    let angle = phase + t * 0.55
                    // Fade in during spawn, fade out after completion.
                    let opacity: Double = {
                        if let done = sub.completedAt {
                            let doneAge = now.timeIntervalSince(done)
                            return max(0, 1 - doneAge / 1.8)
                        }
                        return min(1, age / 0.4)
                    }()
                    // Reel back toward the parent orb while dissolving.
                    let reelR: CGFloat = {
                        guard let done = sub.completedAt else { return orbitR }
                        let doneAge = now.timeIntervalSince(done)
                        let f = CGFloat(min(1, doneAge / 1.8))
                        return orbitR * (1 - f) + orbRadius * 0.30 * f
                    }()

                    let x = center.x + cos(angle) * reelR
                    let y = center.y + sin(angle) * reelR
                    let subR = orbRadius * 0.16 + orbRadius * 0.03 * CGFloat(sin(t * 3 + phase))
                    let hue = Self.palette[sub.hueSeed % Self.palette.count]

                    SubagentSphere(size: subR * 2, hue: hue, status: sub.status, t: t)
                        .opacity(opacity)
                        .position(x: x, y: y)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subagents.isEmpty ? "" : "\(subagents.count) sub-agent\(subagents.count == 1 ? "" : "s") running")
    }

    /// Easing that overshoots slightly at the end — reads as a "pop" rather than a
    /// smooth glide, so the birth of each subagent has weight.
    private func easeOutBack(_ x: Double) -> CGFloat {
        let c1 = 1.70158
        let c3 = c1 + 1
        let n = x - 1
        return CGFloat(1 + c3 * n * n * n + c1 * n * n)
    }
}

/// A miniature version of the main orb — plasma-lit sphere with its own halo. Tints
/// red once the sub-agent has completed with an error.
private struct SubagentSphere: View {
    let size: CGFloat
    let hue: Color
    let status: ClaudeChatSession.SubagentState.Status
    let t: Double

    var body: some View {
        let tint: Color = {
            switch status {
            case .running: return hue
            case .success: return hue
            case .error:   return DiffLine.removedRed
            }
        }()
        ZStack {
            // Outer glow.
            Circle()
                .fill(tint)
                .frame(width: size * 2.4, height: size * 2.4)
                .blur(radius: 22)
                .opacity(0.5)

            // Sphere body — same recipe as the main orb but simplified.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.9),
                            tint.opacity(0.85),
                            tint.opacity(0.4),
                            Color.black.opacity(0.75)
                        ],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 1,
                        endRadius: size * 0.7
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
                )
                .shadow(color: tint.opacity(0.7), radius: 12)

            // Running pulse — a subtle expanding ring while working.
            if status == .running {
                Circle()
                    .stroke(tint.opacity(0.8 * (1 - pulse)), lineWidth: 1)
                    .frame(width: size * (1 + pulse * 0.9),
                           height: size * (1 + pulse * 0.9))
            }
        }
    }

    private var pulse: CGFloat {
        let period = 1.4
        let cycle = t.truncatingRemainder(dividingBy: period) / period
        return CGFloat(cycle)
    }
}

// MARK: - Todo panel

/// A floating checklist showing Claude's live plan (from the TodoWrite tool). Docks
/// on the right side of the screen. Empty state hides the panel entirely.
private struct TodoPanel: View {
    let todos: [TodoEntry]
    let state: OrbState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.hue)
                    .frame(width: 4, height: 4)
                    .shadow(color: state.hue, radius: 4)
                Text("PLAN")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer(minLength: 0)
                Text("\(doneCount)/\(todos.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.accent)
            }
            ForEach(Array(todos.prefix(8).enumerated()), id: \.offset) { _, todo in
                row(todo)
            }
            if todos.count > 8 {
                Text("+ \(todos.count - 8) more…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                )
        )
        .shadow(color: .black.opacity(0.6), radius: 16, y: 4)
    }

    private func row(_ todo: TodoEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch todo.status {
                case "completed":
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(state.accent)
                case "in_progress":
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(state.hue)
                default:
                    Image(systemName: "circle")
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: 14, alignment: .top)
            .padding(.top, 2)

            Text(todo.content)
                .font(.system(size: 12, weight: todo.status == "in_progress" ? .semibold : .regular))
                .foregroundStyle(
                    todo.status == "completed"
                        ? Color.white.opacity(0.5)
                        : Color.white.opacity(0.9)
                )
                .strikethrough(todo.status == "completed", color: Color.white.opacity(0.35))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var doneCount: Int {
        todos.filter { $0.status == "completed" }.count
    }
}

// MARK: - Monitor panel

/// A little terminal-styled panel showing the latest Bash tool: the command that
/// ran, and the head/tail of its output. Docks on the left side of the screen.
private struct MonitorPanel: View {
    let event: ActionEvent
    let state: OrbState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 4, height: 4)
                    .shadow(color: dotColor, radius: 4)
                Text("MONITOR")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer(minLength: 0)
                Text(statusLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(dotColor)
            }
            if let cmd = event.command?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                Text("$ " + cmd)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.accent)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(outputPreview)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(6)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                )
        )
        .shadow(color: .black.opacity(0.6), radius: 16, y: 4)
    }

    private var statusLabel: String {
        switch event.status {
        case .running: return "RUNNING"
        case .success: return event.isError ? "ERROR" : "OK"
        case .error:   return "ERROR"
        }
    }

    private var dotColor: Color {
        switch event.status {
        case .running: return state.hue
        case .success: return event.isError ? DiffLine.removedRed : state.accent
        case .error:   return DiffLine.removedRed
        }
    }

    /// Show the tail of the output — that's where the interesting bit usually is.
    /// Fall back to a short placeholder if the tool hasn't produced anything yet.
    private var outputPreview: String {
        let out = event.result.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return event.status == .running ? "…" : "(no output)" }
        let lines = out.split(separator: "\n").map(String.init)
        let tail = lines.suffix(6).joined(separator: "\n")
        return tail
    }
}

// MARK: - Tiny seeded PRNG

/// A splitmix64-style PRNG. Used to place stars and particles deterministically so
/// their layout is stable across frames without paying Random's overhead per draw.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func nextUnit() -> Double {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}
