// Draws the README's animated tours from the pictures `make screenshots` renders, in light and dark, and encodes each
// with ffmpeg (brew install ffmpeg). make readme-tour runs it, as does make screenshots when ffmpeg is installed:
//   swift scripts/make-readme-tour.swift build/screenshots docs/images
// Both play like a short visit to BriefBar on a Mac's desktop, under its menu bar, and each click opens what clicking
// there opens in the app. The tour opens Copilot's sessions, then your pull requests, from their items in the menu bar,
// then the window's Pull Requests page at Up Next, and the Board. The trail follows a story's bug to its pull request
// and the Copilot session that opened it.
import AppKit

let arguments = CommandLine.arguments
let screenshots = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "build/screenshots")
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "docs/images")
let framesRoot = URL(fileURLWithPath: arguments.count > 3 ? arguments[3] : "build/readme-tour")

let fps = 25
// In points from the top left, like the pictures. The desktop, 1020 × 728 points as the renderer draws it, fills the
// card. A window opens on it below the menu bar, where window pictures (1960 × 1360) fill it; the pages' own, a little
// wider, lose their bottom edge.
let captionHeight: CGFloat = 56
let card = CGRect(x: 12, y: captionHeight, width: 936, height: 668)
let width = 960, height = Int(card.maxY) + 12
let desktopScale = card.width / 1_020
let windowFrame = CGRect(x: card.minX + 20 * desktopScale, y: card.minY + 36 * desktopScale,
                         width: 980 * desktopScale, height: 680 * desktopScale)
let windowRadius: CGFloat = 12

func flipped(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: CGFloat(height) - point.y) }
func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height) }

