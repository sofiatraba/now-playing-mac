import AppKit
import CoreImage
import SwiftUI

// A small floating card showing what Spotify or Apple Music is playing.

let cardSize = CGSize(width: 340, height: 104)
let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

// MARK: - Talking to the music apps

enum Source: CaseIterable {
    case spotify, music

    var appName: String { self == .spotify ? "Spotify" : "Music" }
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var backCommand: String { self == .spotify ? "previous track" : "back track" }

    // Checked before every script, because AppleScript launches an app that isn't running.
    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    var readScript: String {
        switch self {
        case .spotify:
            return """
            tell application "Spotify"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {player state as string, name of t, artist of t, album of t, (duration of t) / 1000, player position, artwork url of t, id of t}
            end tell
            """
        case .music:
            return """
            tell application "Music"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {player state as string, name of t, artist of t, album of t, duration of t, player position, "", persistent ID of t}
            end tell
            """
        }
    }
}

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var source: Source
    var artworkURL: String?
}

struct Reading {
    var track: Track
    var isPlaying: Bool
    var position: Double
}

enum PollResult {
    case nothing
    case reading(Reading)
    case denied(Source)
}

enum Transport {
    case playPause, next, previous
    case seek(Double)
}

final class PlayerBridge {
    private let queue = DispatchQueue(label: "nowplaying.applescript")
    private var compiled: [Source: NSAppleScript] = [:]
    private var lastSource: Source?
    private var pollInFlight = false

    private enum Outcome {
        case value(NSAppleEventDescriptor)
        case failure(Int)
    }

    private func run(_ script: NSAppleScript) -> Outcome {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { return .failure(error[NSAppleScript.errorNumber] as? Int ?? 0) }
        return .value(result)
    }

    func poll(_ done: @escaping (PollResult) -> Void) {
        guard !pollInFlight else { return }
        pollInFlight = true
        queue.async {
            let result = self.readBestSource()
            DispatchQueue.main.async {
                self.pollInFlight = false
                done(result)
            }
        }
    }

    private func readBestSource() -> PollResult {
        var readings: [Reading] = []
        var denied: Source?

        for source in Source.allCases where source.isRunning {
            let script = compiled[source] ?? NSAppleScript(source: source.readScript)!
            compiled[source] = script
            switch run(script) {
            case .value(let list):
                if let reading = Self.parse(list, source: source) { readings.append(reading) }
            case .failure(let code):
                if code == -1743 { denied = source }
            }
        }

        let chosen = readings.first { $0.isPlaying && $0.track.source == lastSource }
            ?? readings.first { $0.isPlaying }
            ?? readings.first { $0.track.source == lastSource }
            ?? readings.first

        if let chosen {
            lastSource = chosen.track.source
            return .reading(chosen)
        }
        if let denied { return .denied(denied) }
        return .nothing
    }

    private static func parse(_ list: NSAppleEventDescriptor, source: Source) -> Reading? {
        guard list.numberOfItems >= 8,
              let state = list.atIndex(1)?.stringValue,
              let title = list.atIndex(2)?.stringValue, !title.isEmpty,
              let id = list.atIndex(8)?.stringValue
        else { return nil }

        let track = Track(
            id: id,
            title: title,
            artist: list.atIndex(3)?.stringValue ?? "",
            album: list.atIndex(4)?.stringValue ?? "",
            duration: list.atIndex(5)?.doubleValue ?? 0,
            source: source,
            artworkURL: list.atIndex(7)?.stringValue
        )
        return Reading(track: track, isPlaying: state == "playing", position: list.atIndex(6)?.doubleValue ?? 0)
    }

    func send(_ command: Transport, to source: Source, then done: @escaping () -> Void) {
        let body: String
        switch command {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = source.backCommand
        case .seek(let seconds): body = "set player position to \(String(format: "%.2f", seconds))"
        }
        queue.async {
            guard source.isRunning,
                  let script = NSAppleScript(source: "tell application \"\(source.appName)\" to \(body)")
            else { return }
            _ = self.run(script)
            DispatchQueue.main.async(execute: done)
        }
    }

    func loadCover(for track: Track, _ done: @escaping (NSImage?) -> Void) {
        switch track.source {
        case .spotify:
            guard let raw = track.artworkURL, !raw.isEmpty,
                  var parts = URLComponents(string: raw)
            else { return done(nil) }
            parts.scheme = "https"
            guard let url = parts.url else { return done(nil) }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                done(data.flatMap(NSImage.init(data:)))
            }.resume()

        case .music:
            queue.async {
                let source = "tell application \"Music\" to get raw data of artwork 1 of current track"
                guard track.source.isRunning, let script = NSAppleScript(source: source),
                      case .value(let result) = self.run(script)
                else { return done(nil) }
                done(NSImage(data: result.data))
            }
        }
    }
}

