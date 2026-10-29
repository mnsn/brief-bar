// Draws the README's animated tour from the pictures `make screenshots` renders, in light and dark, and encodes each
// with ffmpeg (brew install ffmpeg). make readme-tour runs it, as does make screenshots when ffmpeg is installed:
//   swift scripts/make-readme-tour.swift build/screenshots docs/images
// It plays like a short visit to the app: the pointer goes from the Overview to a story on the Sprint page, follows a bug
// to its pull request and the Copilot session that opened it, passes the summaries on the pull requests, and sends a
// task to Copilot. Each click opens what clicking there opens in the app.
import AppKit

let arguments = CommandLine.arguments
let screenshots = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "build/screenshots")
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "docs/images")
let framesRoot = URL(fileURLWithPath: arguments.count > 3 ? arguments[3] : "build/readme-tour")

let fps = 25
let width = 960, height = 718
// In points from the top left, like the pictures. The window pictures (1960 × 1360) fill the card; the Sprint page's,
// a little wider, lose their bottom edge.
let captionHeight: CGFloat = 64
let card = CGRect(x: 20, y: captionHeight, width: 920, height: 638)

func flipped(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: CGFloat(height) - point.y) }
func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height) }

func loadImage(_ name: String) -> CGImage {
    let url = screenshots.appendingPathComponent("\(name).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("Missing \(url.path): run make screenshots first.") }
    return image
}

struct Scene {
    let image: CGImage
    let caption: String
    /// The picture while the pointer is over `hoverArea`, in the picture's pixels.
    var hovered: CGImage? = nil
    var hoverArea: CGRect = .null
    var scale: CGFloat { card.width / CGFloat(image.width) }
    /// Where a point of the picture, in its pixels, lands on the card.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: card.minX + x * scale, y: card.minY + y * scale) }
    func isHovered(at cursor: CGPoint) -> Bool {
        hovered != nil && hoverArea.contains(CGPoint(x: (cursor.x - card.minX) / scale, y: (cursor.y - card.minY) / scale))
    }
}

// Task 5104's row on the Sprint page, in the picture's pixels. Pointing at a task highlights its row and puts the
// Send to Copilot button where its avatar was.
let taskRow = CGRect(x: 532, y: 809, width: 652, height: 57)
let taskAvatar = CGPoint(x: 1_154, y: 837.5)

func hoveredRow(on board: CGImage, dark: Bool) -> CGImage {
    let width = board.width, height = board.height
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let all = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(board, in: all)
    func flip(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height) }

    // The avatar, and its ring, give way to the row's background, stretched from just right of it.
    let avatar = CGRect(x: taskAvatar.x - 26, y: taskAvatar.y - 27, width: 52, height: 54)
    let background = board.cropping(to: CGRect(x: avatar.maxX, y: avatar.minY, width: 10, height: avatar.height))!
    context.draw(background, in: flip(avatar))
    context.addPath(CGPath(roundedRect: flip(taskRow), cornerWidth: 16, cornerHeight: 16, transform: nil))
    context.setFillColor((dark ? NSColor.white : NSColor.black).withAlphaComponent(0.07).cgColor)
    context.fillPath()

    // CopilotSendButton: paperplane at 11.5 pt, medium, in a borderless button's gray; the picture is at 2×.
    let symbol = NSImage(systemSymbolName: "paperplane", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 23, weight: .medium)
            .applying(.init(paletteColors: [NSColor(white: dark ? 0.67 : 0.57, alpha: 1)])))!
    let size = symbol.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    symbol.draw(in: flip(CGRect(x: taskAvatar.x - size.width / 2, y: taskAvatar.y - size.height / 2, width: size.width, height: size.height)))
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

// Scenes change with a cut, as they do in the app. A cross-fade would cost many full frames.
struct Frame {
    var scene: Int
    var cursor: CGPoint
    /// Frames since the last click, while its ripple shows.
    var ripple: Int? = nil
    /// How far the Send to Copilot window has opened, over the scene.
    var sheet: Double = 0
    var hover = false

    var key: String { "\(scene) \(Int(cursor.x * 4)) \(Int(cursor.y * 4)) \(ripple ?? -1) \(Int(sheet * 1000)) \(hover)" }
}

func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
func frames(_ seconds: Double) -> Int { max(1, Int((seconds * Double(fps)).rounded())) }

// MARK: - The visit