/// A picture at 2×, which every position in this script assumes. Pictures rendered on a 1× display are scaled up.
func loadImage(_ name: String) -> CGImage {
    let url = screenshots.appendingPathComponent("\(name).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("Missing \(url.path): run make screenshots first.") }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 144
    let factor = 144 / dpi
    guard abs(factor - 1) > 0.01 else { return image }
    let width = Int((Double(image.width) * factor).rounded()), height = Int((Double(image.height) * factor).rounded())
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Can't scale \(url.path)") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

struct Scene {
    let image: CGImage
    let caption: String
    /// The whole desktop, rather than a window open on the bare one.
    var isDesktop = false
    /// Part of the desktop's menu bar, magnified under it.
    var loupe: Loupe? = nil
    /// Where the picture goes.
    var frame: CGRect { isDesktop ? card : windowFrame }
    var scale: CGFloat { frame.width / CGFloat(image.width) }
    /// Where a point of the picture, in its pixels, lands in the frame.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: frame.minX + x * scale, y: frame.minY + y * scale) }
}

/// A part of a desktop's menu bar, `area` in the picture's pixels, magnified in a card at `frame`, in the tour's points,
/// with what each item is under it, centered on the item's middle, in the picture's pixels.
struct Loupe {
    let area: CGRect
    let frame: CGRect
    let labels: [(text: String, midX: CGFloat)]
}

// In the desktop's pictures: Copilot's and Azure DevOps' items in the menu bar, and the title of Azure DevOps' list, Pull
// Requests ›, which opens the window's page; and where the pointer starts and ends.
let copilotItem = CGPoint(x: 1_147, y: 24)
let pullRequestsItem = CGPoint(x: 888, y: 24)
let pullRequestsTitle = CGPoint(x: 690, y: 178)
let desktopRest = CGPoint(x: 1_640, y: 700)
// The two items, magnified in a card right of the widget.
let itemsLoupe = Loupe(
    area: CGRect(x: 762, y: 0, width: 542, height: 48), frame: CGRect(x: 365, y: 92, width: 560, height: 98),
    labels: [("Azure DevOps pull requests", pullRequestsItem.x), ("Copilot sessions", copilotItem.x)]
)

// On the window's Pull Requests page: 2 more › under Up Next's Fix next, which shows the rest on the Board.
let fixNextMore = CGPoint(x: 585, y: 627)

// A story's pull request's page: the line under its heading, which names the Copilot session that opened it, shows the
// session's page.
let openedBySession = CGPoint(x: 1_480, y: 666)

// Scenes change with a cut, as they do in the app. A cross-fade would cost many full frames.
struct Frame {
    var scene: Int
    var cursor: CGPoint
    /// Frames since the last click, while its ripple shows.
    var ripple: Int? = nil

    var key: String {
        "\(scene) \(Int(cursor.x * 4)) \(Int(cursor.y * 4)) \(ripple ?? -1)"
    }
}

func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
func frames(_ seconds: Double) -> Int { max(1, Int((seconds * Double(fps)).rounded())) }

// MARK: - The visits

/// The frames of a visit, as the pointer moves, clicks and opens what it clicks.
struct Visit {
    var timeline: [Frame] = []
    var cursor: CGPoint
    var ripple: Int?

    init(from start: CGPoint) {
        cursor = start
    }

    mutating func append(_ scene: Int) {
        timeline.append(Frame(scene: scene, cursor: cursor, ripple: ripple))
        if let age = ripple { ripple = age < 10 ? age + 1 : nil }
    }
    mutating func hold(_ scene: Int, _ seconds: Double) {
        for _ in 0..<frames(seconds) { append(scene) }
    }
    mutating func move(_ scene: Int, to target: CGPoint, _ seconds: Double) {
        let from = cursor, count = frames(seconds)
        for index in 1...count {
            let t = ease(Double(index) / Double(count))
            cursor = CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)
            append(scene)
        }
    }
    /// A click, and what it opens.
    mutating func click(_ scene: Int, opening next: Int) {
        ripple = 0
        hold(scene, 0.12)
        append(next)
    }
}

/// From BriefBar's items in the menu bar, to Copilot's sessions, your pull requests, and their page in the window: Up
/// Next, then the Board. It starts and ends on the desktop with no list open, the pointer where it was, so it loops.
func tour(_ scenes: [Scene]) -> [Frame] {
    let rest = scenes[0].point(desktopRest.x, desktopRest.y)
    var visit = Visit(from: rest)
    visit.hold(0, 2.0)
    // Copilot's sessions, from its item: those that wait for you, then those running.
    visit.move(0, to: scenes[0].point(copilotItem.x, copilotItem.y), 0.8)
    visit.click(0, opening: 1)
    visit.move(1, to: scenes[1].point(1_420, 368), 0.6)
    visit.hold(1, 1.8)
    // Your pull requests, from Azure DevOps' item.
    visit.move(1, to: scenes[1].point(pullRequestsItem.x, pullRequestsItem.y), 0.7)
    visit.click(1, opening: 2)
    visit.move(2, to: scenes[2].point(1_100, 670), 0.6)
    visit.hold(2, 1.8)
    // Their page in the window, from the list's title: Up Next.
    visit.move(2, to: scenes[2].point(pullRequestsTitle.x, pullRequestsTitle.y), 0.6)
    visit.click(2, opening: 3)
    visit.move(3, to: scenes[3].point(1_250, 770), 0.7)
    visit.hold(3, 1.6)
    // Fix next's 2 more ›: the Board, where its pull request leads In progress.
    visit.move(3, to: scenes[3].point(fixNextMore.x, fixNextMore.y), 0.6)
    visit.click(3, opening: 4)
    visit.move(4, to: scenes[4].point(345, 1_000), 0.7)
    visit.hold(4, 2.6)
    // Back on the desktop, where it started.
    visit.hold(0, 0.3)
    visit.move(0, to: rest, 0.6)
    return visit.timeline
}

/// From a story to its bug, the bug's pull request and the Copilot session that opened it.
func trail(_ scenes: [Scene]) -> [Frame] {
    var visit = Visit(from: scenes[0].point(1_560, 700))
    visit.hold(0, 1.4)
    visit.move(0, to: scenes[0].point(470, 1_290), 0.8)
    visit.click(0, opening: 1)
    visit.hold(1, 1.0)
    visit.move(1, to: scenes[1].point(1_500, 1_072), 0.6)
    visit.click(1, opening: 2)
    visit.move(2, to: scenes[2].point(1_560, 1_000), 0.5)
    visit.hold(2, 1.2)
    visit.move(2, to: scenes[2].point(openedBySession.x, openedBySession.y), 0.6)
    visit.click(2, opening: 3)
    visit.move(3, to: scenes[3].point(1_560, 620), 0.6)
    visit.hold(3, 2.4)
    return visit.timeline
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

/// The card: the desktop, or the bare one with the scene's window open on it.
func drawScene(_ scene: Scene, desktop: CGImage, dark: Bool, in context: CGContext) {
    context.saveGState()
    context.addPath(roundedRect(card, radius: 12))
    context.clip()
    let image = scene.image
    if scene.isDesktop {
        context.draw(image, in: flipped(card))
        if let loupe = scene.loupe { drawLoupe(loupe, of: scene, dark: dark, in: context) }
        context.restoreGState()
        return
    }
    context.draw(desktop, in: flipped(card))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.3).cgColor)
    context.addPath(roundedRect(windowFrame, radius: windowRadius))
    context.setFillColor(NSColor(white: dark ? 0.15 : 0.95, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(roundedRect(windowFrame, radius: windowRadius))
    context.clip()
    let size = CGSize(width: windowFrame.width, height: CGFloat(scene.image.height) * scene.scale)
    context.draw(image, in: flipped(CGRect(origin: windowFrame.origin, size: size)))
    context.restoreGState()
    context.addPath(roundedRect(windowFrame.insetBy(dx: 0.5, dy: 0.5), radius: windowRadius))
    context.setStrokeColor((dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.16 : 0.12).cgColor)
    context.setLineWidth(1)
    context.strokePath()
    context.restoreGState()
}

/// The loupe's card, its caret pointing up at the part of the menu bar it magnifies, with that part and its labels.
func drawLoupe(_ loupe: Loupe, of scene: Scene, dark: Bool, in context: CGContext) {
    guard let part = scene.image.cropping(to: loupe.area) else { return }
    let frame = loupe.frame
    let zoom = (frame.width - 32) / loupe.area.width
    let anchor = scene.point(loupe.area.midX, loupe.area.maxY)
    let outline = CGMutablePath()
    outline.addPath(roundedRect(frame, radius: 12))
    outline.addLines(between: [CGPoint(x: anchor.x - 9, y: frame.minY + 1), CGPoint(x: anchor.x, y: frame.minY - 8),
                               CGPoint(x: anchor.x + 9, y: frame.minY + 1)].map(flipped))
    outline.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -4), blur: 16, color: NSColor.black.withAlphaComponent(dark ? 0.5 : 0.25).cgColor)
    context.addPath(outline)
    context.setFillColor(NSColor(white: dark ? 0.17 : 0.97, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    let bar = CGRect(x: frame.minX + 16, y: frame.minY + 12, width: loupe.area.width * zoom, height: loupe.area.height * zoom)
    context.saveGState()
    context.addPath(roundedRect(bar, radius: 8))
    context.clip()
    context.draw(part, in: flipped(bar))
    context.restoreGState()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for label in loupe.labels {
        let text = NSAttributedString(string: label.text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: dark ? 0.82 : 0.3, alpha: 1),
        ])
        let size = text.size()
        let x = bar.minX + (label.midX - loupe.area.minX) * zoom - size.width / 2
        text.draw(at: flipped(CGPoint(x: x, y: bar.maxY + 8 + size.height)))
    }
    NSGraphicsContext.restoreGraphicsState()
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

/// Draws each different frame of `timeline` once, and encodes them, each shown for as long as it lasts, as `name`.gif.
func encode(_ timeline: [Frame], scenes: [Scene], desktop: CGImage, dark: Bool, name: String) throws {
    let directory = framesRoot.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Each scene, with its caption, drawn once.
    let background = backdrop(dark: dark)
    var drawn: [Int: CGImage] = [:]
    func base(_ frame: Frame) -> CGImage {
        if let image = drawn[frame.scene] { return image }
        let context = makeContext()
        context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        drawCaption(scenes[frame.scene].caption, in: context)
        drawScene(scenes[frame.scene], desktop: desktop, dark: dark, in: context)
        let image = context.makeImage()!
        drawn[frame.scene] = image
        return image
    }

    var frames: [(name: String, key: String, count: Int)] = []
    for frame in timeline {
        if let last = frames.last, last.key == frame.key {
            frames[frames.count - 1].count += 1
            continue
        }
        let context = makeContext()
        context.draw(base(frame), in: CGRect(x: 0, y: 0, width: width, height: height))
        drawCursor(at: frame.cursor, ripple: frame.ripple, in: context)

        let file = String(format: "%04d.png", frames.count)
        writePNG(context.makeImage()!, to: directory.appendingPathComponent(file))
        frames.append((file, frame.key, 1))
    }
    // ffmpeg's concat list; it takes the last file's duration only if the file is listed again.
    let list = directory.appendingPathComponent("frames.txt")
    let entries = frames.map { "file '\($0.name)'\nduration \(String(format: "%.2f", Double($0.count) / Double(fps)))" }
    try (entries + ["file '\(frames.last!.name)'"]).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)

    // One palette for the whole visit and no dithering: a frame then differs from the one before only where the
    // picture does, which keeps the file small and leaves nothing behind when the scene changes.
    let gif = output.appendingPathComponent("\(name).gif")
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

// MARK: - Light and dark

for appearance in ["light", "dark"] {
    let dark = appearance == "dark"
    let shot = { (name: String) in loadImage("\(name)-\(appearance)") }
    let story = shot("azureDevOps-sprint-details")
    let desktop = shot("desktop-bare")

    let tourScenes = [
        Scene(image: shot("desktop-closed"), caption: "Your pull requests and Copilot sessions, live in your menu bar",
              isDesktop: true, loupe: itemsLoupe),
        Scene(image: shot("desktop-copilot.sessions"), caption: "Copilot sessions waiting for you, and those still running",
              isDesktop: true),
        Scene(image: shot("desktop-azureDevOps.pullRequests"), caption: "Pull requests that need your review, a reply or a fix",
              isDesktop: true),
        Scene(image: shot("window-azureDevOps.pullRequests"), caption: "Up Next: what to fix and review next"),
        Scene(image: shot("azureDevOps-pull-requests-board-window"), caption: "Every pull request's stage, on a Board"),
    ]
    try encode(tour(tourScenes), scenes: tourScenes, desktop: desktop, dark: dark, name: "readme-tour-\(appearance)")

    let trailScenes = [
        Scene(image: story, caption: "Every work item links to its pull requests and sessions"),
        Scene(image: shot("azureDevOps-sprint-bug-details"), caption: "Open a bug: who it's waiting on, and why"),
        Scene(image: shot("azureDevOps-sprint-pull-request-page"), caption: "Click through to its pull request…"),
        Scene(image: shot("azureDevOps-sprint-deep-page"), caption: "…and the Copilot session that opened it"),
    ]
    try encode(trail(trailScenes), scenes: trailScenes, desktop: desktop, dark: dark, name: "readme-trail-\(appearance)")
}
