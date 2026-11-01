// Draws the README's animated tours from the pictures `make screenshots` renders, in light and dark, and encodes each
// with ffmpeg (brew install ffmpeg). make readme-tour runs it, as does make screenshots when ffmpeg is installed:
//   swift scripts/make-readme-tour.swift build/screenshots docs/images
// Both play like a short visit to BriefBar on a Mac's desktop, under its menu bar, and each click opens what clicking
// there opens in the app. The tour opens BriefBar's list from its item in the menu bar, then the window's Overview, a
// story on the Sprint page with its summary, and sends a task to Copilot. The trail follows a story's bug to its pull
// request and the Copilot session that opened it.
import AppKit

let arguments = CommandLine.arguments
let screenshots = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "build/screenshots")
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "docs/images")
let framesRoot = URL(fileURLWithPath: arguments.count > 3 ? arguments[3] : "build/readme-tour")

let fps = 25
// In points from the top left, like the pictures. The desktop, 1020 × 728 points as the renderer draws it, fills the
// card. A window opens on it below the menu bar, where window pictures (1960 × 1360) fill it; the Sprint page's, a
// little wider, lose their bottom edge.
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
    /// The picture while the pointer is over `hoverArea`, in the picture's pixels.
    var hovered: CGImage? = nil
    var hoverArea: CGRect = .null
    /// A taller picture of the same page, which `scrollArea`, in the picture's pixels, scrolls through. Its bottom
    /// corners are rounded like the panel it's in.
    var taller: CGImage? = nil
    var scrollArea: CGRect = .null
    /// Where the picture goes.
    var frame: CGRect { isDesktop ? card : windowFrame }
    var scale: CGFloat { frame.width / CGFloat(image.width) }
    /// Where a point of the picture, in its pixels, lands in the frame.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: frame.minX + x * scale, y: frame.minY + y * scale) }
    func isHovered(at cursor: CGPoint) -> Bool {
        hovered != nil && hoverArea.contains(CGPoint(x: (cursor.x - frame.minX) / scale, y: (cursor.y - frame.minY) / scale))
    }
}

// In the desktop's pictures: BriefBar's item in the menu bar, and the top of its list, which opens the window's
// Overview.
let menuBarItem = CGPoint(x: 1_440, y: 26)
let overviewLink = CGPoint(x: 1_790, y: 108)

// The pull request's page: below its header, its panel scrolls, through the taller picture, to the Copilot session
// that opened it.
let pullRequestPanel = CGRect(x: 1_172, y: 252, width: 798, height: 1_159)
let panelRadius: CGFloat = 32
let openedBySession = CGPoint(x: 1_440, y: 1_468)

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
    /// How far the scene's scrolling area is scrolled down, in its picture's pixels.
    var scroll: CGFloat = 0

    var key: String {
        "\(scene) \(Int(cursor.x * 4)) \(Int(cursor.y * 4)) \(ripple ?? -1) \(Int(sheet * 1000)) \(hover) \(Int(scroll))"
    }
}

func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
func frames(_ seconds: Double) -> Int { max(1, Int((seconds * Double(fps)).rounded())) }

// MARK: - The visits

/// The frames of a visit, as the pointer moves, clicks and opens what it clicks.
struct Visit {
    let scenes: [Scene]
    var timeline: [Frame] = []
    var cursor: CGPoint
    var ripple: Int?
    var sheet = 0.0
    var scroll: CGFloat = 0

    init(_ scenes: [Scene], from start: CGPoint) {
        self.scenes = scenes
        cursor = start
    }

