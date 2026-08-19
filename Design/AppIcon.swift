import AppKit

// Renders the 1024 pt master for the app icon. `Design/render-appicon.sh` runs
// it and slices the result into DumpCompareApp/Assets.xcassets/AppIcon.appiconset,
// so the icon is reproducible: edit the drawing here, run the script, rebuild.
//
// DumpCompare app icon: a black flash chip seen from above, free-standing on a
// transparent background — no plate, so the package itself is the icon's shape.
// The body is a wide rectangle spanning the full width, with one row of five
// polished leads above and one below, and it carries two hex bytes big enough to
// survive a small icon. The second byte wears the app's own difference marking —
// dark glyphs on an orange cell (§5) — so the icon states what the app does.
// 0xFF is the byte a flash dump is full of, which makes it the natural one to
// mark. Two bytes, one of them marked, is the whole statement: nothing divides
// them, because the marked cell already separates them.

let size: CGFloat = 1024

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func gradient(_ from: NSColor, _ to: NSColor) -> NSGradient {
    NSGradient(starting: from, ending: to)!
}

func grey(_ level: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: level, green: level, blue: level, alpha: alpha)
}

/// A multi-stop gradient, for the metal of the leads — two stops cannot describe
/// a lit cylinder.
func gradient(_ stops: [(CGFloat, NSColor)]) -> NSGradient {
    NSGradient(colors: stops.map(\.1),
               atLocations: stops.map(\.0),
               colorSpace: .sRGB)!
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

// MARK: Geometry

// The package runs the full width of the tile, with only enough margin left for
// its own shadow; the leads take the room above and below it. Everything else
// is measured from this rectangle.
//
// The height is not what the type needs — the byte size is limited by the width,
// so a taller package only adds plastic. It is what the tile needs: with a
// shallow body the artwork sat in a band across the middle of a square icon and
// left a quarter of it empty top and bottom. Body plus leads now covers 784 of
// the 1024, and the package reads as one with a marking on it rather than a
// label with a chip drawn round it. The extra height goes into the body, not the
// leads: long legs turn spindly at 32 pt and make the chip read as a DIP through
// a magnifier.
let body = NSRect(x: 22, y: 232, width: 980, height: 560)
let bodyRadius: CGFloat = 60

let leadCount = 5
let leadWidth: CGFloat = 86
let leadLength: CGFloat = 112
let leadRadius: CGFloat = 20
/// How far each lead runs under the package, so it emerges from beneath it
/// rather than being butt-joined to the edge.
let leadOverlap: CGFloat = 26

let castShadow = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42).cgColor

// MARK: Leads

/// Lead centres, spread evenly across the body's flat span.
func leadCentres() -> [CGFloat] {
    let inset = bodyRadius + 44
    let span = body.width - 2 * inset
    let step = span / CGFloat(leadCount - 1)
    return (0..<leadCount).map { body.minX + inset + step * CGFloat($0) }
}

// Polished metal: a bright specular band just off the lead's centre line, dark
// at both edges. Drawn across the lead's short axis, which for these top and
// bottom rows is horizontal.
let leadMetal = gradient([(0.00, grey(0.28)),
                          (0.14, grey(0.62)),
                          (0.34, grey(0.97)),
                          (0.52, grey(0.74)),
                          (0.78, grey(0.38)),
                          (1.00, grey(0.20))])

// The leads go down first: the package is drawn over them, hiding the ends that
// run underneath it.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: castShadow)
for centre in leadCentres() {
    let x = centre - leadWidth / 2
    let top = NSRect(x: x, y: body.maxY - leadOverlap,
                     width: leadWidth, height: leadLength + leadOverlap)
    let bottom = NSRect(x: x, y: body.minY - leadLength,
                        width: leadWidth, height: leadLength + leadOverlap)
    for lead in [top, bottom] {
        leadMetal.draw(in: rounded(lead, leadRadius), angle: 0)
    }
}
cg.restoreGState()

// A cool sheen along the outer tip of each lead, so the metal looks turned
// towards the light rather than flat.
for centre in leadCentres() {
    let x = centre - leadWidth / 2
    let tips = [NSRect(x: x + 8, y: body.maxY + leadLength - 26, width: leadWidth - 16, height: 14),
                NSRect(x: x + 8, y: body.minY - leadLength + 12, width: leadWidth - 16, height: 14)]
    for tip in tips {
        gradient(grey(1, 0.55), grey(1, 0)).draw(in: rounded(tip, 7), angle: 90)
    }
}

// MARK: Body

let bodyPath = rounded(body, bodyRadius)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: castShadow)
// Black moulded plastic, lit from above: never fully black at the top, or the
// package loses its volume; near black at the bottom, so it still reads black.
gradient([(0.00, grey(0.035)),
          (0.42, grey(0.075)),
          (0.86, grey(0.155)),
          (1.00, grey(0.235))])
    .draw(in: bodyPath, angle: 90)
cg.restoreGState()

