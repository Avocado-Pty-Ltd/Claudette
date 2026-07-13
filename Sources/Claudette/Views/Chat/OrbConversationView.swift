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
            // Central sphere. Diameter capped at 380pt to match the Ember-family
            // "Observatory" design spec (340pt at 720pt canvas height, +10% for
            // larger windows). Previously topped out at 520pt which read as
            // over-scale — the design intent is that the orb sits inside a
            // starfield with orbital rings visible around it, not that it
            // dominates the screen.
            let side = min(geo.size.width, geo.size.height)
            let orbRadius = min(side * 0.24, 190)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.40)
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
                    // Explicit hit target — the sphere content lives inside a
                    // GeometryReader and its visible pixels don't reach the
                    // frame edges (soft halos, transparent corners). Without
                    // this, .gesture and .focusable would only fire on the
                    // visibly-painted parts and press-to-talk feels dead in
                    // large swaths of what looks like the orb.
                    .contentShape(Rectangle())
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

    // Observatory spec: linear-gradient(180deg, #02030A 0%, #090612 55%, #0E0A18 100%).
    // The state tint isn't in the backdrop — it rides the nebulae. Previously
    // this view added a state-hued radial gradient over the top; that made the
    // whole scene shift colour on every state change, which is louder than the
    // spec intends.
    var body: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color(hex: 0x02030A), location: 0.00),
                .init(color: Color(hex: 0x090612), location: 0.55),
                .init(color: Color(hex: 0x0E0A18), location: 1.00)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
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
        // Observatory spec: exactly two nebulae.
        //   Left/top:   520×520 at left:24% top:14%, background = state.hue,
        //               opacity .13, blur 90, drift1 26s
        //   Right/mid:  420×420 at right:8% top:34%, background = #6B3EAE,
        //               opacity .10, blur 90, drift2 32s
        // The state hue rides the left nebula; the amethyst on the right is
        // fixed so the scene keeps a compositional anchor across states.
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                // drift1: 120px right, 40px up
                let dx1 = 120 * sin(t * (2 * .pi / 26))
                let dy1 = -40 * sin(t * (2 * .pi / 26))
                // drift2: 100px left, 50px down
                let dx2 = -100 * sin(t * (2 * .pi / 32))
                let dy2 =  50 * sin(t * (2 * .pi / 32))

                ZStack(alignment: .topLeading) {
                    Circle()
                        .fill(state.hue)
                        .frame(width: 520, height: 520)
                        .blur(radius: 90)
                        .opacity(0.13)
                        .offset(x: w * 0.24 + CGFloat(dx1), y: h * 0.14 + CGFloat(dy1))
                        .animation(.easeInOut(duration: 1.2), value: state)
                    Circle()
                        .fill(Color(hex: 0x6B3EAE))
                        .frame(width: 420, height: 420)
                        .blur(radius: 90)
                        .opacity(0.10)
                        .offset(x: w * 0.92 - CGFloat(420) + CGFloat(dx2), y: h * 0.34 + CGFloat(dy2))
                }
            }
            .allowsHitTesting(false)
        }
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
        // Observatory spec: two subtle plain rings at −9° and −4°, sized as
        // fractions of the design canvas (860×300 and 1080×420 within 1180×720),
        // with only a very faint white stroke — no chase arcs, no motion.
        // Motion comes from the nebulae + processing ring + sub-agents; the
        // orbital planes are just "here's where things travel".
        ZStack {
            Ellipse()
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                .frame(width: radius * 4.30, height: radius * 1.50)
                .rotationEffect(.degrees(-9))
            Ellipse()
                .stroke(Color.white.opacity(0.045), lineWidth: 1)
                .frame(width: radius * 5.40, height: radius * 2.10)
                .rotationEffect(.degrees(-4))
        }
        .position(center)
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
        // Layer stack tightened to the Observatory spec:
        //   1. Nebula halo behind the sphere (soft hue bleed).
        //   2. Sphere body — single radial gradient (accent → hue → dark → black).
        //   3. Refraction log inside (masked to inner disk).
        //   4. Top-left specular highlight (radial white, screen blend).
        //   5. Bottom-right deep shadow (radial black).
        //   6. Rim highlight (thin white inset ring at top).
        //   7. Central bright core (30pt white blur).
        //
        // Notes on what was removed vs the previous implementation: plasma
        // blobs, extra pulsing halos, warm-glow bleed, sub-halo ring, and the
        // dilating iris. The design carries all its life through the nebulae,
        // ripples, processing ring, and sub-agents around the orb — not
        // inside it.
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathing = 1.0 + 0.028 * sin(t * (2 * .pi / 5.2))  // breathe 5.2s

            GeometryReader { g in
                let s = min(g.size.width, g.size.height)
                ZStack {
                    // ── 1. Nebula halo — soft hue bleed behind the sphere ─
                    // Design's `radial-gradient(circle, hue 0%, transparent 62%)`
                    // with opacity .22 and blur 50px, on a 560px canvas
                    // vs 340px orb (≈ 1.65× overscan).
                    Circle()
                        .fill(state.hue)
                        .frame(width: s * 1.65, height: s * 1.65)
                        .opacity(0.22)
                        .blur(radius: 50)

                    // ── 2. Sphere body + interior log ─────────────────────
                    ZStack {
                        // Base fill — spec's radial gradient at (34%, 28%):
                        // accent 0% → hue 38% → #140A10 78% → #05030A 100%.
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        state.accent,
                                        state.hue,
                                        Color(hex: 0x140A10),
                                        Color(hex: 0x05030A)
                                    ],
                                    center: UnitPoint(x: 0.34, y: 0.28),
                                    startRadius: 0,
                                    endRadius: s * 0.62
                                )
                            )

                        // Refracted CLI log — masked to inner disk so the
                        // text doesn't touch the sphere edge. Design mask:
                        // radial(circle, #000 55%, transparent 78%).
                        RefractionText(rawLog: rawLog, state: state)
                            .frame(width: s, height: s)
                            .mask(
                                RadialGradient(
                                    colors: [.black, .black, .clear],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: s * 0.42
                                )
                            )
                            .opacity(0.85)
                            .blendMode(.screen)
                    }
                    .frame(width: s, height: s)
                    .clipShape(Circle())
                    .overlay(
                        // ── 3. Specular highlight top-left ─────────────
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.white.opacity(0.75),
                                        .clear
                                    ],
                                    center: UnitPoint(x: 0.33, y: 0.27),
                                    startRadius: 0,
                                    endRadius: s * 0.30
                                )
                            )
                            .blendMode(.screen)
                    )
                    .overlay(
                        // ── 4. Deep shadow bottom-right ─────────────────
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        .clear,
                                        Color.black.opacity(0.65)
                                    ],
                                    center: UnitPoint(x: 0.72, y: 0.80),
                                    startRadius: s * 0.40,
                                    endRadius: s * 0.80
                                )
                            )
                    )
                    .overlay(
                        // ── 5. Thin rim highlight ──────────────────────
                        // Design uses `box-shadow: inset 0 1.5px 0 rgba(255,255,255,.4)`.
                        // A stroked circle with a linear top-heavy gradient
                        // approximates the highlight at the very top edge.
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.40),
                                        .clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1.5
                            )
                    )

                    // ── 6. Central bright core ────────────────────────────
                    // Design: 30×30 rgba(255,255,255,.7) with blur(9px).
                    // At 340pt canvas that's ≈8.8% of diameter.
                    Circle()
                        .fill(Color.white.opacity(0.70))
                        .frame(width: s * 0.088, height: s * 0.088)
                        .blur(radius: s * 0.026)
                }
                .frame(width: s, height: s)
                .scaleEffect(isPressing ? 0.94 : breathing)
                .animation(.easeInOut(duration: 0.18), value: isPressing)
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.6), radius: s * 0.26, x: 0, y: 0)
            }
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

    /// Single-line HUD strip in the bottom-left, matching the Observatory
    /// design's `ACTIONS 359 · PROJECT EZYBIZ` treatment. Nothing sits in the
    /// bottom-right corner in the spec.
    private var bottomLeft: some View {
        HStack(spacing: 8) {
            hudLine(k: "ACTIONS", v: "\(actionCount)")
            Text("·")
                .foregroundStyle(Color.white.opacity(0.30))
            hudLine(k: "PROJECT", v: session.project.name.uppercased())
        }
    }

    private var bottomRight: some View { EmptyView() }

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
    // Observatory spec:
    //   radial-gradient(ellipse at 50% 42%, transparent 55%, rgba(0,0,0,.5) 100%)
    // SwiftUI has no ellipse-shaped RadialGradient, so we approximate with a
    // circular gradient centred slightly above centre and let the multiply
    // blend do the darkening. The 42% Y anchor matches the spec exactly.
    var body: some View {
        GeometryReader { geo in
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .clear, location: 0.55),
                    .init(color: Color.black.opacity(0.5), location: 1.00)
                ]),
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0,
                endRadius: max(geo.size.width, geo.size.height) * 0.65
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
        // Observatory spec: italic serif @ 19px, hue-tinted glow (22px shadow at
        // 45% alpha) layered under a hard black drop shadow. This is the
        // "current beat" — the thing being said right now, and the design uses
        // it as the anchor of the bottom-centre.
        Text(text)
            .font(.system(size: 19, weight: .medium, design: .serif))
            .italic()
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .shadow(color: .black.opacity(0.95), radius: 12, x: 0, y: 2)
            .shadow(color: state.hue.opacity(0.45), radius: 22)
            .padding(.horizontal, 20)
            .frame(maxWidth: 640)
    }
}

