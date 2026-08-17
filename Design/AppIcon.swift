import AppKit

// Renders the 1024 pt master for the app icon. `Design/render-appicon.sh` runs
// it and slices the result into DumpCompareApp/Assets.xcassets/AppIcon.appiconset,
// so the icon is reproducible: edit the drawing here, run the script, rebuild.
//
// DumpCompare app icon: a chip seen from above, its top face carrying two hex
// bytes large enough to survive a small icon, on a deep navy plate. The second
// byte wears the app's own difference marking — dark glyphs on an orange cell
// (§5) — so the icon states what the app does. 0xFF is the byte a flash dump is
// full of, which makes it the natural one to mark.

let size: CGFloat = 1024

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func gradient(_ from: NSColor, _ to: NSColor) -> NSGradient {
    NSGradient(starting: from, ending: to)!
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
guard let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext

// MARK: Plate

let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let plateRadius: CGFloat = 185
// Deep navy, lit from the top: the darkest ground the light package can sit on
// without the whole tile turning black at small sizes.
gradient(NSColor(srgbRed: 0.15, green: 0.34, blue: 0.56, alpha: 1),
         NSColor(srgbRed: 0.01, green: 0.03, blue: 0.09, alpha: 1))
    .draw(in: rounded(plate, plateRadius), angle: 285)

// A hairline of light along the top rim, so the tile has an edge.
NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setStroke()
let rim = rounded(plate.insetBy(dx: 2.5, dy: 2.5), plateRadius - 2.5)
rim.lineWidth = 5
rim.stroke()

// MARK: Leads

let body = NSRect(x: 232, y: 232, width: 560, height: 560)
let bodyRadius: CGFloat = 116
let leadLength: CGFloat = 92
let leadWidth: CGFloat = 46
let leadCount = 4

/// Lead centres, evenly spread across the flat part of each face.
func leadOffsets() -> [CGFloat] {
    let span = body.width - 2 * (bodyRadius + 6)
    let step = span / CGFloat(leadCount - 1)
    return (0..<leadCount).map { body.minX + bodyRadius + 6 + step * CGFloat($0) }
}

// Pill-shaped leads in a muted slate — clearly lighter than the plate, clearly
// darker than the package, so neither edge disappears.
let leadSlate = gradient(NSColor(srgbRed: 0.53, green: 0.63, blue: 0.75, alpha: 1),
                         NSColor(srgbRed: 0.33, green: 0.43, blue: 0.56, alpha: 1))
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 16,
             color: NSColor(srgbRed: 0, green: 0.01, blue: 0.04, alpha: 0.55).cgColor)
for centre in leadOffsets() {
    let vertical = [NSRect(x: centre - leadWidth / 2, y: body.maxY - 30,
                           width: leadWidth, height: leadLength + 30),
                    NSRect(x: centre - leadWidth / 2, y: body.minY - leadLength,
                           width: leadWidth, height: leadLength + 30)]
    let horizontal = [NSRect(x: body.maxX - 30, y: centre - leadWidth / 2,
                             width: leadLength + 30, height: leadWidth),
                      NSRect(x: body.minX - leadLength, y: centre - leadWidth / 2,
                             width: leadLength + 30, height: leadWidth)]
    for lead in vertical {
        leadSlate.draw(in: rounded(lead, leadWidth / 2), angle: 90)
    }
    for lead in horizontal {
        leadSlate.draw(in: rounded(lead, leadWidth / 2), angle: 0)
    }
}
cg.restoreGState()

// MARK: Body

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -28), blur: 62,
             color: NSColor(srgbRed: 0, green: 0.01, blue: 0.04, alpha: 0.85).cgColor)
gradient(NSColor(srgbRed: 0.73, green: 0.80, blue: 0.87, alpha: 1),
         NSColor(srgbRed: 0.38, green: 0.48, blue: 0.60, alpha: 1))
    .draw(in: rounded(body, bodyRadius), angle: 285)
cg.restoreGState()

// The moulded edge: light along the top, a darker line low down. Two strokes on
// a clipped path, because the package's height is the whole point of the icon.
cg.saveGState()
let bodyPath = rounded(body, bodyRadius)
bodyPath.addClip()
NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45).setStroke()
let highlight = rounded(body.insetBy(dx: 5, dy: 5), bodyRadius - 5)
highlight.lineWidth = 10
highlight.stroke()
cg.restoreGState()
NSColor(srgbRed: 0.05, green: 0.10, blue: 0.18, alpha: 0.35).setStroke()
let bodyEdge = rounded(body.insetBy(dx: 1.5, dy: 1.5), bodyRadius - 1.5)
bodyEdge.lineWidth = 3
bodyEdge.stroke()