    mutating func append(_ scene: Int) {
        timeline.append(Frame(scene: scene, cursor: cursor, ripple: ripple, sheet: sheet,
                              hover: scenes[scene].isHovered(at: cursor), scroll: scroll))
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
    /// Scrolls the scene's scrolling area down `distance` pixels of its picture, as a trackpad does under the pointer.
    mutating func scroll(_ scene: Int, by distance: CGFloat, _ seconds: Double) {
        let from = scroll, count = frames(seconds)
        for index in 1...count {
            scroll = from + distance * CGFloat(ease(Double(index) / Double(count)))
            append(scene)
        }
    }
    /// A click, and what it opens.
    mutating func click(_ scene: Int, opening next: Int) {
        ripple = 0
        hold(scene, 0.12)
        scroll = 0
        append(next)
    }
    /// A click that opens Send to Copilot's window over the scene.
    mutating func clickOpeningSheet(_ scene: Int) {
        ripple = 0
        hold(scene, 0.12)
        for index in 1...frames(0.24) {
            sheet = ease(Double(index) / Double(frames(0.24)))
            append(scene)
        }
    }
}

/// From BriefBar's list to the window, a story's summary, and a task sent to Copilot. It starts as the list opens, from
/// BriefBar's item in the menu bar, and ends as the item is clicked again, so it loops.
func tour(_ scenes: [Scene]) -> [Frame] {
    let item = scenes[0].point(menuBarItem.x, menuBarItem.y)
    var visit = Visit(scenes, from: item)
    // The end's click, still rippling.
    visit.ripple = 3
    visit.hold(1, 0.4)
    visit.move(1, to: scenes[1].point(1_560, 420), 0.7)
    visit.hold(1, 1.7)
    // The window, at the Overview, then the Sprint page from its sidebar.
    visit.move(1, to: scenes[1].point(overviewLink.x, overviewLink.y), 0.7)
    visit.click(1, opening: 2)
    visit.hold(2, 0.5)
    visit.move(2, to: scenes[2].point(165, 522), 0.8)
    visit.click(2, opening: 3)
    // Story 5101's details, and the summary of where it stands.
    visit.hold(3, 0.4)
    visit.move(3, to: scenes[3].point(760, 566), 0.7)
    visit.click(3, opening: 4)
    visit.move(4, to: scenes[4].point(1_560, 700), 0.6)
    visit.hold(4, 2.1)
    // Closing them, pointing at a task offers to send it to Copilot, where its avatar was.
    visit.move(4, to: scenes[4].point(1_928, 204), 0.6)
    visit.click(4, opening: 5)
    visit.move(5, to: scenes[5].point(taskAvatar.x + 8, taskAvatar.y + 9), 0.8)
    visit.clickOpeningSheet(5)
    visit.move(5, to: scenes[5].point(1_050, 700), 0.5)
    visit.hold(5, 2.2)
    // Back on the desktop, the list opens from the menu bar again.
    visit.sheet = 0
    visit.hold(0, 0.3)
    visit.move(0, to: item, 0.8)
    visit.ripple = 0
    visit.hold(0, 0.12)
    return visit.timeline
}

/// From a story to its bug, the bug's pull request and, down its page, the Copilot session that opened it.
func trail(_ scenes: [Scene]) -> [Frame] {
    var visit = Visit(scenes, from: scenes[0].point(1_560, 700))
    visit.hold(0, 1.4)
    visit.move(0, to: scenes[0].point(470, 1_290), 0.8)
    visit.click(0, opening: 1)
    visit.hold(1, 1.0)
    visit.move(1, to: scenes[1].point(1_500, 1_072), 0.6)
    visit.click(1, opening: 2)
    visit.hold(2, 1.0)
    visit.move(2, to: scenes[2].point(1_560, 1_000), 0.4)
    let distance: CGFloat = 300
    visit.scroll(2, by: distance, 0.45)
    visit.move(2, to: scenes[2].point(openedBySession.x, openedBySession.y - distance), 0.5)
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
func drawScene(_ scene: Scene, hover: Bool, desktop: CGImage, dark: Bool, in context: CGContext) {
    context.saveGState()
    context.addPath(roundedRect(card, radius: 12))
    context.clip()
    let image = hover ? scene.hovered ?? scene.image : scene.image
    if scene.isDesktop {
        context.draw(image, in: flipped(card))
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

/// The scene's scrolling area, scrolled down `offset` pixels of its picture through the taller picture. Above the
/// area, such as a panel's header, nothing moves.
func drawScrolled(_ scene: Scene, by offset: CGFloat, in context: CGContext) {
    guard let taller = scene.taller, offset > 0 else { return }
    let area = scene.scrollArea
    let shown = CGRect(origin: scene.point(area.minX, area.minY), size: CGSize(width: area.width * scene.scale, height: area.height * scene.scale))
    // Square at the top, where the header is, and rounded at the bottom like the panel.
    let radius = panelRadius * scene.scale
    let rounded = CGRect(x: shown.minX, y: shown.minY - radius, width: shown.width, height: shown.height + radius)
    context.saveGState()
    context.clip(to: flipped(shown))
    context.addPath(roundedRect(rounded, radius: radius))
    context.clip()
    let size = CGSize(width: CGFloat(taller.width) * scene.scale, height: CGFloat(taller.height) * scene.scale)
    context.draw(taller, in: flipped(CGRect(origin: CGPoint(x: scene.frame.minX, y: scene.frame.minY - offset * scene.scale), size: size)))
    context.restoreGState()
}

/// Send to Copilot's window, over the window it was opened from, which dims at once.
func drawSheet(_ composer: CGImage, scene: Scene, progress: Double, dark: Bool, in context: CGContext) {
    guard progress > 0 else { return }
    let shown = CGFloat(progress)
    context.saveGState()
    context.addPath(roundedRect(windowFrame, radius: windowRadius))
    context.clip()
    context.setFillColor(NSColor.black.withAlphaComponent(dark ? 0.4 : 0.2).cgColor)
    context.fill(flipped(windowFrame))
    context.restoreGState()

    let scale = scene.scale * (0.94 + 0.06 * shown)
    let size = CGSize(width: CGFloat(composer.width) * scale, height: CGFloat(composer.height) * scale)
    let frame = CGRect(x: windowFrame.midX - size.width / 2, y: windowFrame.midY - size.height / 2, width: size.width, height: size.height)
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

/// Draws each different frame of `timeline` once, and encodes them, each shown for as long as it lasts, as `name`.gif.
func encode(_ timeline: [Frame], scenes: [Scene], desktop: CGImage, composer: CGImage, dark: Bool, name: String) throws {
    let directory = framesRoot.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Each scene under the pointer, with its caption, drawn once.
    let background = backdrop(dark: dark)
    var drawn: [String: CGImage] = [:]
    func base(_ frame: Frame) -> CGImage {
        let key = "\(frame.scene) \(frame.hover)"
        if let image = drawn[key] { return image }
        let context = makeContext()
        context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        drawCaption(scenes[frame.scene].caption, in: context)
        drawScene(scenes[frame.scene], hover: frame.hover, desktop: desktop, dark: dark, in: context)
        let image = context.makeImage()!
        drawn[key] = image
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
        drawScrolled(scenes[frame.scene], by: frame.scroll, in: context)
        drawSheet(composer, scene: scenes[frame.scene], progress: frame.sheet, dark: dark, in: context)
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
    let board = shot("window-azureDevOps.sprint")
    let story = shot("azureDevOps-sprint-details")
    let desktop = shot("desktop-bare")
    let composer = shot("azureDevOps-copilot-composer")

    let tourScenes = [
        Scene(image: shot("desktop-closed"), caption: "Counted in your menu bar, and on your desktop", isDesktop: true),
        Scene(image: shot("desktop"), caption: "One click: a brief, and everything that needs you", isDesktop: true),
        Scene(image: shot("window-overview"), caption: "The whole picture in a window"),
        Scene(image: board, caption: "Your sprint, with its pull requests and Copilot sessions"),
        Scene(image: story, caption: "Open a story: where it stands, summarized by AI"),
        Scene(image: board, caption: "Hand the next task to Copilot", hovered: hoveredRow(on: board, dark: dark), hoverArea: taskRow),
    ]
    try encode(tour(tourScenes), scenes: tourScenes, desktop: desktop, composer: composer, dark: dark,
               name: "readme-tour-\(appearance)")

    let trailScenes = [
        Scene(image: story, caption: "Every work item links to its pull requests and sessions"),
        Scene(image: shot("azureDevOps-sprint-bug-details"), caption: "Open a bug: who it's waiting on, and why"),
        Scene(image: shot("azureDevOps-sprint-pull-request-page"), caption: "Click through to its pull request…",
              taller: shot("azureDevOps-sprint-pull-request-page-tall"), scrollArea: pullRequestPanel),
        Scene(image: shot("azureDevOps-sprint-deep-page"), caption: "…and the Copilot session that opened it"),
    ]
    try encode(trail(trailScenes), scenes: trailScenes, desktop: desktop, composer: composer, dark: dark,
               name: "readme-trail-\(appearance)")
}
