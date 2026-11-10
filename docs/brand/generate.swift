// Draws every image in the orbit brand kit from code, so the art stays pixel-exact and reproducible.
//
//     swift docs/brand/generate.swift        (run from the repository root)
//
// All art lives on integer pixel grids and is only ever enlarged by whole numbers with nearest-neighbour
// sampling. The wordmark is Monocraft (SIL OFL 1.1, docs/brand/fonts/), rasterized on its native grid.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (the only eight colours the brand uses)

typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

func hex(_ s: String) -> RGBA {
    let v = UInt32(s.dropFirst(), radix: 16)!
    return (UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255), 255)
}

let palette: [(name: String, hex: String)] = [
    ("Void", "#060606"), ("Graphite", "#2b2b2b"), ("Iron", "#3d3d3d"), ("Slate", "#5c5c5c"),
    ("Ash", "#808080"), ("Fog", "#b5b5b5"), ("Mist", "#ebebeb"), ("White", "#ffffff"),
]
let void = hex("#060606"), graphite = hex("#2b2b2b"), iron = hex("#3d3d3d"), slate = hex("#5c5c5c")
let ash = hex("#808080"), fog = hex("#b5b5b5"), mist = hex("#ebebeb"), white = hex("#ffffff")
let clear: RGBA = (0, 0, 0, 0)

func same(_ a: RGBA, _ b: RGBA) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a }

// MARK: - Canvas

struct Canvas {
    let w: Int, h: Int
    var px: [RGBA]

    init(_ w: Int, _ h: Int, _ fill: RGBA = clear) {
        self.w = w; self.h = h; px = Array(repeating: fill, count: w * h)
    }

    subscript(x: Int, y: Int) -> RGBA {
        get { x >= 0 && y >= 0 && x < w && y < h ? px[y * w + x] : clear }
        set { if x >= 0, y >= 0, x < w, y < h { px[y * w + x] = newValue } }
    }

    mutating func blit(_ o: Canvas, _ ox: Int, _ oy: Int) {
        for y in 0..<o.h { for x in 0..<o.w where o[x, y].a > 0 { self[ox + x, oy + y] = o[x, y] } }
    }

    /// Crops to the opaque content plus `margin` empty pixels on every side.
    func trimmed(margin: Int = 0) -> Canvas {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where self[x, y].a > 0 {
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        } }
        var c = Canvas(x1 - x0 + 1 + margin * 2, y1 - y0 + 1 + margin * 2)
        for y in y0...y1 { for x in x0...x1 { c[x - x0 + margin, y - y0 + margin] = self[x, y] } }
        return c
    }

    /// `opaque` drops the alpha channel, which App Store validation requires for the app icon.
    func save(_ path: String, scale: Int, opaque: Bool = false) {
        let W = w * scale, H = h * scale
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H { for x in 0..<W {
            let c = self[x / scale, y / scale], i = (y * W + x) * 4, a = Int(c.a)
            bytes[i] = UInt8(Int(c.r) * a / 255); bytes[i + 1] = UInt8(Int(c.g) * a / 255)
            bytes[i + 2] = UInt8(Int(c.b) * a / 255); bytes[i + 3] = c.a
        } }
        let ctx = CGContext(data: &bytes, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
        let url = URL(fileURLWithPath: path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(path) (\(W)×\(H))")
    }
}

// MARK: - Type: Monocraft on its native grid (120 font units = 1 pixel, so 9 pt = 1 px per font pixel)

let root = "docs/brand"
let fontPath = "\(root)/fonts/Monocraft.ttf"

func textMask(_ text: String) -> [[Bool]] {
    let G = 100  // render each font pixel as a 100×100 block, then sample block centres
    let descs = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: fontPath) as CFURL) as! [CTFontDescriptor]
    let font = CTFontCreateWithFontDescriptor(descs[0], CGFloat(9 * G), nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]))
    let cols = text.count * 8 + 4, rows = 16, W = cols * G, H = rows * G
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    ctx.setShouldAntialias(false)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.textPosition = CGPoint(x: 2 * G, y: 5 * G)
    CTLineDraw(line, ctx)
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let m = (0..<rows).map { r in (0..<cols).map { c in p[(r * G + G / 2) * W + c * G + G / 2] > 127 } }
    let ys = m.indices.filter { m[$0].contains(true) }
    let xs = (0..<cols).filter { c in m.contains { $0[c] } }
    return (ys.first!...ys.last!).map { r in Array(m[r][xs.first!...xs.last!]) }
}