// MARK: - Artwork

struct Artwork: Identifiable {
    let id = UUID()
    let cover: NSImage
    let backdrop: NSImage
    let accent: Color
    let shade: Double // How much black goes over the backdrop so white text stays readable.

    private static let context = CIContext(options: [.cacheIntermediates: false])

    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let scale = 160 / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 16])
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.5, "inputBrightness": -0.08])
            .cropped(to: small.extent)
        guard let output = Self.context.createCGImage(blurred, from: blurred.extent) else { return nil }

        cover = image
        backdrop = NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
        let colors = Self.analyze(cg)
        accent = colors.accent
        shade = 0.2 + 0.52 * colors.luminance
    }

    // Finds the cover's average brightness and its most vivid colour, lifted to read on a dark background.
    private static func analyze(_ image: CGImage) -> (accent: Color, luminance: Double) {
        let side = 20
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return (.white, 0.5) }

        var best: (score: CGFloat, hue: CGFloat, saturation: CGFloat) = (0, 0, 0)
        var luminanceTotal = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            luminanceTotal += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
            let color = NSColor(
                srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1
            )
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let score = saturation * saturation * brightness
            if score > best.score { best = (score, hue, saturation) }
        }
        let luminance = luminanceTotal / Double(side * side)
        guard best.saturation > 0.2 else { return (.white, luminance) }
        return (Color(hue: Double(best.hue), saturation: Double(min(best.saturation, 0.6)), brightness: 1), luminance)
    }
}

// MARK: - Model

final class NowPlayingModel: ObservableObject {
    @Published var track: Track?
    @Published var isPlaying = false
    @Published var art: Artwork?
    @Published var hovering = false
    @Published var deniedSource: Source?
    @Published private(set) var anchorPosition = 0.0
    @Published private(set) var anchorDate = Date()

    private let bridge = PlayerBridge()

    var accent: Color { art?.accent ?? .white }

    func position(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(anchorDate) : 0
        let position = anchorPosition + elapsed
        guard let duration = track?.duration, duration > 0 else { return max(position, 0) }
        return min(max(position, 0), duration)
    }

    func setAnchor(_ position: Double) {
        anchorPosition = position
        anchorDate = Date()
    }

    func refresh() {
        bridge.poll { [weak self] result in self?.apply(result) }
    }

    func apply(_ result: PollResult) {
        switch result {
        case .nothing:
            deniedSource = nil
            clearTrack()
        case .denied(let source):
            deniedSource = source
            clearTrack()
        case .reading(let reading):
            deniedSource = nil
            let isNewTrack = track?.id != reading.track.id
            // Small differences are script delay. Re-anchoring on them makes the bar jump backwards.
            let drift = abs(position(at: Date()) - reading.position)
            if isNewTrack || reading.isPlaying != isPlaying || drift > 1.2 {
                setAnchor(reading.position)
            }
            isPlaying = reading.isPlaying
            if isNewTrack {
                withAnimation(.easeInOut(duration: 0.3)) { track = reading.track }
                loadArt(for: reading.track)
            } else if track != reading.track {
                track = reading.track
            }
        }
    }