// MARK: - State chip

/// Small pill directly under the sphere showing the current OrbState. Replaces the
/// old block caption — the caption text now lives in the crawl instead.
private struct StateChip: View {
    let state: OrbState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.hue)
                .frame(width: 5, height: 5)
                .shadow(color: state.hue, radius: 5)
            Text(state.description)
                // Design uses IBM Plex Mono @ 10px; system monospaced is close
                // enough to the metrics and available without bundling a font.
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.4)  // letter-spacing:.24em
                .foregroundStyle(state.hue.opacity(0.95))
                .textCase(.uppercase)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.40))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(state.hue.opacity(0.45), lineWidth: 1)
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
        // Observatory spec:
        //   conic-gradient(from 0deg, transparent 0-62%, accent 92%, transparent 100%)
        //   masked to a thin band via
        //   radial-gradient(circle, transparent 66%, #000 67-69%, transparent 70%)
        //   spinning CW at 2.8s per revolution.
        // Only visible during thinking / interpreting.
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let visible = (state == .thinking || state == .interpreting)
            let ringD = orbRadius * 2.6   // canvas 440 vs orb 340 → 1.294; scaled up here for balance
            let rotation = Angle.radians(t * (2 * .pi / 2.8))

            AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear,       location: 0.00),
                    .init(color: .clear,       location: 0.62),
                    .init(color: state.accent, location: 0.92),
                    .init(color: .clear,       location: 1.00)
                ]),
                center: .center
            )
            .frame(width: ringD, height: ringD)
            .mask(
                Circle()
                    .stroke(Color.black, lineWidth: ringD * 0.03)
                    .frame(width: ringD * 0.68, height: ringD * 0.68)
            )
            .rotationEffect(rotation)
            .position(center)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.8), value: visible)
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

    /// Observatory spec has two sub-agents visible in the thinking state:
    ///   • Amethyst — 46px, orbit at ~1.75× orbRadius, spinning CW at 11s.
    ///   • Green    — 36px, orbit at ~2.08× orbRadius, spinning CCW at 15s.
    ///
    /// Rather than hard-coding two decorative slots, we use these two orbits
    /// as slots for the FIRST two live sub-agents from `session.subagents`.
    /// Sub-agents past the second get cycled through the same slots so the
    /// scene still reads as design intent when work is exceptionally busy.
    private struct OrbitSlot {
        let radius: CGFloat       // multiplier of orbRadius
        let sizeFrac: CGFloat     // multiplier of orbRadius diameter
        let period: Double        // seconds per revolution; negative = CCW
        let startAngle: Double    // radians
        let highlight: Color
        let body: Color
        let deep: Color
    }
    private static let slots: [OrbitSlot] = [
        // Amethyst — atan2(-14, 298) starting angle
        OrbitSlot(
            radius: 1.75, sizeFrac: 0.135, period: 11,
            startAngle: atan2(-14.0, 298.0),
            highlight: Color(hex: 0xEDE0FF),
            body: Color(hex: 0xA680E5),
            deep: Color(hex: 0x241536)
        ),
        // Green — atan2(40, -352) starting angle (roughly π)
        OrbitSlot(
            radius: 2.08, sizeFrac: 0.106, period: -15,
            startAngle: atan2(40.0, -352.0),
            highlight: Color(hex: 0xD9FFF0),
            body: Color(hex: 0x64D9AF),
            deep: Color(hex: 0x10321F)
        )
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { context in
            let now = context.date
            let t = now.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(subagents.enumerated()), id: \.element.id) { idx, sub in
                    let slot = Self.slots[idx % Self.slots.count]
                    // Angle drifts at the slot's period (positive = CW).
                    let angle = slot.startAngle + t * (2 * .pi / slot.period)
                    let orbitR = orbRadius * slot.radius
                    let x = center.x + cos(angle) * orbitR
                    let y = center.y + sin(angle) * orbitR
                    let diameter = orbRadius * 2 * slot.sizeFrac
                    // Opacity: fade in over 0.4s on spawn, fade out over 1.8s on
                    // completion. Nothing else — the design shows subagents at
                    // full presence, not springing in.
                    let opacity: Double = {
                        if let done = sub.completedAt {
                            let doneAge = now.timeIntervalSince(done)
                            return max(0, 1 - doneAge / 1.8)
                        }
                        let age = now.timeIntervalSince(sub.startedAt)
                        return min(1, age / 0.4)
                    }()

                    SubagentSphere(
                        size: diameter,
                        highlight: slot.highlight,
                        bodyColor: slot.body,
                        deep: slot.deep,
                        status: sub.status
                    )
                    .opacity(opacity)
                    .position(x: x, y: y)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subagents.isEmpty ? "" : "\(subagents.count) sub-agent\(subagents.count == 1 ? "" : "s") running")
    }
}