/// Minecraft-style title text: a two-tone fill (lighter top rows) with a hard 1px shadow down-right.
func text(_ s: String, top: RGBA, bottom: RGBA, shadow: RGBA?) -> Canvas {
    let m = textMask(s), mh = m.count, mw = m[0].count
    var c = Canvas(mw + 1, mh + 1)
    if let shadow { for y in 0..<mh { for x in 0..<mw where m[y][x] { c[x + 1, y + 1] = shadow } } }
    for y in 0..<mh { for x in 0..<mw where m[y][x] { c[x, y] = y < mh * 3 / 5 ? top : bottom } }
    return c.trimmed()
}

// MARK: - The mark: a planet with a satellite on a tilted orbit (32×32 grid)

let N = 32
let cx = 16.0, cy = 16.0, R = 8.35
let rx = 13.6, ry = 4.4, tilt = -0.36

func inPlanet(_ x: Int, _ y: Int) -> Bool {
    let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
    return dx * dx + dy * dy <= R * R
}

func orbitPoint(_ t: Double) -> (Double, Double) {
    let ex = rx * cos(t), ey = ry * sin(t)
    return (cx + ex * cos(tilt) - ey * sin(tilt), cy + ex * sin(tilt) + ey * cos(tilt))
}

/// The orbit as a clean 1px line. `front` is the near half, which passes in front of the planet.
let orbit: [(x: Int, y: Int, front: Bool)] = {
    var path = [(x: Int, y: Int, front: Bool)]()
    for i in 0..<4000 {
        let t = Double(i) / 4000 * 2 * .pi, (x, y) = orbitPoint(t)
        let p = (x: Int(x.rounded(.down)), y: Int(y.rounded(.down)), front: sin(t) > 0)
        if let l = path.last, l.x == p.x, l.y == p.y { continue }
        path.append(p)
    }
    // Drop L-shaped elbow pixels so the line steps diagonally (never two in a row, or it would break).
    var keep = [(x: Int, y: Int, front: Bool)](), dropped = false
    for (i, p) in path.enumerated() {
        let a = path[(i - 1 + path.count) % path.count], b = path[(i + 1) % path.count]
        if !dropped && abs(a.x - b.x) == 1 && abs(a.y - b.y) == 1 { dropped = true; continue }
        dropped = false
        keep.append(p)
    }
    var seen = Set<Int>()
    return keep.filter { seen.insert($0.y * N + $0.x).inserted }
}()

enum Part { case panelLit, panel, strut, body, bodyShade, beacon }

/// Satellite sprite, anchored on the near-left part of the orbit where it sits in open space.
let satellite: [(x: Int, y: Int, part: Part)] = {
    let (sx, sy) = orbitPoint(0.85 * .pi)
    let bx = Int(sx.rounded(.down)), by = Int(sy.rounded(.down))
    var s = [(x: Int, y: Int, part: Part)]()
    for dx in [-3, -2, 2, 3] { s.append((bx + dx, by - 1, .panelLit)); s.append((bx + dx, by, .panel)) }
    s += [(bx - 1, by - 1, .strut), (bx + 1, by - 1, .strut),
          (bx, by - 2, .body), (bx, by - 1, .body), (bx, by, .bodyShade), (bx, by - 3, .beacon)]
    return s
}()

/// 4-neighbours of the satellite body and panels (not the beacon), used for its outline or knockout.
let satelliteHalo: [(x: Int, y: Int)] = {
    let cells = Set(satellite.map { $0.y * N + $0.x })
    var halo = Set<Int>()
    for s in satellite where s.part != .beacon {
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where !cells.contains((s.y + dy) * N + s.x + dx) {
            halo.insert((s.y + dy) * N + s.x + dx)
        }
    }
    return halo.map { (x: $0 % N, y: $0 / N) }
}()

struct Theme {
    var sky: RGBA? = nil
    var stars = false
    var starColors: (bright: RGBA, dim: RGBA, twinkle: RGBA, twinkleArms: RGBA) = (mist, slate, white, ash)
    var orbitFront: [RGBA]          // lit (left) → far (right)
    var orbitBack: RGBA
    var orbitOverPlanet: RGBA? = nil // where the near arc crosses the planet, if it needs more contrast
    var planet: [RGBA]              // six tones, dark → light
    var rim: RGBA                   // bounce light on the shadowed edge
    var planetOutline: RGBA? = nil  // needed only on light backgrounds
    var sat: [Part: RGBA]
    var satOutline: RGBA? = nil
}

