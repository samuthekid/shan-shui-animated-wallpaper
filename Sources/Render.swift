import AppKit
import IOSurface

// Constants, tile geometry, chunk data, and drawing the tiles. (Parser.swift reads the chunks, Paper.swift is the paper.)
// Globals here (sRGB) and in Paper.swift (paper) are lazy in Swift: no order between files matters.
// Layers, bottom to top: paper, far hills, near mountains. Plain alpha blending only.
// Upstream multiplies the drawing onto the paper. The same picture comes from normal blending when
//   near pixel = paper * ink, with the alpha of the shape (the paper is baked into the near tiles), and
//   far pixel  = black with alpha (1 - gray)  (far hills are gray, so multiply = black ink with alpha).

enum K {
    static let viewH = 700.0   // world units from top to bottom (upstream: 800 px / zoom 1.142)
    static let tileW = 128.0   // world units per tile
    static let paperW = 512    // paper texture in texels. One texel is one world unit.
    static let paperH = 700
    static let parallax = 0.5  // far layer speed relative to the near layer
    static let ahead = 2       // least number of tiles that stay ready past the right edge
    static let leadSeconds = 10.0  // ...and at least this many seconds of pan travel (matters at high speed only)
    static let reach = 1200.0  // an item can reach this far from the slice that planned it
    static let maxSpeed = 60.0    // the top of the speed slider, points per second. The lead is made for this speed.
    static let farMaxHeight = 1000.0  // a far tile is at most about this many pixels high (far hills are soft)
    static let pixelScale = 1.0  // tile pixels per point (1 = 1x tiles, 2 = Retina). Tiles are stretched to the point size.
    static let rebaseDistance = 20000.0  // points of travel (from the base) after which the layers start again near zero
    static let panLength = 30000.0  // points that one pan animation covers before it ends
    static let scratchSize = 1 << 20  // first size of the engine text buffer, in bytes
    static let paperColor = CGColor(red: 0.96, green: 0.91, blue: 0.82, alpha: 1)  // the paper, until the first tile is there
    static let fps60 = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)  // pan and fade ask for 60 fps
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue  // BGRA
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: geometry

// A tile is tileW world units wide and as high as the screen. All sizes are whole pixels.
struct Geo {
    let scale: Double          // backing scale of the screen (only for the PNG export size in points)
    let px: Double             // pixels per point of the tiles (K.pixelScale, or the backing scale for the PNG export)
    let wPts: Double, hPts: Double
    let pxW: Int, pxH: Int     // near tile in pixels
    let fpxW: Int, fpxH: Int   // far tile in pixels (smaller, shown stretched to the size of a near tile)
    let pn: Double, pf: Double // pixels per world unit, near and far
    var sPts: Double { pn / px }  // points per world unit
    var wUnits: Double { wPts / sPts }  // visible width in world units

    init(wPts: Double, hPts: Double, scale: Double, pixelScale: Double = K.pixelScale) {
        px = pixelScale
        self.wPts = wPts
        self.hPts = hPts
        self.scale = scale
        let half = max(1, Int((K.tileW * hPts * px / K.viewH / 2).rounded()))
        pxW = half * 2
        pxH = Int((hPts * px).rounded(.up))
        pn = Double(pxW) / K.tileW
        // Far pixels per point: half of the backing scale, but not more than farMaxHeight pixels for the whole height.
        // The far tile covers the same world area as a near tile, so it fits the near tile exactly when stretched.
        let farScale = min(px / 2, K.farMaxHeight / hPts)
        fpxW = max(1, Int((Double(pxW) / px * farScale).rounded()))
        pf = Double(fpxW) / K.tileW
        fpxH = max(1, Int((Double(pxH) / pn * pf).rounded()))
    }
}

// MARK: chunks

