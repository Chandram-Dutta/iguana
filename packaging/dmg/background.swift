// Draws the picture behind the icons in the disk image's window: the iguana's tongue shoots
// out of the app icon and catches the Applications folder.
//
//   swift packaging/dmg/background.swift <output folder>
//
// It writes background.png (660 x 420) and background@2x.png (1320 x 840). Both are kept in
// packaging/dmg, so making a release never has to draw: run this only to change the picture.
//
// Finder draws the two icons and their names on top of the picture, so neither is drawn here:
//
//   Iguana.app     centred at (165, 180), 128 points
//   Applications   centred at (495, 180), 128 points
//
// packaging/dmg/settings.py puts them there. Change one and the other must follow.

import AppKit
import CoreText

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift packaging/dmg/background.swift <output folder>\n".utf8))
    exit(2)
}
let outputFolder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

/// The window's content area, in points, with the origin at the top left as Finder counts.
let canvas = CGSize(width: 660, height: 420)

// MARK: - Colours

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

/// The app icon's own colours (assets/app-icon.svg), so that the picture and the icon that
/// Finder lays on it look like one drawing.
enum Palette {
    static let outline = colour(0x0C3B2E)
    static let paper = colour(0xF3F2EC)
    static let teal = colour(0x18A67E)
    static let leaf = colour(0x74CB70)
    static let lime = colour(0x8FD43F)
    /// A mid green. Finder writes the icons' names on it in black in light mode and in white in
    /// dark mode, and both have to be readable: each stands at about 4:1 against this.
    static let ground = colour(0x2F8F47)
    static let groundShade = colour(0x287C40)
    static let groundLight = colour(0x3DA257)
    static let groundHalfLight = colour(0x35964E)
    /// The one warm colour in the picture, so that the eye follows the tongue.
    static let tongue = colour(0xF2707F)
    static let tongueLight = colour(0xF99CA6)
}

/// A little heavier than the icon's own lines, which are about 2 points wide when the icon is
/// 128 points across: the shapes here are larger, and seen from further off.
let outlineWidth: CGFloat = 3

// MARK: - The tongue

struct Cubic {
    var from, control1, control2, to: CGPoint

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * from.x + b * control1.x + c * control2.x + d * to.x,
            y: a * from.y + b * control1.y + c * control2.y + d * to.y)
    }

    func tangent(_ t: CGFloat) -> CGVector {
        let u = 1 - t
        let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
        let dx = a * (control1.x - from.x) + b * (control2.x - control1.x) + c * (to.x - control2.x)
        let dy = a * (control1.y - from.y) + b * (control2.y - control1.y) + c * (to.y - control2.y)
        let length = max(hypot(dx, dy), 0.0001)
        return CGVector(dx: dx / length, dy: dy / length)
    }
}

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func smoothstep(_ from: CGFloat, _ to: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - from) / (to - from), 0), 1)
    return t * t * (3 - 2 * t)
}

/// A point the middle line of the tongue passes through. Both curves that meet at a knot take
/// their direction from it, so the line never has a corner.
struct Knot {
    var at: CGPoint
    var heading: CGVector
    /// How far the curve keeps to the heading before and after the knot.
    var reachIn: CGFloat
    var reachOut: CGFloat

    init(_ x: CGFloat, _ y: CGFloat, heading: (CGFloat, CGFloat), reachIn: CGFloat = 0, reachOut: CGFloat = 0) {
        let length = hypot(heading.0, heading.1)
        at = CGPoint(x: x, y: y)
        self.heading = CGVector(dx: heading.0 / length, dy: heading.1 / length)
        self.reachIn = reachIn
        self.reachOut = reachOut
    }

    func along(_ distance: CGFloat) -> CGPoint {
        CGPoint(x: at.x + heading.dx * distance, y: at.y + heading.dy * distance)
    }
}

