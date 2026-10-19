import AppKit

// A timer that also runs while a menu is open (the "common" run loop modes).
func commonTimer(_ interval: TimeInterval, repeats: Bool = true, _ block: @escaping @Sendable (Timer) -> Void) -> Timer {
    let t = Timer(timeInterval: interval, repeats: repeats, block: block)
    RunLoop.main.add(t, forMode: .common)
    return t
}

// Removes the tiles for which drop(k) is true. The surface is freed when the window server lets go of it.
func prune(_ tiles: inout [Int: CALayer], _ drop: (Int) -> Bool) {
    for (k, l) in tiles where drop(k) {
        l.contents = nil
        l.removeFromSuperlayer()
        tiles[k] = nil
    }
}

// The tiles that a view covers: from a scroll position (world units) to `width` units further.
func visibleTiles(from: Double, width: Double) -> ClosedRange<Int> {
    Int((from / K.tileW).rounded(.down))...Int(((from + width) / K.tileW).rounded(.down))
}