    private func clearTrack() {
        guard track != nil else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            track = nil
            art = nil
        }
        isPlaying = false
    }

    private func loadArt(for track: Track) {
        bridge.loadCover(for: track) { [weak self] image in
            DispatchQueue.global(qos: .userInitiated).async {
                let artwork = image.flatMap(Artwork.init(image:))
                DispatchQueue.main.async {
                    guard let self, self.track?.id == track.id else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { self.art = artwork }
                }
            }
        }
    }

    private func send(_ command: Transport) {
        guard let source = track?.source else { return }
        bridge.send(command, to: source) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        }
    }

    func togglePlay() {
        setAnchor(position(at: Date()))
        isPlaying.toggle()
        send(.playPause)
    }

    func next() { send(.next) }
    func previous() { send(.previous) }

    func seek(toFraction fraction: Double) {
        guard let duration = track?.duration, duration > 0 else { return }
        let target = fraction * duration
        setAnchor(target)
        send(.seek(target))
    }

    func openPlayer() {
        guard let source = track?.source,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Views

struct CardView: View {
    @ObservedObject var model: NowPlayingModel
    var onDrag: () -> Void = {}
    var onDragEnd: () -> Void = {}

    var body: some View {
        ZStack {
            Backdrop(art: model.art)
            HStack(spacing: 12) {
                Cover(art: model.art)
                    .onTapGesture { model.openPlayer() }
                details
            }
            .padding(12)

            if model.hovering {
                closeButton
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.hovering)
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .contentShape(cardShape)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in onDrag() }
                .onEnded { _ in onDragEnd() }
        )
        .environment(\.colorScheme, .dark)
    }

    private var closeButton: some View {
        Button { NSApp.terminate(nil) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.black.opacity(0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help("Quit Now Playing")
    }

    @ViewBuilder private var details: some View {
        if let track = model.track {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Marquee(text: track.title).id(track.title)
                        Text(subtitle(for: track))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if model.hovering {
                        Controls(model: model).transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else {
                        Equalizer(playing: model.isPlaying, color: model.accent)
                            .padding(.top, 3)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                ProgressRow(model: model)
            }
            .frame(height: 80)
            .animation(.easeOut(duration: 0.18), value: model.hovering)
        } else if let source = model.deniedSource {
            Button {
                let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                NSWorkspace.shared.open(URL(string: url)!)
            } label: {
                message("Allow access to \(source.appName)", "Click to open Automation settings")
            }
            .buttonStyle(.plain)
        } else {
            message("Nothing playing", "Start something in Spotify or Music")
        }
    }

    private func subtitle(for track: Track) -> String {
        [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Backdrop: View {
    let art: Artwork?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.2), Color(white: 0.09)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            if let art {
                Color.clear
                    .overlay(Image(nsImage: art.backdrop).resizable().scaledToFill())
                    .clipped()
                    .id(art.id)
                    .transition(.opacity)
            }
            Color.black.opacity(art?.shade ?? 0.38)
        }
    }
}

struct Cover: View {
    let art: Artwork?
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        ZStack {
            shape.fill(.white.opacity(0.1))
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            if let art {
                Image(nsImage: art.cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(shape)
                    .id(art.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: 80, height: 80)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

// Shows a title on one line, and scrolls it when it doesn't fit.
struct Marquee: View {
    let text: String

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    private let gap: CGFloat = 36
    private let speed: Double = 30
    private let hold: Double = 2.5
    private let height: CGFloat = 20

    private var label: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }

    var body: some View {
        GeometryReader { geometry in
            let overflows = textWidth > geometry.size.width + 0.5
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !overflows)) { context in
                HStack(spacing: gap) {
                    label.onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { textWidth = $0 }
                    if overflows { label }
                }
                .offset(x: overflows ? scrollOffset(at: context.date) : 0)
            }
            .frame(width: geometry.size.width, height: height, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: overflows ? .clear : .black, location: 0),
                        .init(color: .black, location: 0.03),
                        .init(color: .black, location: 0.9),
                        .init(color: overflows ? .clear : .black, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        }
        .frame(height: height)
    }

    private func scrollOffset(at date: Date) -> CGFloat {
        let distance = Double(textWidth + gap)
        let elapsed = date.timeIntervalSince(start).truncatingRemainder(dividingBy: hold + distance / speed)
        return elapsed < hold ? 0 : -CGFloat((elapsed - hold) * speed)
    }
}

struct Equalizer: View {
    let playing: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !playing)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: playing ? barHeight(index, time) : 3)
                }
            }
        }
        .frame(height: 18, alignment: .bottom)
        .animation(.easeOut(duration: 0.25), value: playing)
    }

    private func barHeight(_ index: Int, _ time: Double) -> CGFloat {
        let i = Double(index)
        let fast = 0.5 + 0.5 * sin(time * (5 + i * 1.3) + i * 1.7)
        let slow = 0.7 + 0.3 * sin(time * (2.1 + i * 0.7))
        return CGFloat(3 + 15 * fast * slow)
    }
}

struct Controls: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        HStack(spacing: 2) {
            ControlButton(symbol: "backward.fill", size: 13, action: model.previous)
            ControlButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", size: 17, action: model.togglePlay)
            ControlButton(symbol: "forward.fill", size: 13, action: model.next)
        }
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ProgressRow: View {
    @ObservedObject var model: NowPlayingModel
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = model.track?.duration ?? 0
            let position = scrub.map { $0 * duration } ?? model.position(at: context.date)

            if duration > 0 {
                HStack(spacing: 8) {
                    timeLabel(position)
                    bar(fraction: min(position / duration, 1))
                    timeLabel(duration)
                }
            }
        }
        .frame(height: 14)
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(Self.format(seconds))
            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
    }

    private func bar(fraction: Double) -> some View {
        let thick = model.hovering || scrub != nil
        let thickness: CGFloat = thick ? 5 : 3
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24))
                Capsule()
                    .fill(model.accent)
                    .frame(width: max(thickness, geometry.size.width * fraction))
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrub = min(max($0.location.x / geometry.size.width, 0), 1) }
                    .onEnded { _ in
                        if let scrub { model.seek(toFraction: scrub) }
                        scrub = nil
                    }
            )
        }
        .animation(.easeOut(duration: 0.15), value: thick)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Window