func timeline(_ scenes: [Scene]) -> [Frame] {
    var timeline: [Frame] = []
    let start = scenes[0].point(1_400, 1_000)
    var cursor = start
    var ripple: Int?
    var sheet = 0.0

    func append(_ frame: Frame) {
        var frame = frame
        frame.ripple = ripple
        frame.sheet = sheet
        frame.hover = scenes[frame.scene].isHovered(at: frame.cursor)
        timeline.append(frame)
        if let age = ripple { ripple = age < 10 ? age + 1 : nil }
    }
    func hold(_ scene: Int, _ seconds: Double) {
        for _ in 0..<frames(seconds) { append(Frame(scene: scene, cursor: cursor)) }
    }
    func move(_ scene: Int, to target: CGPoint, _ seconds: Double) {
        let from = cursor, count = frames(seconds)
        for index in 1...count {
            let t = ease(Double(index) / Double(count))
            cursor = CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)
            append(Frame(scene: scene, cursor: cursor))
        }
    }
    /// A click, and what it opens.
    func click(_ scene: Int, opening next: Int) {
        ripple = 0
        hold(scene, 0.12)
        append(Frame(scene: next, cursor: cursor))
    }

    // The Overview, then the Sprint page from the sidebar.
    hold(0, 1.2)
    move(0, to: scenes[0].point(165, 522), 0.8)
    click(0, opening: 1)
    // Story 5101's details, and Copilot's summary of where it stands.
    hold(1, 0.4)
    move(1, to: scenes[1].point(760, 566), 0.7)
    click(1, opening: 2)
    move(2, to: scenes[2].point(1_560, 700), 0.6)
    hold(2, 2.4)
    // Bug 5110, its pull request, and the session that opened it.
    move(2, to: scenes[2].point(470, 1_290), 0.8)
    click(2, opening: 3)
    hold(3, 0.6)
    move(3, to: scenes[3].point(1_520, 850), 0.6)
    click(3, opening: 4)
    hold(4, 0.8)
    move(4, to: scenes[4].point(1_440, 1_095), 0.6)
    click(4, opening: 5)
    move(5, to: scenes[5].point(1_620, 575), 0.6)
    hold(5, 1.8)
    // The pull requests, each with a summary.
    move(6, to: scenes[6].point(1_080, 770), 0.7)
    hold(6, 2.2)
    // Pointing at a task offers to send it to Copilot, where its avatar was.
    move(7, to: scenes[7].point(taskAvatar.x + 8, taskAvatar.y + 9), 0.8)
    ripple = 0
    hold(7, 0.12)
    for index in 1...frames(0.24) {
        sheet = ease(Double(index) / Double(frames(0.24)))
        append(Frame(scene: 7, cursor: cursor))
    }
    move(7, to: scenes[7].point(1_050, 700), 0.5)
    hold(7, 2.4)
    return timeline
}

// MARK: - Drawing

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: flipped(rect), cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawCaption(_ caption: String, in context: CGContext) {
    let text = NSAttributedString(string: caption, attributes: [
        .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
        .foregroundColor: NSColor.white,
    ])
    let size = text.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    text.draw(at: flipped(CGPoint(x: (CGFloat(width) - size.width) / 2, y: (captionHeight + size.height) / 2 - 2)))
    NSGraphicsContext.restoreGraphicsState()
}

func drawScene(_ scene: Scene, hover: Bool, in context: CGContext) {
    context.saveGState()
    context.addPath(roundedRect(card, radius: 12))
    context.clip()
    let size = CGSize(width: card.width, height: CGFloat(scene.image.height) * scene.scale)
    context.draw(hover ? scene.hovered ?? scene.image : scene.image, in: flipped(CGRect(origin: card.origin, size: size)))
    context.restoreGState()
}

/// Send to Copilot's window, over the page it was opened from, which dims at once.
func drawSheet(_ composer: CGImage, scene: Scene, progress: Double, dark: Bool, in context: CGContext) {
    guard progress > 0 else { return }
    let shown = CGFloat(progress)
    context.saveGState()
    context.addPath(roundedRect(card, radius: 12))
    context.clip()
    context.setFillColor(NSColor.black.withAlphaComponent(dark ? 0.4 : 0.2).cgColor)
    context.fill(flipped(card))
    context.restoreGState()

    let scale = scene.scale * (0.94 + 0.06 * shown)
    let size = CGSize(width: CGFloat(composer.width) * scale, height: CGFloat(composer.height) * scale)
    let frame = CGRect(x: card.midX - size.width / 2, y: card.midY - size.height / 2, width: size.width, height: size.height)
    context.saveGState()
    context.setAlpha(shown)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 28, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    context.addPath(roundedRect(frame, radius: 10))
    context.setFillColor(NSColor(white: dark ? 0.18 : 0.93, alpha: 1).cgColor)
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.addPath(roundedRect(frame, radius: 10))
    context.clip()
    context.draw(composer, in: flipped(frame))
    context.endTransparencyLayer()
    context.restoreGState()
}