struct Poly {
    var fill: UInt32, stroke: UInt32  // packed r g b a, a = 0 means none
    var width: Float
    var start: Int32, count: Int32    // the points are Chunk.pts[start ..< start + 2 * count]
    var minX: Float, maxX: Float      // relative to the origin of the chunk
}

final class Chunk {
    let near: Bool
    let ox: Double  // origin of the chunk (local world units). Points are relative to it: a Float is exact enough there,
                    // but not at x = millions (days of panning).
    let y: Double   // painter's order key
    let polys: [Poly]
    let pts: [Float]  // x y x y ...  x relative to ox
    var minX = Double.infinity, maxX = -Double.infinity  // the extent in local world units

    init(near: Bool, ox: Double, y: Double, polys: [Poly], pts: [Float]) {
        self.near = near
        self.ox = ox
        self.y = y
        self.polys = polys
        self.pts = pts
        for p in polys {
            minX = min(minX, ox + Double(p.minX - p.width))
            maxX = max(maxX, ox + Double(p.maxX + p.width))
        }
    }
}

// MARK: rasterizer

func rgba(_ c: UInt32) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    (CGFloat(c >> 24) / 255, CGFloat((c >> 16) & 255) / 255, CGFloat((c >> 8) & 255) / 255, CGFloat(c & 255) / 255)
}

// Linear mix of two packed 0x00RRGGBB colors. t is 0...255 (the weight of b).
@inline(__always) func mix(_ a: UInt32, _ b: UInt32, _ t: UInt32) -> UInt32 {
    let s = 256 - t
    let r = (((a >> 16) & 255) * s + ((b >> 16) & 255) * t) >> 8
    let g = (((a >> 8) & 255) * s + ((b >> 8) & 255) * t) >> 8
    let bl = ((a & 255) * s + (b & 255) * t) >> 8
    return (r << 16) | (g << 8) | bl
}

// A tile lives in an IOSurface: BGRA, premultiplied, rows of 64 bytes. The window server reads the same memory,
// so there is one copy of the pixels. No CGImage is kept (a CGImage as layer contents costs a second copy).
// The drawing goes straight into the surface: there is no other pixel buffer.
func makeSurface(w: Int, h: Int) -> IOSurface? {
    let bytesPerRow = (w * 4 + 63) & ~63
    guard let s = IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4, .bytesPerRow: bytesPerRow,
                                         .pixelFormat: 0x42475241])  // 'BGRA'
    else { return nil }
    // The colors are sRGB, like the paper image. Without this tag the window server reads them in the display
    // color space, and on a wide-gamut screen the tiles would not match the paper layer.
    if let plist = sRGB.copyPropertyList() {
        IOSurfaceSetValue(s, "IOSurfaceColorSpace" as CFString, plist)
    }
    return s
}