/// The line down the middle of the tongue. It starts at the iguana's mouth, which is about 80%
/// across and 55% down the app icon, so the icon hides the root. It dips, springs over the gap,
/// goes behind the folder on its left side, comes out at the bottom right, and curls up and over
/// the top right corner. Finder draws the folder over the middle of it, and that is what makes
/// the tongue look wrapped round the folder.
let knots: [Knot] = [
    Knot(200, 185, heading: (32, 9), reachOut: 33),
    Knot(290, 148, heading: (1, -1), reachIn: 40, reachOut: 40),
    Knot(394, 114, heading: (36, 20), reachIn: 41, reachOut: 39),
    Knot(474, 192, heading: (50, 16), reachIn: 52, reachOut: 40),
    Knot(583, 174, heading: (0, -1), reachIn: 40, reachOut: 30),
    Knot(524, 123, heading: (-1, 0), reachIn: 36),
]

let spine: [Cubic] = zip(knots, knots.dropFirst()).map { from, to in
    Cubic(from: from.at, control1: from.along(from.reachOut), control2: to.along(-to.reachIn), to: to.at)
}

struct SpinePoint {
    var position: CGPoint
    var tangent: CGVector
    /// How far this is from the mouth and from the tip, in points along the tongue.
    var fromMouth: CGFloat
    var toTip: CGFloat = 0

    var width: CGFloat { tongueWidth(fromMouth: fromMouth, toTip: toTip) }

    /// The side that is uppermost while the tongue travels to the right.
    var normal: CGVector { CGVector(dx: tangent.dy, dy: -tangent.dx) }

    func offset(_ distance: CGFloat) -> CGPoint {
        CGPoint(x: position.x + normal.dx * distance, y: position.y + normal.dy * distance)
    }
}

func sample(_ curves: [Cubic], stepsPerCurve: Int = 96) -> [SpinePoint] {
    var points: [SpinePoint] = []
    var travelled: CGFloat = 0
    for (index, curve) in curves.enumerated() {
        for step in (index == 0 ? 0 : 1)...stepsPerCurve {
            let t = CGFloat(step) / CGFloat(stepsPerCurve)
            let position = curve.point(t)
            if let last = points.last {
                travelled += hypot(position.x - last.position.x, position.y - last.position.y)
            }
            points.append(SpinePoint(position: position, tangent: curve.tangent(t), fromMouth: travelled))
        }
    }
    return points.map {
        SpinePoint(position: $0.position, tangent: $0.tangent, fromMouth: $0.fromMouth, toTip: travelled - $0.fromMouth)
    }
}

/// Thick where it leaves the mouth, thin in flight, and a sticky club at the tip.
func tongueWidth(fromMouth: CGFloat, toTip: CGFloat) -> CGFloat {
    let root: CGFloat = 20, flight: CGFloat = 11.5, club: CGFloat = 27
    let taper = (root - flight) * (1 - smoothstep(0, 200, fromMouth))
    let swell = (club - flight) * (1 - smoothstep(2, 40, toTip))
    return flight + taper + swell
}