/// The arrow pointer, its tip at `tip`, a little smaller while pressed, with a ripple where it clicked.
func drawCursor(at tip: CGPoint, ripple: Int?, in context: CGContext) {
    if let age = ripple {
        let t = CGFloat(age) / 10
        let radius = 6 + 20 * t
        let ring = CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)
        let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
        context.setFillColor(blue.withAlphaComponent(0.22 * (1 - t)).cgColor)
        context.fillEllipse(in: flipped(ring))
        context.setStrokeColor(blue.withAlphaComponent(0.7 * (1 - t)).cgColor)
        context.setLineWidth(2.5)
        context.strokeEllipse(in: flipped(ring))
    }
    let pressed = (ripple ?? 99) < 3
    let size: CGFloat = pressed ? 1.0 : 1.18
    let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 16.5), (4, 12.6), (6.6, 18.6), (9.1, 17.6), (6.6, 11.7), (11.8, 11.7)]
    let path = CGMutablePath()
    path.addLines(between: outline.map { flipped(CGPoint(x: tip.x + $0.0 * size, y: tip.y + $0.1 * size)) })
    path.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(path)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()
    context.addPath(path)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(1.4)
    context.setLineJoin(.round)
    context.strokePath()
}

func backdrop(dark: Bool) -> CGImage {
    let context = makeContext()
    let colors = dark
        ? [NSColor(srgbRed: 0.05, green: 0.11, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.09, green: 0.33, blue: 0.5, alpha: 1)]
        : [NSColor(srgbRed: 0.07, green: 0.16, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.12, green: 0.47, blue: 0.68, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
    // The card's shadow, drawn once.
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(roundedRect(card, radius: 12))
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    return context.makeImage()!
}

func makeContext() -> CGContext {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    return context
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Can't write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(url.path)") }
}

// MARK: - Light and dark

for appearance in ["light", "dark"] {
    let dark = appearance == "dark"
    let shot = { (name: String) in loadImage("\(name)-\(appearance)") }
    let board = shot("window-azureDevOps.sprint")
    let scenes = [
        Scene(image: shot("window-overview"), caption: "Everything that needs you, in one place"),
        Scene(image: board, caption: "Your sprint, with its pull requests and Copilot sessions"),
        Scene(image: shot("azureDevOps-sprint-details"), caption: "Open a story: where it stands, summarized by Copilot"),
        Scene(image: shot("azureDevOps-sprint-bug-details"), caption: "Every item links to its pull requests and sessions"),
        Scene(image: shot("azureDevOps-sprint-pull-request-page"), caption: "Click through to the pull request…"),
        Scene(image: shot("azureDevOps-sprint-deep-page"), caption: "…and the Copilot session that opened it"),
        Scene(image: shot("rows-summary-pull-requests"), caption: "AI briefs, and a summary on every row"),
        Scene(image: board, caption: "Hand the next task to Copilot", hovered: hoveredRow(on: board, dark: dark), hoverArea: taskRow),
    ]
    let composer = shot("azureDevOps-copilot-composer")
    let background = backdrop(dark: dark)

    let directory = framesRoot.appendingPathComponent(appearance)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Each different frame once, shown for as long as it lasts.
    var frames: [(name: String, key: String, count: Int)] = []
    for frame in timeline(scenes) {
        if let last = frames.last, last.key == frame.key {
            frames[frames.count - 1].count += 1
            continue
        }
        let context = makeContext()
        context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scene = scenes[frame.scene]
        drawCaption(scene.caption, in: context)
        drawScene(scene, hover: frame.hover, in: context)
        drawSheet(composer, scene: scene, progress: frame.sheet, dark: dark, in: context)
        drawCursor(at: frame.cursor, ripple: frame.ripple, in: context)

        let name = String(format: "%04d.png", frames.count)
        writePNG(context.makeImage()!, to: directory.appendingPathComponent(name))
        frames.append((name, frame.key, 1))
    }
    // ffmpeg's concat list; it takes the last file's duration only if the file is listed again.
    let list = directory.appendingPathComponent("frames.txt")
    let entries = frames.map { "file '\($0.name)'\nduration \(String(format: "%.2f", Double($0.count) / Double(fps)))" }
    try (entries + ["file '\(frames.last!.name)'"]).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)

    // One palette for the whole tour and no dithering: a frame then differs from the one before only where the
    // picture does, which keeps the file small and leaves nothing behind when the scene changes.
    let gif = output.appendingPathComponent("readme-tour-\(appearance).gif")
    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments = [
        "ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
        "-vf", "split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle",
        "-fps_mode", "vfr", "-loop", "0", gif.path,
    ]
    try ffmpeg.run()
    ffmpeg.waitUntilExit()
    guard ffmpeg.terminationStatus == 0 else {
        fatalError("ffmpeg failed (\(ffmpeg.terminationStatus)). Is it installed? brew install ffmpeg")
    }
    let seconds = Double(frames.reduce(0) { $0 + $1.count }) / Double(fps)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
    print("\(gif.path): \(frames.count) frames, \(String(format: "%.1f", seconds)) s, \(bytes / 1024) KB")
}