/// Miniature version of the main orb — matches Observatory spec:
///   background: radial-gradient(circle at 35% 30%, highlight, body 55%, deep 92%)
///   box-shadow: 0 0 26–30px rgba(body,.55–.60)
///
/// Both design sub-agents share this recipe; the palette (highlight / body /
/// deep) is chosen by the parent based on which orbit slot the sub-agent is
/// filling.
private struct SubagentSphere: View {
    let size: CGFloat
    let highlight: Color
    let bodyColor: Color
    let deep: Color
    let status: ClaudeChatSession.SubagentState.Status

    var body: some View {
        // On error we tint the body layer red so the sphere reads as failed
        // without dropping the highlight/deep sandwich from the design.
        let effectiveBody = status == .error ? DiffLine.removedRed : bodyColor
        let effectiveDeep = status == .error
            ? DiffLine.removedRed.opacity(0.35)
            : deep

        ZStack {
            // Outer amethyst/green glow (design box-shadow).
            Circle()
                .fill(effectiveBody)
                .frame(width: size * 1.7, height: size * 1.7)
                .blur(radius: size * 0.45)
                .opacity(0.55)

            // Sphere body — radial gradient centred at (35%, 30%) inside.
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: highlight,       location: 0.00),
                            .init(color: effectiveBody,   location: 0.55),
                            .init(color: effectiveDeep,   location: 0.92)
                        ]),
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0,
                        endRadius: size * 0.6
                    )
                )
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Todo panel