// The moulded edge, drawn on a clipped path: a lit top rim — which is also what
// keeps the silhouette visible against a dark Dock — and a thin dark line low
// down where the plastic turns away.
cg.saveGState()
bodyPath.addClip()
grey(1, 0.30).setStroke()
let topRim = rounded(body.insetBy(dx: 4, dy: 4), bodyRadius - 4)
topRim.lineWidth = 8
topRim.stroke()
// Over the lower half of that stroke again, in the plastic's own dark, so the
// rim light stays where the light is.
grey(0.05, 0.85).setStroke()
cg.saveGState()
NSBezierPath(rect: NSRect(x: body.minX, y: body.minY,
                          width: body.width, height: body.height * 0.42)).addClip()
topRim.stroke()
cg.restoreGState()
cg.restoreGState()

// MARK: Glare

// One small highlight over the top left of the package — the sheen a glossy
// moulded surface picks up — laid down before the type, so the glyphs stay
// crisp. It is a radial falloff rather than a shaped streak: any edge of its own
// reads as a grey patch stuck on the plastic instead of light on it.
cg.saveGState()
bodyPath.addClip()
// The falloff has to reach zero well inside the rect it is drawn in: a radial
// gradient is clipped by that rect, so a box drawn tight around the highlight
// cuts the fade off mid-slope and leaves a seam straight across the package.
let glareCentre = NSPoint(x: body.minX + 190, y: body.maxY - 120)
let glareRadius: CGFloat = 540
gradient([(0.00, grey(1, 0.20)),
          (0.22, grey(1, 0.10)),
          (0.42, grey(1, 0.03)),
          (0.60, grey(1, 0)),
          (1.00, grey(1, 0))])
    .draw(in: NSRect(x: glareCentre.x - glareRadius, y: glareCentre.y - glareRadius,
                     width: glareRadius * 2, height: glareRadius * 2),
          relativeCenterPosition: .zero)
cg.restoreGState()

// MARK: Hex bytes

// One byte either side of the package's centre, each centred in its own half:
// the plain one on its glyphs, the marked one on its difference cell, so the
// orange block sits midway between the centre and the package's edge. The size
// is fitted, not fixed — the glyphs grow until either the cell would come closer
// to the edge than `edgeMargin`, or it would come within `topMargin` of the
// moulded rim. On this wide package that lands far above the old square one's
// 220 pt; the width is what binds, which is why a taller body does not grow it.
let cellPadding: CGFloat = 20
// The gap left either side of the centre, so the two bytes read as two fields
// with nothing drawn between them.
let halfGap: CGFloat = 30
let edgeMargin: CGFloat = 56
let topMargin: CGFloat = 44

func byteWidth(_ font: NSFont) -> CGFloat {
    NSAttributedString(string: "FF", attributes: [.font: font, .kern: 2]).size().width
}

/// The proportions of the difference cell, as fractions of the fitted cap
/// height — the way a hex-view row frames its glyphs.
let cellLift: CGFloat = 0.24
let cellHeightRatio: CGFloat = 1.46

/// The room one byte has: from its side of the centre gap to the package's edge
/// margin, and between the package's rims.
let halfRoom = body.width / 2 - halfGap - edgeMargin
let heightRoom = body.height - 2 * topMargin

let font: NSFont = {
    var size: CGFloat = 400
    while size > 100 {
        let candidate = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let fitsWidth = byteWidth(candidate) + cellPadding * 2 <= halfRoom
        let fitsHeight = candidate.capHeight * cellHeightRatio <= heightRoom
        if fitsWidth && fitsHeight { return candidate }
        size -= 2
    }
    return .monospacedSystemFont(ofSize: size, weight: .bold)
}()

// The plain byte is white and carries a shadow to seat it on the plastic; the
// marked one is near black on orange, the way the hex view marks a difference
// (§5).
let ink = grey(1)
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
// The difference cell behind the marked byte. `draw(at:)` puts the line's
// bottom at the origin, so the baseline is a descender above it; the cell is
// sized from the cap height.
//
// What has to sit in the middle of the package is the cell, not the text line:
// the line's box is taller than its caps and lopsided about them, so centring
// that box left the orange block visibly high. The provisional baseline is
// placed, the cell measured from it, and both then lifted by whatever it takes
// to centre the block — the glyphs travel with it, so they stay on its baseline.
let provisionalBaseline = body.midY - first.size().height / 2
let capHeight = font.capHeight
let cellHeight = capHeight * cellHeightRatio
let cellBottom = provisionalBaseline - font.descender - capHeight * cellLift
let lift = body.midY - (cellBottom + cellHeight / 2)

let baseline = provisionalBaseline + lift
let firstOrigin = NSPoint(x: leftHalf.midX - first.size().width / 2, y: baseline)
let secondOrigin = NSPoint(x: rightHalf.midX - second.size().width / 2, y: baseline)
let cell = NSRect(x: secondOrigin.x - cellPadding,
                  y: cellBottom + lift,
                  width: second.size().width + cellPadding * 2 - 4,
                  height: cellHeight)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 26,
             color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65).cgColor)
diffOrange.setFill()
rounded(cell, 26).fill()
cg.restoreGState()

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 16,
             color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65).cgColor)
first.draw(at: firstOrigin)
cg.restoreGState()
second.draw(at: secondOrigin)

NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon-1024.png"
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: output))
print("wrote \(output) — glyphs at \(font.pointSize) pt")