let onDark = Theme(
    orbitFront: [white, mist, fog], orbitBack: slate,
    planet: [graphite, iron, slate, ash, fog, mist], rim: iron,
    sat: [.panelLit: ash, .panel: iron, .strut: ash, .body: white, .bodyShade: ash, .beacon: white],
    satOutline: void)

let onLight = Theme(
    orbitFront: [void, graphite, iron], orbitBack: fog, orbitOverPlanet: white,
    planet: [graphite, iron, slate, ash, fog, mist], rim: iron, planetOutline: graphite,
    sat: [.panelLit: ash, .panel: slate, .strut: graphite, .body: graphite, .bodyShade: void, .beacon: void],
    satOutline: white)

func mark(_ th: Theme) -> Canvas {
    var c = Canvas(N, N, th.sky ?? clear)
    func checker(_ x: Int, _ y: Int) -> Bool { (x + y) % 2 == 0 }

    if th.stars {
        let sc = th.starColors
        for (x, y) in [(4, 4), (27, 4), (5, 27), (29, 24), (12, 2), (23, 29), (2, 17)] { c[x, y] = sc.bright }
        for (x, y) in [(8, 8), (30, 14), (14, 29), (25, 26)] { c[x, y] = sc.dim }
        c[26, 7] = sc.twinkle
        for (x, y) in [(25, 7), (27, 7), (26, 6), (26, 8)] { c[x, y] = sc.twinkleArms }
    }

    for p in orbit where !p.front && !inPlanet(p.x, p.y) { c[p.x, p.y] = th.orbitBack }

    if let o = th.planetOutline {
        for y in 0..<N { for x in 0..<N where !inPlanet(x, y) {
            if inPlanet(x + 1, y) || inPlanet(x - 1, y) || inPlanet(x, y + 1) || inPlanet(x, y - 1) { c[x, y] = o }
        } }
    }

    // Light from the upper left; flat tones with a checker seam only right at each tone boundary.
    let L: (Double, Double, Double) = {
        let v = (-0.5, -0.62, 0.6), n = sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2)
        return (v.0 / n, v.1 / n, v.2 / n)
    }()
    for y in 0..<N { for x in 0..<N where inPlanet(x, y) {
        let dx = (Double(x) + 0.5 - cx) / R, dy = (Double(y) + 0.5 - cy) / R
        let dz = sqrt(max(0, 1 - dx * dx - dy * dy))
        let l = dx * L.0 + dy * L.1 + dz * L.2
        let t = max(0, min(0.999, (l + 0.02) / 1.12)) * Double(th.planet.count)
        var idx = Int(t)
        if t - Double(idx) > 0.82 && checker(x, y) { idx = min(th.planet.count - 1, idx + 1) }
        let rim = dx * dx + dy * dy > 0.78 && dx + dy > 0.6 && idx <= 1
        c[x, y] = rim ? th.rim : th.planet[idx]
    } }

    for p in orbit where p.front {
        let lit = Double(p.x) / Double(N)
        c[p.x, p.y] = inPlanet(p.x, p.y) ? th.orbitOverPlanet ?? th.orbitFront[lit < 0.35 ? 0 : lit < 0.7 ? 1 : 2]
                                         : th.orbitFront[lit < 0.35 ? 0 : lit < 0.7 ? 1 : 2]
    }

    if let o = th.satOutline { for h in satelliteHalo { c[h.x, h.y] = o } }
    for s in satellite { c[s.x, s.y] = th.sat[s.part]! }
    return c
}

/// One-colour mark for stamps, embossing, single-ink print and template images: a solid planet,
/// with a 1px knockout gap wherever the orbit or the satellite crosses in front of it.
func monoMark(_ ink: RGBA) -> Canvas {
    var c = Canvas(N, N)
    for y in 0..<N { for x in 0..<N where inPlanet(x, y) { c[x, y] = ink } }
    for p in orbit where !p.front && !inPlanet(p.x, p.y) { c[p.x, p.y] = ink }
    let front = Set(orbit.filter { $0.front }.map { $0.y * N + $0.x })
    for p in orbit where p.front {
        for dy in [-1, 1] where !front.contains((p.y + dy) * N + p.x) { c[p.x, p.y + dy] = clear }
    }
    for p in orbit where p.front { c[p.x, p.y] = ink }
    for s in satellite { for dy in -1...1 { for dx in -1...1 { c[s.x + dx, s.y + dy] = clear } } }
    for s in satellite { c[s.x, s.y] = ink }
    return c
}