// Draws tile k of the near or far layer. chunks are sorted by y, the order of upstream.
// The only buffers besides the surface are small: one row of the paper (2 KB) and three arrays of one tile width.
func rasterize(near: Bool, k: Int, chunks: [Chunk], geo: Geo) -> IOSurface? {
    let w = near ? geo.pxW : geo.fpxW
    let h = near ? geo.pxH : geo.fpxH
    let pn = near ? geo.pn : geo.pf
    guard let surface = makeSurface(w: w, h: h) else { return nil }
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    let base = surface.baseAddress
    let bytesPerRow = surface.bytesPerRow
    memset(base, 0, bytesPerRow * h)
    guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: sRGB, bitmapInfo: K.bitmapInfo)
    else { return nil }

    let x0 = Double(k) * K.tileW
    ctx.translateBy(x: 0, y: CGFloat(h))  // world y goes down, the first row is the top
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: CGFloat(pn), y: CGFloat(pn))
    ctx.setLineJoin(.miter)  // SVG defaults
    ctx.setMiterLimit(4)
    ctx.setLineCap(.butt)

    for c in chunks where c.maxX >= x0 && c.minX <= x0 + K.tileW {
        // the points are relative to the origin of the chunk: move by (origin - tile) in Double, draw in Float
        let lo = Float(x0 - c.ox), hi = Float(x0 + K.tileW - c.ox)
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(c.ox - x0), y: 0)
        c.pts.withUnsafeBufferPointer { pts in
            for p in c.polys where p.maxX + p.width >= lo && p.minX - p.width <= hi {
                let doFill = p.fill & 255 != 0
                let doStroke = p.stroke & 255 != 0 && p.width > 0
                if !doFill && !doStroke { continue }
                var i = Int(p.start)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: CGFloat(pts[i]), y: CGFloat(pts[i + 1])))
                for _ in 1..<Int(p.count) {
                    i += 2
                    ctx.addLine(to: CGPoint(x: CGFloat(pts[i]), y: CGFloat(pts[i + 1])))
                }
                if doFill {
                    let f = rgba(p.fill)
                    ctx.setFillColor(red: f.0, green: f.1, blue: f.2, alpha: f.3)
                }
                if doStroke {
                    let s = rgba(p.stroke)
                    ctx.setStrokeColor(red: s.0, green: s.1, blue: s.2, alpha: s.3)
                    ctx.setLineWidth(CGFloat(p.width))
                }
                let mode: CGPathDrawingMode = doFill ? (doStroke ? .fillStroke : .fill) : .stroke
                ctx.drawPath(using: mode)
            }
        }
        ctx.restoreGState()
    }

    let px = base.assumingMemoryBound(to: UInt32.self)
    let stride = bytesPerRow / 4
    if near {
        // pixel = paper * ink. Premultiplied, so the alpha stays. The paper is sampled with bilinear
        // interpolation, like the GPU does for the paper layer (texel centers at +0.5), so the paper inside
        // the mountains and outside of them match.
        var xa = [Int](repeating: 0, count: w), xb = [Int](repeating: 0, count: w)
        var xt = [UInt32](repeating: 0, count: w)
        for i in 0..<w {
            let fx = x0 + (Double(i) + 0.5) / pn - 0.5
            let ix = fx.rounded(.down)
            xt[i] = UInt32((fx - ix) * 256)
            xa[i] = Int(ix) & (K.paperW - 1)
            xb[i] = (Int(ix) + 1) & (K.paperW - 1)
        }
        var vrow = [UInt32](repeating: 0, count: K.paperW)  // the paper rows of this pixel row, mixed
        paper.texels.withUnsafeBufferPointer { tex in
            for j in 0..<h {
                let row = px + j * stride
                let fy = (Double(j) + 0.5) / pn - 0.5
                let iy = fy.rounded(.down)
                let ty = UInt32((fy - iy) * 256)
                let y0 = min(max(Int(iy), 0), K.paperH - 1) * K.paperW
                let y1 = min(max(Int(iy) + 1, 0), K.paperH - 1) * K.paperW
                for x in 0..<K.paperW { vrow[x] = mix(tex[y0 + x], tex[y1 + x], ty) }
                for i in 0..<w {
                    let v = row[i]
                    let a = v >> 24
                    if a == 0 { continue }
                    let t = mix(vrow[xa[i]], vrow[xb[i]], xt[i])
                    let r = ((v >> 16) & 255) * (t >> 16) / 255
                    let g = ((v >> 8) & 255) * ((t >> 8) & 255) / 255
                    let bl = (v & 255) * (t & 255) / 255
                    row[i] = (a << 24) | (r << 16) | (g << 8) | bl
                }
            }
        }
    } else {
        // gray ink -> black with alpha (a - gray). Exact for opaque gray shapes that overlap. In place.
        for j in 0..<h {
            let row = px + j * stride
            for i in 0..<w {
                let v = row[i]
                let a = v >> 24
                if a == 0 { continue }
                let g = (v >> 16) & 255
                row[i] = (a > g ? a - g : 0) << 24
            }
        }
    }
    return surface
}
