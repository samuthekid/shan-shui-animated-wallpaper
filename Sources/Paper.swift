import AppKit

// One texture for all screens. Upstream draws it with a canvas: 245 + low-frequency noise - random grain,
// tinted (1, 0.95, 0.85). Here it is built in Swift. It repeats every paperW world units without a seam.
// Uses sRGB from Render.swift. Globals in non-main files are lazy, so the order does not matter.
final class Paper {
    let texels: [UInt32]  // 0x00RRGGBB
    let image: CGImage

    init() {
        let gx = 51, rows = 73  // one noise cell is about 10 texels
        let grid = (0..<gx * rows).map { _ in Double.random(in: 0..<1) }
        func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        var t = [UInt32](repeating: 0, count: K.paperW * K.paperH)
        for y in 0..<K.paperH {
            let fy = Double(y) / 10
            let y0 = Int(fy)
            let ty = smooth(fy - Double(y0))
            for x in 0..<K.paperW {
                let fx = Double(x) * Double(gx) / Double(K.paperW)
                let x0 = Int(fx)
                let x1 = (x0 + 1) % gx
                let tx = smooth(fx - Double(x0))
                let top = grid[y0 * gx + x0] * (1 - tx) + grid[y0 * gx + x1] * tx
                let bottom = grid[(y0 + 1) * gx + x0] * (1 - tx) + grid[(y0 + 1) * gx + x1] * tx
                let n = top * (1 - ty) + bottom * ty
                let v = min(255.0, max(0.0, 245 + n * 10 - Double.random(in: 0..<20)))
                t[y * K.paperW + x] = UInt32(v) << 16 | UInt32(v * 0.95) << 8 | UInt32(v * 0.85)
            }
        }
        // The image has one extra column on each side (the last texel left, the first texel right). The layers show
        // only the middle part (contentsRect). So linear filtering at the edge of a layer reads the real neighbor
        // texel, and two paper layers side by side have no seam.
        let w = K.paperW + 2
        var padded = [UInt32](repeating: 0, count: w * K.paperH)
        for y in 0..<K.paperH {
            let row = y * K.paperW
            padded[y * w] = t[row + K.paperW - 1]
            for x in 0..<K.paperW { padded[y * w + 1 + x] = t[row + x] }
            padded[y * w + w - 1] = t[row]
        }
        let data = padded.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        texels = t
        image = CGImage(width: w, height: K.paperH, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: w * 4, space: sRGB, bitmapInfo: info,
                        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: true,
                        intent: .defaultIntent)!
    }

    // The part of the image that a layer shows.
    static let contentsRect = CGRect(x: 1.0 / Double(K.paperW + 2), y: 0, width: Double(K.paperW) / Double(K.paperW + 2), height: 1)
}

let paper = Paper()