// MARK: - Compositions

func lockup(_ m: Canvas, _ word: Canvas, stacked: Bool) -> Canvas {
    let mt = m.trimmed()
    if stacked {
        var c = Canvas(max(mt.w, word.w), mt.h + 4 + word.h)
        c.blit(mt, (c.w - mt.w) / 2, 0)
        c.blit(word, (c.w - word.w) / 2, mt.h + 4)
        return c
    }
    var c = Canvas(mt.w + 5 + word.w, max(mt.h, word.h))
    c.blit(mt, 0, (c.h - mt.h) / 2)
    c.blit(word, mt.w + 5, (c.h - word.h) / 2)
    return c
}

/// A starfield background with `art` centred. Stars are seeded so every run is identical.
func banner(_ w: Int, _ h: Int, _ art: Canvas) -> Canvas {
    var c = Canvas(w, h, void)
    var seed: UInt64 = 0x0b17
    func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
    let ox = (w - art.w) / 2, oy = (h - art.h) / 2
    for _ in 0..<(w * h / 90) {
        let x = rnd(w), y = rnd(h)
        if x >= ox - 3 && x < ox + art.w + 3 && y >= oy - 3 && y < oy + art.h + 3 { continue }
        c[x, y] = [slate, slate, iron, ash, mist][rnd(5)]
    }
    c.blit(art, ox, oy)
    return c
}

func paletteSheet() -> Canvas {
    let rowH = 24, sw = 18
    var c = Canvas(110, palette.count * rowH + 4, void)
    for (i, p) in palette.enumerated() {
        let y0 = 4 + i * rowH
        for y in 0..<sw { for x in 0..<sw { c[4 + x, y0 + y] = hex(p.hex) } }
        if p.name == "Void" {  // outline the swatch that matches the sheet
            for k in 0..<sw { c[4 + k, y0] = iron; c[4 + k, y0 + sw - 1] = iron; c[4, y0 + k] = iron; c[3 + sw, y0 + k] = iron }
        }
        c.blit(text(p.name, top: white, bottom: mist, shadow: iron), 4 + sw + 5, y0 + 1)
        c.blit(text(p.hex.uppercased(), top: ash, bottom: ash, shadow: nil), 4 + sw + 5, y0 + 11)
    }
    return c
}

// MARK: - Output

let wordWhite = text("orbit", top: white, bottom: mist, shadow: slate)
let wordBlack = text("orbit", top: void, bottom: graphite, shadow: mist)
let markDark = mark(onDark), markLight = mark(onLight)

// Logo
markDark.save("\(root)/logo/mark-on-dark.png", scale: 16)
markLight.save("\(root)/logo/mark-on-light.png", scale: 16)
monoMark(void).save("\(root)/logo/mark-mono-black.png", scale: 16)
monoMark(white).save("\(root)/logo/mark-mono-white.png", scale: 16)

// Wordmark
wordWhite.save("\(root)/wordmark/wordmark-on-dark.png", scale: 16)
wordBlack.save("\(root)/wordmark/wordmark-on-light.png", scale: 16)

// Lockups
lockup(markDark, wordWhite, stacked: false).save("\(root)/lockup/lockup-horizontal-on-dark.png", scale: 12)
lockup(markLight, wordBlack, stacked: false).save("\(root)/lockup/lockup-horizontal-on-light.png", scale: 12)
lockup(markDark, wordWhite, stacked: true).save("\(root)/lockup/lockup-stacked-on-dark.png", scale: 12)
lockup(markLight, wordBlack, stacked: true).save("\(root)/lockup/lockup-stacked-on-light.png", scale: 12)

