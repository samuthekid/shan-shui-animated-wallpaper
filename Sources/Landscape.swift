import AppKit
import IOSurface
import QuartzCore

// One screen: its window, its layers (paper, far, near), the pan, the tiles that the engine delivers.

// Main thread only. Time model: near scroll position u (world units) at time t0, moving with `speed`.
@MainActor
final class Landscape {
    let window: NSWindow
    let engine: Engine
    let id: Int              // the world of this screen in the engine
    let screenFrame: CGRect  // to see if the screen changed
    let backing: CGFloat
    let geo: Geo
    let paperBox = CALayer(), farBox = CALayer(), nearBox = CALayer()
    var nearTiles: [Int: CALayer] = [:]  // the pixels are only in layer.contents (an IOSurface)
    var farTiles: [Int: CALayer] = [:]
    var paperTiles: [Int: CALayer] = [:]  // paperW wide, in the paper box. The paper box moves exactly like the near box.
    var u = 0.0
    var t0 = CACurrentMediaTime()  // the time of u. Set by repan() only.
    var started = false  // the window is hidden until the first screen and the lead are ready, see checkReady()
    var running = false  // pan and generation are on. Starts with the window.
    var stopped = false
    var paused = false  // the menu item Pause. Same effect as a covered window (setRunning), only the reason differs.
    var replaced: Landscape?  // the landscape of the same screen before a change: it stays until this one is shown
    var speed: Double  // the pan speed (slider), points per second. Constant: nothing slows the pan.
    var baseN = 0.0, baseF = 0.0  // world x at x = 0 of the near and far box. Moves forward from time to time: small floats.
    var rangeN: ClosedRange<Int> = 0...0
    var rangeF: ClosedRange<Int> = 0...0
    var timer: Timer?
    var observer: NSObjectProtocol?

    // The window of a landscape. The wallpaper window is borderless, click-through, on all spaces, at the desktop
    // level (desktop icons stay above it). The test window is a normal titled window at the given level.
    // Either way, it is shown later by the landscape, when the first screen is ready.
    static func makeWindow(frame: NSRect, level: NSWindow.Level, wallpaper: Bool) -> NSWindow {
        let win = NSWindow(contentRect: frame, styleMask: wallpaper ? .borderless : [.titled], backing: .buffered, defer: false)
        win.level = level
        if wallpaper {
            // Not .stationary: the window then slides with each Space page, so Mission Control and Space swipes keep the
            // native black gap (a stationary window covered it and left a visible seam).
            win.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
            win.ignoresMouseEvents = true
        }
        win.isReleasedWhenClosed = false  // the landscape owns it
        return win
    }

    init(engine: Engine, id: Int, window: NSWindow, scale: CGFloat, frame: CGRect, speed: Double, density: Double) {
        self.engine = engine
        self.id = id
        self.window = window
        self.screenFrame = frame
        self.backing = scale
        self.speed = speed
        let size = frame.size
        let g = Geo(wPts: Double(size.width), hPts: Double(size.height), scale: Double(scale))
        geo = g

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        window.contentView = view
        let root = view.layer!
        root.backgroundColor = K.paperColor
        for box in [paperBox, farBox, nearBox] {
            box.anchorPoint = .zero
            box.position = .zero
            box.bounds = CGRect(origin: .zero, size: size)
            root.addSublayer(box)
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
        engine.register(id: id, geo: g, density: density) { [weak self] isNear, k, surface in
            self?.place(near: isNear, k: k, surface: surface)
        }
        repan()
        tick()
        scheduleTimer()
    }

    func scheduleTimer() {
        timer = commonTimer(1) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.5
    }

    func currentU(_ now: Double = CACurrentMediaTime()) -> Double { running ? u + speed / geo.sPts * (now - t0) : u }

    // The only place that starts the pans. u is moved to this moment under the old speed, then the speed or the
    // running state changes, then the animations start with beginTime = this same moment. So the model (u, t0) and
    // the animation agree, and a restart does not jump.
    func repan(speed newSpeed: Double? = nil, running newRunning: Bool? = nil) {
        let now = CACurrentMediaTime()
        u = currentU(now)
        t0 = now
        if let s = newSpeed { speed = s }
        if let r = newRunning { running = r }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sp = geo.sPts
        // paper and near: the same numbers, so the paper grain does not move against the paper baked into the tiles
        pan(paperBox, from: (u - baseN) * sp, rate: speed, at: now)
        pan(nearBox, from: (u - baseN) * sp, rate: speed, at: now)
        pan(farBox, from: (u * K.parallax - baseF) * sp, rate: speed * K.parallax, at: now)
        CATransaction.commit()
    }

    // One linear animation of bounds.origin.x. rate is in points per second.
    func pan(_ box: CALayer, from: Double, rate: Double, at now: Double) {
        box.removeAnimation(forKey: "pan")
        var b = box.bounds
        b.origin.x = CGFloat(from)
        box.bounds = b
        guard running && rate > 0 else { return }
        // The animation is K.panLength long. tick() restarts it (rebase) when the box has moved K.rebaseDistance from the
        // base, so at least 10000 points (166 s at the top speed) are left. A pause removes it.
        let length = K.panLength
        let a = CABasicAnimation(keyPath: "bounds.origin.x")
        a.fromValue = from
        a.toValue = from + length
        a.duration = length / rate
        a.beginTime = box.convertTime(now, from: nil)
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.preferredFrameRateRange = K.fps60
        box.add(a, forKey: "pan")
    }

    func visibilityChanged() {
        if started { setRunning(!paused && window.occlusionState.contains(.visible)) }
    }

    // Every wanted tile is there (first screen plus lead): show the window with a fade. Until then the normal
    // desktop wallpaper (or the old landscape of this screen) stays visible. The pan starts now.
    func checkReady() {
        for k in rangeN where nearTiles[k] == nil { return }
        for k in rangeF where farTiles[k] == nil { return }
        started = true
        repan(running: true)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 1
        window.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
        visibilityChanged()  // a wallpaper that starts covered must pause
        if let old = replaced {
            // this landscape fades in above the old one of the same screen. When it is solid, the old one goes.
            replaced = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { old.stop() } }
        }
    }