/// Half a circle from one side of the tongue to the other, round its end.
func cap(at point: SpinePoint, radius: CGFloat, forwards: Bool) -> [CGPoint] {
    let steps = 24
    return (0...steps).map { step in
        let angle = CGFloat.pi * CGFloat(step) / CGFloat(steps)
        let side = cos(angle) * radius * (forwards ? 1 : -1)
        let ahead = sin(angle) * radius * (forwards ? 1 : -1)
        return CGPoint(
            x: point.position.x + point.normal.dx * side + point.tangent.dx * ahead,
            y: point.position.y + point.normal.dy * side + point.tangent.dy * ahead)
    }
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

/// The outline of the tongue, grown or shrunk by a margin all the way round.
func tongueShape(_ points: [SpinePoint], grownBy margin: CGFloat) -> CGPath {
    guard let first = points.first, let last = points.last else { return CGMutablePath() }
    var outline = points.map { $0.offset($0.width / 2 + margin) }
    outline += cap(at: last, radius: last.width / 2 + margin, forwards: true)
    outline += points.reversed().map { $0.offset(-$0.width / 2 - margin) }
    outline += cap(at: first, radius: first.width / 2 + margin, forwards: false)
    return polygon(outline)
}

func drawTongue(in context: CGContext) {
    let points = sample(spine)
    guard let last = points.last else { return }

    // The dark line round the tongue is a larger tongue under a smaller one, not a stroke: a
    // stroke along this many short pieces leaves hairline cracks where the curve changes.
    let body = tongueShape(points, grownBy: -outlineWidth / 2)
    context.addPath(tongueShape(points, grownBy: outlineWidth / 2))
    context.setFillColor(Palette.outline)
    context.fillPath()
    context.addPath(body)
    context.setFillColor(Palette.tongue)
    context.fillPath()

    // A lighter facet along the upper side, as the icon's head has: colour meets colour, with
    // no line between. It stops short of the club, which is one plain blob.
    let lit = points.filter { $0.fromMouth > 10 && $0.toTip > 52 }
    let inner = lit.reversed().map { point -> CGPoint in
        let fade = smoothstep(10, 40, point.fromMouth) * smoothstep(52, 92, point.toTip)
        return point.offset(point.width / 2 - outlineWidth / 2 - point.width * 0.24 * fade)
    }
    context.saveGState()
    context.addPath(body)
    context.clip()
    context.addPath(polygon(lit.map { $0.offset($0.width / 2) } + inner))
    context.setFillColor(Palette.tongueLight)
    context.fillPath()
    context.restoreGState()

    // Speed ticks beside the rising part, so that the tongue reads as moving towards the folder.
    context.setStrokeColor(Palette.outline)
    context.setLineWidth(outlineWidth)
    context.setLineCap(.round)
    for (fromMouth, distance, length) in [(93.0, 18.0, 22.0), (108.0, 27.0, 11.0)] {
        guard let at = points.first(where: { $0.fromMouth >= CGFloat(fromMouth) }) else { continue }
        let middle = at.offset(CGFloat(distance))
        let half = CGFloat(length) / 2
        context.move(to: p(middle.x - at.tangent.dx * half, middle.y - at.tangent.dy * half))
        context.addLine(to: p(middle.x + at.tangent.dx * half, middle.y + at.tangent.dy * half))
    }
    // And three where the tip lands, for the snap of the catch.
    let tip = last.position
    for (dx, dy) in [(-0.94, -0.34), (-0.56, -0.83), (0.0, -1.0)] {
        context.move(to: p(tip.x - 6 + CGFloat(dx) * 22, tip.y + CGFloat(dy) * 22))
        context.addLine(to: p(tip.x - 6 + CGFloat(dx) * 30, tip.y + CGFloat(dy) * 30))
    }
    context.strokePath()
}

// MARK: - The ground and the leaves

func outlined(_ points: [CGPoint], fill: CGColor, in context: CGContext) {
    context.addPath(polygon(points))
    context.setFillColor(fill)
    context.fillPath()
    context.addPath(polygon(points))
    context.setStrokeColor(Palette.outline)
    context.setLineWidth(outlineWidth)
    // Sharp points, as the crest in the icon has.
    context.setLineJoin(.miter)
    context.setMiterLimit(6)
    context.strokePath()
}

/// Blades at the two edges of the window, echoing the spikes of the iguana's crest. They stand
/// behind the ground, which hides their feet.
func drawLeaves(in context: CGContext) {
    outlined([p(-16, 258), p(-4, 194), p(14, 258)], fill: Palette.leaf, in: context)
    outlined([p(0, 258), p(29, 174), p(42, 258)], fill: Palette.lime, in: context)
    outlined([p(31, 258), p(63, 206), p(69, 258)], fill: Palette.teal, in: context)

    outlined([p(597, 258), p(611, 210), p(630, 258)], fill: Palette.teal, in: context)
    outlined([p(621, 258), p(644, 184), p(658, 258)], fill: Palette.lime, in: context)
    outlined([p(648, 258), p(667, 202), p(678, 258)], fill: Palette.leaf, in: context)
}

/// The top edge of the ground, from left to right. It is level under the two icons, where
/// their names are written, and breaks into facets between and beside them.
let horizon: [CGPoint] = [
    p(-10, 224), p(38, 242), p(96, 237), p(240, 237), p(314, 228), p(420, 237),
    p(566, 237), p(618, 243), p(670, 226),
]

func drawGround(in context: CGContext) {
    context.addPath(polygon(horizon + [p(670, 430), p(-10, 430)]))
    context.setFillColor(Palette.ground)
    context.fillPath()

    // Darker facets in the bottom corners, clear of the names and of the words.
    context.setFillColor(Palette.groundShade)
    context.addPath(polygon([p(-10, 318), p(118, 430), p(-10, 430)]))
    context.addPath(polygon([p(670, 304), p(548, 430), p(670, 430)]))
    context.fillPath()
    // A low hill between the icons, cut like a gem: one face lit, one half lit. It points down
    // at the words.
    context.setFillColor(Palette.groundLight)
    context.addPath(polygon([p(240, 237), p(314, 228), p(330, 298)]))
    context.fillPath()
    context.setFillColor(Palette.groundHalfLight)
    context.addPath(polygon([p(314, 228), p(420, 237), p(330, 298)]))
    context.fillPath()

    context.addLines(between: horizon)
    context.setStrokeColor(Palette.outline)
    context.setLineWidth(outlineWidth)
    context.setLineJoin(.miter)
    context.setMiterLimit(6)
    context.strokePath()
}

// MARK: - The words

/// The rounded system face where the system has one, to go with the tongue's round ends; the
/// plain system face otherwise.
func systemFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let plain = NSFont.systemFont(ofSize: size, weight: weight)
    if let rounded = plain.fontDescriptor.withDesign(.rounded), let font = NSFont(descriptor: rounded, size: size) {
        return font
    }
    return plain
}

