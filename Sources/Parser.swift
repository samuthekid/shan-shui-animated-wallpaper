import Foundation

// Reads the text of Sources/generator.js (UTF-8, see the format at the top of that file). edge is the "=n" line.
// The scratch arrays are reused for every chunk, so there is no growing array per chunk. A chunk gets
// copies of exactly the needed size.
final class Parser {
    var pts: [Float] = []
    var polys: [Poly] = []

    func parse(_ b: UnsafeBufferPointer<UInt8>) -> (chunks: [Chunk], edge: Double?) {
        var i = 0
        var chunks: [Chunk] = []
        var edge: Double? = nil
        var header: (near: Bool, ox: Double, y: Double)? = nil
        pts.removeAll(keepingCapacity: true)
        polys.removeAll(keepingCapacity: true)

        func skipSpaces() { while i < b.count && b[i] == 32 { i += 1 } }
        func number() -> Double {
            skipSpaces()
            var neg = false
            if i < b.count && b[i] == 45 { neg = true; i += 1 }
            var v = 0.0
            while i < b.count && b[i] >= 48 && b[i] <= 57 { v = v * 10 + Double(b[i] - 48); i += 1 }
            if i < b.count && b[i] == 46 {
                i += 1
                var f = 0.1
                while i < b.count && b[i] >= 48 && b[i] <= 57 { v += Double(b[i] - 48) * f; f *= 0.1; i += 1 }
            }
            return neg ? -v : v
        }
        func atEnd() -> Bool { skipSpaces(); return i >= b.count || b[i] == 10 }
        func finish() {
            if let h = header, !polys.isEmpty {
                let exactPolys = polys.withUnsafeBufferPointer { Array($0) }
                let exactPts = pts.withUnsafeBufferPointer { Array($0) }
                chunks.append(Chunk(near: h.near, ox: h.ox, y: h.y, polys: exactPolys, pts: exactPts))
            }
            pts.removeAll(keepingCapacity: true)
            polys.removeAll(keepingCapacity: true)
        }

        while i < b.count {
            if b[i] == 10 { i += 1; continue }
            if b[i] == 61 {  // "=n"
                i += 1
                edge = number()
                continue
            }
            if b[i] == 35 && i + 1 < b.count {  // "#N x y"
                finish()
                let isNear = b[i + 1] == 78
                i += 2
                let ox = number()
                let y = number()
                header = (isNear, ox, y)
                continue
            }
            if header == nil { i += 1; continue }
            let fill = UInt32(truncatingIfNeeded: Int64(number()))
            let stroke = UInt32(truncatingIfNeeded: Int64(number()))
            let width = Float(number())
            var p = Poly(fill: fill, stroke: stroke, width: width, start: Int32(pts.count), count: 0,
                         minX: Float.infinity, maxX: -Float.infinity)
            while !atEnd() {
                let before = i
                let x = Float(number()), y = Float(number())
                if i == before { i += 1; continue }  // not a number: skip the byte, never loop forever
                pts.append(x)
                pts.append(y)
                p.count += 1
                if x < p.minX { p.minX = x }
                if x > p.maxX { p.maxX = x }
            }
            if p.count >= 2 { polys.append(p) } else { pts.removeLast(Int(p.count) * 2) }
        }
        finish()
        return (chunks, edge)
    }
}