// MARK: Hex bytes

// One byte either side of the centre line, each centred in its own half of the
// package: the plain one on its glyphs, the marked one on its difference cell,
// so the orange block sits midway between the line and the package's edge. The
// size is fitted, not fixed — the glyphs grow until the cell would come closer
// to the edge than `edgeMargin`.
let cellPadding: CGFloat = 17
// Equal on both sides of the cell, so "centred between the line and the edge"
// is true by construction once the fitted cell fills the half.
let halfGap: CGFloat = 28
let edgeMargin: CGFloat = 28

func byteWidth(_ font: NSFont) -> CGFloat {
    NSAttributedString(string: "FF", attributes: [.font: font, .kern: 2]).size().width
}

/// The room one byte has: from the divider's side of the gap to the package's
/// edge margin.
let halfRoom = body.width / 2 - halfGap - edgeMargin

let font: NSFont = {
    var size: CGFloat = 220
    while size > 80,
          byteWidth(.monospacedSystemFont(ofSize: size, weight: .bold)) + cellPadding * 2 > halfRoom {
        size -= 2
    }
    return .monospacedSystemFont(ofSize: size, weight: .bold)
}()

// The plain byte is white and carries a heavy shadow; the marked one is near
// black on orange, the way the hex view marks a difference (§5).
let ink = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let markedInk = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1)
let diffOrange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.09, alpha: 1)

func run(_ text: String, _ colour: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour, .kern: 2])
}
let first = run("A5", ink)
let second = run("FF", markedInk)

let leftHalf = NSRect(x: body.minX + edgeMargin, y: body.minY,
                      width: halfRoom, height: body.height)
let rightHalf = NSRect(x: body.midX + halfGap, y: body.minY,
                       width: halfRoom, height: body.height)
let baseline = body.midY - first.size().height / 2 - 6
let firstOrigin = NSPoint(x: leftHalf.midX - first.size().width / 2, y: baseline)
let secondOrigin = NSPoint(x: rightHalf.midX - second.size().width / 2, y: baseline)

// The difference cell behind the marked byte. `draw(at:)` puts the line's
// bottom there, so the baseline is a descender above it; the cell is sized from
// the cap height, the way a hex-view row frames its glyphs.
let baselineY = secondOrigin.y - font.descender
let capHeight = font.capHeight
let cell = NSRect(x: secondOrigin.x - cellPadding,
                  y: baselineY - capHeight * 0.24,
                  width: second.size().width + cellPadding * 2 - 4,
                  height: capHeight * 1.46)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 22,
             color: NSColor(srgbRed: 0.20, green: 0.09, blue: 0, alpha: 0.70).cgColor)
diffOrange.setFill()
rounded(cell, 22).fill()
cg.restoreGState()

// White on a light package needs a deep shadow, drawn twice, or the glyphs go
// soft; the marked byte needs none — its cell already separates it.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -9), blur: 18,
             color: NSColor(srgbRed: 0.02, green: 0.06, blue: 0.13, alpha: 0.75).cgColor)
first.draw(at: firstOrigin)
first.draw(at: firstOrigin)
cg.restoreGState()
second.draw(at: secondOrigin)

// MARK: Divider

// The centre line: what separates file A from file B in every part of this app,
// cut into the package as a groove — dark, with a lit edge on its right.
let dividerWidth: CGFloat = 12
let divider = NSRect(x: body.midX - dividerWidth / 2, y: body.minY + 74,
                     width: dividerWidth, height: body.height - 148)
NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45).setFill()
rounded(divider.offsetBy(dx: 6, dy: 0), dividerWidth / 2).fill()
NSColor(srgbRed: 0.04, green: 0.09, blue: 0.17, alpha: 0.72).setFill()
rounded(divider, dividerWidth / 2).fill()

// MARK: Sheen

// Kept off the marked cell: a wash over the orange is exactly the paling that
// makes the highlight look washed out.
cg.saveGState()
rounded(body, bodyRadius).addClip()
gradient(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12),
         NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)).draw(in: body, angle: 285)
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon-1024.png"
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: output))
print("wrote \(output) — glyphs at \(font.pointSize) pt")