func drawLine(_ text: String, font: NSFont, colour: CGColor, baseline: CGFloat, in context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.saveGState()
    // The canvas counts down from the top and text is drawn counting up, so turn the text over.
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: (canvas.width - width) / 2, y: baseline)
    CTLineDraw(line, context)
    context.restoreGState()
}

func drawWords(in context: CGContext) {
    drawLine(
        "Catch it in Applications.", font: systemFont(size: 22, weight: .semibold),
        colour: Palette.paper, baseline: 342, in: context)
    drawLine(
        "Drag the iguana onto the folder.", font: systemFont(size: 13, weight: .medium),
        colour: Palette.paper.copy(alpha: 0.8) ?? Palette.paper, baseline: 366, in: context)
}

// MARK: - The picture

func render(scale: CGFloat) -> CGImage? {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    // Count from the top left, as Finder does when it places the icons.
    context.translateBy(x: 0, y: canvas.height * scale)
    context.scaleBy(x: scale, y: -scale)
    context.setShouldSmoothFonts(false)

    context.setFillColor(Palette.paper)
    context.fill(CGRect(origin: .zero, size: canvas))
    drawLeaves(in: context)
    drawTongue(in: context)
    drawGround(in: context)
    drawWords(in: context)
    return context.makeImage()
}

func write(_ image: CGImage, scale: CGFloat, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    // 72 dots to the inch for each point, so that the larger file is known to be the same
    // picture at twice the detail and not a picture twice the size.
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

do {
    try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("error: cannot make \(outputFolder.path): \(error.localizedDescription)\n".utf8))
    exit(1)
}
for (name, scale) in [("background.png", CGFloat(1)), ("background@2x.png", CGFloat(2))] {
    let url = outputFolder.appendingPathComponent(name)
    guard let image = render(scale: scale), write(image, scale: scale, to: url) else {
        FileHandle.standardError.write(Data("error: could not write \(url.path)\n".utf8))
        exit(1)
    }
    print("wrote \(url.path) (\(image.width) x \(image.height))")
}
