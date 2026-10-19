import AppKit
import IOSurface
import ImageIO
import QuartzCore

// Test and debug support: the command line flags, composed frames, stats lines, BLANK/missing, the sweep.

// Test options: --window [--windows N]  --seconds N  --debug DIR  --sweep
// The store build (-D STORE) has none of them: Opt is constant and the debug code is not compiled.
#if STORE
enum Opt {
    static let window = false
    static let seconds: Double? = nil
    static let debug: String? = nil
    static let sweep = false
    static let still: String? = nil
}
#else
enum Opt {
    static func value(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static let window = CommandLine.arguments.contains("--window")
    static let windows = max(1, Int(Opt.value("--windows") ?? "") ?? 1)  // test windows, each one is a world
    static let seconds: Double? = Opt.value("--seconds").flatMap { Double($0) }
    static let debug: String? = Opt.value("--debug")
    static let sweep = CommandLine.arguments.contains("--sweep") && Opt.window  // test: change speed and density every 5 s
    static let still: String? = Opt.value("--still")  // no window: one 3840x2160 JPEG (the bundled background)
}

// --sweep: the values that are applied every 5 s, in turn.
enum Sweep {
    static let speeds = [60.0, 2, 45, 15, 60]
    static let densities = [2.0, 0.2, 1.5, 1, 2]
}

// The timing counters of one world (World.stats). The engine only calls addGen and addRaster.
struct Stats {
    var genSum = 0.0, genCount = 0, rasterSum = 0.0, rasterMax = 0.0, rasterCount = 0

    mutating func addGen(_ dt: Double) {
        genSum += dt
        genCount += 1
    }

    mutating func addRaster(_ dt: Double) {
        rasterSum += dt
        rasterMax = max(rasterMax, dt)
        rasterCount += 1
    }

    // Averages in ms. The counters start again.
    mutating func take() -> (gen: Int, raster: Int, rasterMax: Int) {
        let r = (gen: genCount > 0 ? Int(genSum / Double(genCount) * 1000) : 0,
                 raster: rasterCount > 0 ? Int(rasterSum / Double(rasterCount) * 1000) : 0,
                 rasterMax: Int(rasterMax * 1000))
        self = Stats()
        return r
    }
}

extension Engine {
    // One line for a screen. Counters start again after each call.
    func stats(_ id: Int, _ done: @escaping @MainActor (String) -> Void) {
        q.async {
            var line = ""
            if let w = self.worlds[id] {
                let s = w.stats.take()
                line = "gen \(s.gen) ms/slice, raster \(s.raster) ms/tile (max \(s.rasterMax)), "
                    + "chunks near \(w.near.chunks.count) far \(w.far.chunks.count)"
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(line) } }
        }
    }

    // One line for the engine.
    func engineLine(_ done: @escaping @MainActor (String) -> Void) {
        q.async {
            let now = CACurrentMediaTime()
            let waiting = self.worlds.values.filter { self.action($0, now) != nil }.count
            let line = "engine: worlds \(self.worlds.count), waiting for work \(waiting), last served world \(self.lastServed) "
                + "(\(self.lastGenMs) ms)"
            DispatchQueue.main.async { MainActor.assumeIsolated { done(line) } }
        }
    }
}

extension Landscape {
    // How many tiles that overlap the screen are not drawn now.
    func missingCount() -> Int {
        let now = currentU()
        var n = 0
        let lastN = Int(((now + geo.wUnits) / K.tileW).rounded(.up)) - 1
        for k in Int((now / K.tileW).rounded(.down))...max(lastN, 0) where nearTiles[k] == nil { n += 1 }
        let fu = now * K.parallax
        let lastF = Int(((fu + geo.wUnits) / K.tileW).rounded(.up)) - 1
        for k in Int((fu / K.tileW).rounded(.down))...max(lastF, 0) where farTiles[k] == nil { n += 1 }
        return n
    }

    func checkBlank(_ tag: String) {
        guard started && running else { return }
        let m = missingCount()
        if m > 0 {
            print("BLANK [\(tag)] world=\(id) missing=\(m) u=\(Int(currentU())) speed=\(Int(speed))")
            fflush(stdout)
        }
    }

    // Draws paper, far and near at the current offset with CoreGraphics, writes a PNG, prints one line.
    func debug(dir: String, tag: String) {
        if let img = composeFrame(captureFrame()), let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/frame-\(tag).png"))
        }
        engine.stats(id) { [weak self] line in
            guard let self = self else { return }
            print("[\(tag)] world=\(self.id) run=\(self.running) speed=\(Int(self.speed)) missing=\(self.missingCount()) u=\(Int(self.currentU())) tiles near \(self.nearTiles.count) far \(self.farTiles.count) | \(line)")
            fflush(stdout)
        }
    }
}

// --still FILE.jpg: the paper layer only (same texture and composeFrame as the app, no landscape), 1920x1080 points x2.
// No window, no engine, no status item, no wallpaper code. Exits when the file is written.
@MainActor func renderStill(_ path: String) -> Never {
    let geo = Geo(wPts: 1920, hPts: 1080, scale: 2, pixelScale: 2)
    guard let img = composeFrame(FrameCapture(geo: geo, u: 0, near: [], far: [])),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)
    else { print("still: compose failed"); exit(1) }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { print("still: write failed"); exit(1) }
    print("still: \(img.width)x\(img.height) written")
    exit(0)
}

extension Wallpaper {
    // --window [--windows N]: floating test windows, bottom right, stacked up. Each one is a world of the one engine.
    func makeTestWindows() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let size = Opt.windows == 1 ? CGSize(width: 800, height: 450) : CGSize(width: 640, height: 360)
        for i in 0..<Opt.windows {
            let rect = NSRect(x: vis.maxX - size.width - 20, y: vis.minY + 20 + CGFloat(i) * (size.height + 30),
                              width: size.width, height: size.height)
            let win = Landscape.makeWindow(frame: rect, level: .floating, wallpaper: false)
            nextWorld += 1
            // the landscape shows the window when it is ready
            landscapes[UInt32(i)] = Landscape(engine: engine, id: nextWorld, window: win, scale: screen.backingScaleFactor,
                                              frame: rect, speed: Settings.speed, density: Settings.density)
        }
    }

    // --debug DIR: a frame and a stats line for every window every 10 s, BLANK lines every 0.25 s.
    func startDebug(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = commonTimer(10) { [weak self] _ in
            MainActor.assumeIsolated { self?.debugTick(dir) }
        }
        // a tile that is missing for a short time is easy to miss
        _ = commonTimer(0.25) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let t = String(format: "%.2f", Date().timeIntervalSince(self.launched))
                for l in self.landscapes.values { l.checkBlank(t) }
            }
        }
    }

    func debugTick(_ dir: String) {
        let t = Int(Date().timeIntervalSince(launched).rounded())
        for (i, key) in landscapes.keys.sorted().enumerated() { landscapes[key]?.debug(dir: dir, tag: "\(t)s-\(i)") }
        engine.engineLine { line in
            print(line)
            fflush(stdout)
        }
    }

    // --sweep: every 5 s the next speed and density, through the same code as the sliders.
    func startSweep() {
        _ = commonTimer(5) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    func sweep() {
        let speed = Sweep.speeds[sweepStep % Sweep.speeds.count]
        let density = Sweep.densities[sweepStep % Sweep.densities.count]
        applySpeed(speed)
        applyDensity(density)
        print("SWEEP speed \(speed) density \(density)")
        fflush(stdout)
        sweepStep += 1
    }
}
#endif