// App icon: whole-number enlargements of the 32px grid only, so every art pixel stays square.
var appIcon = onDark; appIcon.sky = void; appIcon.stars = true
let icon = mark(appIcon)
for size in [32, 64, 128, 256, 512, 1024] { icon.save("\(root)/app-icon/icon-\(size).png", scale: size / N, opaque: true) }
mark(onDark).save("\(root)/app-icon/icon-dark-1024.png", scale: 32)   // iOS dark appearance: no background
icon.save("\(root)/app-icon/icon-tinted-1024.png", scale: 32, opaque: true) // iOS tinted: grayscale, opaque

// The app's own AppIcon set, kept in sync with the kit (single-size iOS icon with dark and tinted looks).
let appIconSet = "orbit/Resources/Assets.xcassets/AppIcon.appiconset"
icon.save("\(appIconSet)/AppIcon.png", scale: 32, opaque: true)
mark(onDark).save("\(appIconSet)/AppIcon-Dark.png", scale: 32)
icon.save("\(appIconSet)/AppIcon-Tinted.png", scale: 32, opaque: true)
// In-app branding at 1× (one art pixel per point). SwiftUI enlarges it by whole numbers with
// `.interpolation(.none)`, so it stays sharp at any size without shipping big PNGs.
let lockupSet = "orbit/Resources/Assets.xcassets/Lockup.imageset"
lockup(markLight, wordBlack, stacked: true).save("\(lockupSet)/Lockup-Light.png", scale: 1)
lockup(markDark, wordWhite, stacked: true).save("\(lockupSet)/Lockup-Dark.png", scale: 1)
// Light variant: white sky with dark stars, for an alternate icon or light-themed placements.
var lightIcon = onLight; lightIcon.sky = white; lightIcon.stars = true
lightIcon.starColors = (slate, fog, graphite, fog)
let iconLight = mark(lightIcon)
for size in [256, 1024] { iconLight.save("\(root)/app-icon/icon-light-\(size).png", scale: size / N) }

// Social
let wide = lockup(markDark, wordWhite, stacked: false)
banner(128, 64, wide).save("\(root)/social/github-social-preview.png", scale: 10)  // 1280×640
banner(200, 50, wide).save("\(root)/social/readme-banner.png", scale: 8)           // 1600×400

// Colour
paletteSheet().save("\(root)/colors/palette.png", scale: 6)
var gpl = "GIMP Palette\nName: orbit\nColumns: 8\n#\n"
for p in palette {
    let c = hex(p.hex)
    gpl += "\(String(c.r).leftPad(3)) \(String(c.g).leftPad(3)) \(String(c.b).leftPad(3))\t\(p.name)\n"
}
try! gpl.write(toFile: "\(root)/colors/orbit.gpl", atomically: true, encoding: .utf8)
print("wrote \(root)/colors/orbit.gpl")

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
}

// MARK: - Previews (docs only)

/// Transparent assets disappear on a page of the same colour (a white wordmark on GitHub's light theme),
/// so the guidelines show these tiles instead: each asset on the background it was made for, padded by
/// the 4-pixel clear space.
func tile(_ art: Canvas, on bg: RGBA) -> Canvas {
    let a = art.trimmed()
    var c = Canvas(a.w + 8, a.h + 8, bg)
    c.blit(a, 4, 4)
    return c
}

let previews: [(String, Canvas, RGBA, Int)] = [
    ("mark-on-dark", markDark, void, 8), ("mark-on-light", markLight, white, 8),
    ("mark-mono-white", monoMark(white), void, 8), ("mark-mono-black", monoMark(void), white, 8),
    ("wordmark-on-dark", wordWhite, void, 8), ("wordmark-on-light", wordBlack, white, 8),
    ("lockup-horizontal-on-dark", lockup(markDark, wordWhite, stacked: false), void, 6),
    ("lockup-horizontal-on-light", lockup(markLight, wordBlack, stacked: false), white, 6),
    ("lockup-stacked-on-dark", lockup(markDark, wordWhite, stacked: true), void, 6),
    ("lockup-stacked-on-light", lockup(markLight, wordBlack, stacked: true), white, 6),
]
for (name, art, bg, scale) in previews { tile(art, on: bg).save("\(root)/preview/\(name).png", scale: scale) }
// The dark-appearance icon is transparent; iOS draws it over a dark backdrop, so preview it on Void.
var darkBackdrop = Canvas(N, N, void); darkBackdrop.blit(mark(onDark), 0, 0)
darkBackdrop.save("\(root)/preview/icon-dark.png", scale: 8)