/// A floating checklist showing Claude's live plan (from the TodoWrite tool). Docks
/// on the right side of the screen. Empty state hides the panel entirely.
private struct TodoPanel: View {
    let todos: [TodoEntry]
    let state: OrbState

    var body: some View {
        // Same glass panel as MonitorPanel, matching Observatory spec exactly.
        // Plan rows use 12.5px text (rounded to 13 in SwiftUI): completed items
        // are struck through and dimmed, in-progress is bold, pending is
        // mid-opacity white.
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.hue)
                    .frame(width: 4, height: 4)
                    .shadow(color: state.hue, radius: 6)
                Text("PLAN")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.white.opacity(0.50))
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
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x08060E).opacity(0.6))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
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
        // Observatory spec: rounded-14 glass panel, rgba(8,6,14,.6) fill,
        // rgba(255,255,255,.08) border, backdrop blur 12px. Header uses a 4px
        // hue-glow dot + mono 9px @ .24em tracking label + accent-tinted meta
        // on the right ("OK"). Command line: mono 11px accent. Output: mono
        // 10px white α.55 with line-height 1.6.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 4, height: 4)
                    .shadow(color: dotColor, radius: 6)
                Text("MONITOR")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.white.opacity(0.50))
                Spacer(minLength: 0)
                Text(statusLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(dotColor)
            }
            if let cmd = event.command?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                Text("$ " + cmd)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(state.accent)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(outputPreview)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineSpacing(3)  // ≈ 1.6 line-height on 10px
                .lineLimit(6)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 264, alignment: .leading)
        .background(
            // Design uses backdrop-filter:blur(12px). SwiftUI's .materials
            // (.ultraThinMaterial) is the closest native equivalent — same
            // frosted-glass effect over the scene behind it.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x08060E).opacity(0.6))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
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