final class HostView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    // Lets a click work straight away, even when another app is in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if area == nil {
            let newArea = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(newArea)
            area = newArea
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === area { onHoverChange?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === area { onHoverChange?(false) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppController: NSObject, NSApplicationDelegate {
    private let model = NowPlayingModel()
    private var panel: FloatingPanel!
    private var timer: Timer?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    private let positionKey = "cardOrigin"
    private let onTopKey = "keepOnTop"

    private var keepOnTop: Bool {
        get { UserDefaults.standard.object(forKey: onTopKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: onTopKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        listenForPlayerChanges()
        installContextMenu()

        model.refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.model.refresh() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func buildPanel() {
        panel = FloatingPanel(
            contentRect: NSRect(origin: savedOrigin() ?? defaultOrigin(), size: cardSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = keepOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let card = CardView(
            model: model,
            onDrag: { [weak self] in self?.dragMoved() },
            onDragEnd: { [weak self] in self?.dragEnded() }
        )
        let host = HostView(rootView: card)
        host.onHoverChange = { [weak self] inside in self?.model.hovering = inside }
        panel.contentView = host
        panel.orderFrontRegardless()

        // The shadow is calculated from what's drawn, so it has to wait for the first render.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.panel.invalidateShadow() }
    }

    private func listenForPlayerChanges() {
        // NSApplication holds these back while the app is inactive, which is always, unless told otherwise.
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(playerChanged), name: Notification.Name(name),
                object: nil, suspensionBehavior: .deliverImmediately
            )
        }
    }

    @objc private func playerChanged() { model.refresh() }

    // MARK: Position

    private func defaultOrigin() -> NSPoint {
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: area.maxX - cardSize.width - 14, y: area.maxY - cardSize.height - 14)
    }

    private func savedOrigin() -> NSPoint? {
        guard let text = UserDefaults.standard.string(forKey: positionKey) else { return nil }
        let origin = NSPointFromString(text)
        let frame = NSRect(origin: origin, size: cardSize)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) } ? origin : nil
    }

    private func dragMoved() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    // Snaps to a screen edge when released close to one, and keeps the card on screen.
    private func dragEnded() {
        dragStart = nil
        let area = (panel.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let margin: CGFloat = 14, snap: CGFloat = 32
        var frame = panel.frame

        if frame.minX - area.minX < snap { frame.origin.x = area.minX + margin }
        if area.maxX - frame.maxX < snap { frame.origin.x = area.maxX - frame.width - margin }
        if frame.minY - area.minY < snap { frame.origin.y = area.minY + margin }
        if area.maxY - frame.maxY < snap { frame.origin.y = area.maxY - frame.height - margin }

        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: positionKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: Right-click menu

    private func installContextMenu() {
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if let track = model.track {
            menu.addItem(item("Open \(track.source.appName)", #selector(openPlayer)))
            menu.addItem(.separator())
        }
        let onTop = item("Always on Top", #selector(toggleOnTop))
        onTop.state = keepOnTop ? .on : .off
        menu.addItem(onTop)
        menu.addItem(.separator())
        menu.addItem(item("Quit Now Playing", #selector(quit)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openPlayer() { model.openPlayer() }

    @objc private func toggleOnTop() {
        keepOnTop.toggle()
        panel.level = keepOnTop ? .floating : .normal
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

#if SNAPSHOT
// Renders the card with made-up songs to PNG files, for checking the design. Not in the installed app.
@MainActor func renderSnapshots(to folder: String) {
    func cover(_ colors: [NSColor]) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: colors)!.draw(in: rect, angle: 60)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: 80, y: 60, width: 150, height: 150)).fill()
            return true
        }
    }

    func track(_ title: String) -> Track {
        Track(id: title, title: title, artist: "Example Artist", album: "Example Album", duration: 214, source: .spotify)
    }

    typealias Case = (name: String, art: [NSColor]?, title: String?, playing: Bool, hovering: Bool)
    let cases: [Case] = [
        ("vivid", [.systemPink, .systemPurple, .systemIndigo], "Short Song Title", true, false),
        ("hover", [.systemTeal, .systemBlue], "Short Song Title", true, true),
        ("white-cover", [.white, NSColor(white: 0.93, alpha: 1)], "A Song on a Very Pale Cover", false, false),
        ("idle", nil, nil, false, false),
    ]

    for item in cases {
        let model = NowPlayingModel()
        if let title = item.title {
            model.apply(.reading(Reading(track: track(title), isPlaying: false, position: 83)))
            model.isPlaying = item.playing
        }
        model.art = item.art.flatMap { Artwork(image: cover($0)) }
        model.hovering = item.hovering

        let view = CardView(model: model)
            .padding(24)
            .background(Color(white: 0.75))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { continue }
        try? png.write(to: URL(fileURLWithPath: "\(folder)/\(item.name).png"))
    }
}

MainActor.assumeIsolated { renderSnapshots(to: CommandLine.arguments[1]) }
#else
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
#endif