    // Not visible (covered, display asleep, screen locked): no animation, no generation, no timer.
    func setRunning(_ r: Bool) {
        if r == running { return }
        repan(running: r)
        engine.setActive(id: id, r)
        timer?.invalidate()
        timer = nil
        if r {
            tick()
            scheduleTimer()
        }
    }

    func tileX(_ isNear: Bool, _ k: Int) -> Double {
        (Double(k) * K.tileW - (isNear ? baseN : baseF)) * geo.sPts
    }

    // Once per second: which tiles are wanted, drop old tiles, move the origin forward when it is far from zero.
    func tick() {
        guard running || !started else { return }  // before the window is shown, tiles are wanted too
        if (currentU() - baseN) * geo.sPts > K.rebaseDistance { rebase() }
        let now = currentU()
        let w = geo.wUnits
        // Lead: leadSeconds of travel at the MAXIMUM speed, at least K.ahead tiles. It does not depend on the
        // current speed, so a jump of the slider never outruns the tiles. The engine plans K.reach units further.
        let speedU = K.maxSpeed / geo.sPts  // world units per second
        let leadN = max(K.ahead, Int((speedU * K.leadSeconds / K.tileW).rounded(.up)))
        let leadF = max(K.ahead, Int((speedU * K.parallax * K.leadSeconds / K.tileW).rounded(.up)))
        let n = visibleTiles(from: now, width: w), f = visibleTiles(from: now * K.parallax, width: w)
        rangeN = n.lowerBound...(n.upperBound + leadN)
        rangeF = f.lowerBound...(f.upperBound + leadF)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Only tiles behind the view go. A tile ahead stays even if the lead gets shorter: it is drawn from chunks
        // that may be freed already, and the view will use it soon.
        let lowN = rangeN.lowerBound, lowF = rangeF.lowerBound
        prune(&nearTiles) { $0 < lowN }
        prune(&farTiles) { $0 < lowF }
        // paper layers: the same range as the near tiles, made here (they need no engine)
        let paperFrom = Int((Double(rangeN.lowerBound) * K.tileW / Double(K.paperW)).rounded(.down))
        let paperTo = Int(((Double(rangeN.upperBound) + 1) * K.tileW / Double(K.paperW)).rounded(.down))
        prune(&paperTiles) { $0 < paperFrom || $0 > paperTo }
        for j in paperFrom...paperTo where paperTiles[j] == nil {
            let l = makeTile(paperBox)
            l.bounds = CGRect(x: 0, y: 0, width: Double(K.paperW) * geo.sPts, height: Double(geo.pxH) / geo.px)
            l.position = CGPoint(x: paperX(j), y: 0)
            l.contents = paper.image  // one image for all of them
            l.contentsRect = Paper.contentsRect
            paperTiles[j] = l
        }
        CATransaction.commit()
        engine.request(id: id, near: rangeN, far: rangeF, u: now)
    }

    func paperX(_ j: Int) -> Double { (Double(j) * Double(K.paperW) - baseN) * geo.sPts }

    // Float precision of the layers: after K.rebaseDistance points of travel the tiles and the boxes start again near zero.
    // The picture does not change.
    func rebase() {
        let now = currentU()
        baseN = (now / K.tileW).rounded(.down) * K.tileW
        baseF = (now * K.parallax / K.tileW).rounded(.down) * K.tileW
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, l) in nearTiles { l.position = CGPoint(x: tileX(true, k), y: 0) }
        for (k, l) in farTiles { l.position = CGPoint(x: tileX(false, k), y: 0) }
        for (j, l) in paperTiles { l.position = CGPoint(x: paperX(j), y: 0) }
        repan()  // inside the same transaction: no frame shows tiles moved but the boxes not
        CATransaction.commit()
    }

    // All moving layers use linear filtering: at a fraction of a pixel nothing snaps and nothing steps.
    // A far tile has fewer pixels than a near tile, but the same bounds (in points): it is stretched to fit.
    func makeTile(_ box: CALayer) -> CALayer {
        let l = CALayer()
        l.anchorPoint = .zero
        l.bounds = CGRect(x: 0, y: 0, width: Double(geo.pxW) / geo.px, height: Double(geo.pxH) / geo.px)
        l.magnificationFilter = .linear
        l.minificationFilter = .linear
        box.addSublayer(l)
        return l
    }

    // A finished tile from the engine (main thread).
    func place(near isNear: Bool, k: Int, surface: IOSurface) {
        guard !stopped, k >= (isNear ? rangeN : rangeF).lowerBound else { return }  // behind the view: not needed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let old = isNear ? nearTiles[k] : farTiles[k]
        let layer = old ?? makeTile(isNear ? nearBox : farBox)
        layer.position = CGPoint(x: tileX(isNear, k), y: 0)
        layer.contents = surface
        if old == nil {
            // A new tile fades in. If it comes late and is already in view, there is no hard edge.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.8
            fade.preferredFrameRateRange = K.fps60
            layer.add(fade, forKey: "fade")
        }
        CATransaction.commit()
        if isNear { nearTiles[k] = layer } else { farTiles[k] = layer }
        if !started { checkReady() }
    }

    // Safe to call twice. Also stops the landscape that this one has replaced (if it is still there).
    func stop() {
        if stopped { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        engine.unregister(id: id)
        replaced?.stop()
        replaced = nil
        window.close()
    }
}
