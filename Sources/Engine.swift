import AppKit
import IOSurface
import JavaScriptCore
import QuartzCore

// One engine for all screens: one JavaScriptCore context (generator.js + the scripts of upstream), one queue.
// Each screen is a World in it.

extension Notification.Name {
    static let generatorFailed = Notification.Name("shanshui.generatorFailed")  // userInfo["reason"]
}

// The chunks and the tiles of one layer (near or far) of one world.
final class Lane {
    let near: Bool
    var chunks: [Chunk] = []
    var done = Set<Int>()                // tiles that are drawn
    var want: ClosedRange<Int> = 0...0   // tiles that the view needs, with the lead
    var edge = -Double.infinity          // where generation has come to (local units). Reported by JavaScript.
    init(near: Bool) { self.near = near }

    // An item can reach `reach` units from the slice that planned it. A far hill starts at its x and runs to the right.
    var reach: Double { near ? K.reach : 0 }

    // The first tile, counted from the view, that is not drawn.
    var frontier: Int {
        var k = want.lowerBound
        while done.contains(k) { k += 1 }
        return k
    }

    // That tile, if all chunks that can reach it exist.
    func nextTile() -> Int? {
        let k = frontier
        return k <= want.upperBound && (Double(k) + 1) * K.tileW + reach <= edge ? k : nil
    }

    var wantsMore: Bool { edge < (Double(want.upperBound) + 1) * K.tileW + reach }
}

// The state of one screen in the engine.
final class World {
    let id: Int
    let geo: Geo
    let deliver: @MainActor (Bool, Int, IOSurface) -> Void  // called on the main thread with a finished tile
    let near = Lane(near: true), far = Lane(near: false)
    var density: Double
    var active = true     // false while the screen is paused
    var broken = false    // JavaScript gave no answer: no more work
    var u = 0.0           // where the view is (near units), for the lead
    var failures = 0, blockedUntil = 0.0  // a tile that fails is tried again later
    #if !STORE
    var stats = Stats()  // --debug (Debug.swift)
    #endif

    init(id: Int, geo: Geo, density: Double, deliver: @escaping @MainActor (Bool, Int, IOSurface) -> Void) {
        self.id = id
        self.geo = geo
        self.density = density
        self.deliver = deliver
    }

    // World units that are drawn ahead of the view (near, and far counted in near units).
    // The same speed in points for all screens, so lead * sPts orders the screens by seconds of pan.
    var lead: Double {
        let n = Double(near.frontier) * K.tileW - (u + geo.wUnits)
        let f = (Double(far.frontier) * K.tileW - (u * K.parallax + geo.wUnits)) / K.parallax
        return min(n, f) * geo.sPts
    }
}

enum Action {
    case render(Lane, Int)
    case generate(Lane)
}

// All of this runs on the queue q: JavaScriptCore, parsing, rasterizing. The main thread only gets finished tiles.
// One step at a time, always for the screen that has the least drawn ahead of its view: no screen starves another.
final class Engine: @unchecked Sendable {
    let q = DispatchQueue(label: "shanshui.engine", qos: .utility)
    let seed = String(Int.random(in: 1...999_999_999_999))
    var ss: JSValue?  // ss.context is the JSContext
    var worlds: [Int: World] = [:]
    var busy = false
    var dirty = false  // work was done since the allocator was asked to give memory back
    let parser = Parser()
    // The text of a slice is copied from JavaScript into this buffer as UTF-8 and parsed from there. No String and no
    // Array copies of megabytes. It grows when a slice needs more (it never shrinks).
    var scratch = UnsafeMutablePointer<CChar>.allocate(capacity: K.scratchSize)
    var scratchSize = K.scratchSize
    #if !STORE
    var lastServed = -1, lastGenMs = 0  // --debug
    #endif

    // The generator did not start: log it and show it in the menu (Wallpaper listens).
    func fail(_ reason: String) {
        NSLog("ShanShui generator: %@", reason)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .generatorFailed, object: nil, userInfo: ["reason": reason])
        }
    }

    // Call once, before the first register.
    func start() {
        q.async {
            guard let res = Bundle.main.resourceURL,
                  let html = try? String(contentsOf: res.appendingPathComponent("index.html"), encoding: .utf8),
                  let gen = try? String(contentsOf: res.appendingPathComponent("generator.js"), encoding: .utf8),
                  let ctx = JSContext()
            else { return self.fail("cannot read index.html or generator.js") }
            var jsError = ""
            ctx.exceptionHandler = { _, e in jsError = e?.toString() ?? "unknown JS error"; NSLog("ShanShui JS: %@", jsError) }
            ctx.evaluateScript(gen)
            let ss = ctx.objectForKeyedSubscript("SS")
            // load() returns "ok", or the message of the error that it caught
            let result = ss?.invokeMethod("load", withArguments: [html, self.seed])?.toString()
            if result != "ok" { return self.fail(jsError.isEmpty ? (result ?? "no result") : jsError) }
            self.ss = ss
            self.kick()
        }
    }

    // A screen joins. It gets its own part of the landscape (JavaScript chooses it).
    func register(id: Int, geo: Geo, density: Double, deliver: @escaping @MainActor (Bool, Int, IOSurface) -> Void) {
        q.async {
            self.worlds[id] = World(id: id, geo: geo, density: density, deliver: deliver)
            _ = self.ss?.invokeMethod("addWorld", withArguments: [id, density])
            self.kick()
        }
    }

    func unregister(id: Int) {
        q.async {
            self.worlds[id] = nil
            _ = self.ss?.invokeMethod("removeWorld", withArguments: [id])
        }
    }

    // The main thread says which tiles a screen wants and where its view is. Tiles behind the view are forgotten.
    // A tile ahead stays drawn when the lead gets shorter: the chunks of such a tile may be freed already,
    // so it could not be drawn again.
    func request(id: Int, near: ClosedRange<Int>, far: ClosedRange<Int>, u: Double) {
        q.async {
            guard let w = self.worlds[id] else { return }
            w.near.want = near
            w.far.want = far
            w.u = u
            w.near.done = w.near.done.filter { $0 >= near.lowerBound }
            w.far.done = w.far.done.filter { $0 >= far.lowerBound }
            self.kick()
        }
    }

    func setActive(id: Int, _ a: Bool) { q.async { self.worlds[id]?.active = a; self.kick() } }

    func setDensity(id: Int, _ d: Double) {
        q.async {
            self.worlds[id]?.density = d
            _ = self.ss?.invokeMethod("setDensity", withArguments: [id, d])
        }
    }

    func kick() {
        if busy { return }
        busy = true
        q.async { self.pump() }
    }

    // One unit of work, then the queue is free again for other requests.
    // When there is nothing to do any more, the allocator gets the memory back (once, not at every idle check).
    func pump() {
        guard let next = pick() else {
            busy = false
            if dirty {
                dirty = false
                _ = malloc_zone_pressure_relief(nil, 0)
            }
            return
        }
        dirty = true
        switch next.action {
        case .render(let lane, let k): render(next.world, lane, k)
        case .generate(let lane): generate(next.world, lane)
        }
        q.async { self.pump() }
    }

    // What is the next step of this screen? Tiles first, then more chunks (far hills are cheap, so they come first).
    func action(_ w: World, _ now: Double) -> Action? {
        guard w.active, !w.broken else { return nil }
        if now >= w.blockedUntil {
            for lane in [w.near, w.far] {
                if let k = lane.nextTile() { return .render(lane, k) }
            }
        }
        for lane in [w.far, w.near] where lane.wantsMore { return .generate(lane) }
        return nil
    }

    // The screen with the least drawn ahead of its view gets the step.
    func pick() -> (world: World, action: Action)? {
        guard ss != nil else { return nil }
        let now = CACurrentMediaTime()
        var best: (world: World, action: Action)? = nil
        var bestLead = Double.infinity
        for w in worlds.values {
            guard let a = action(w, now) else { continue }
            let l = w.lead
            if best == nil || l < bestLead {
                best = (w, a)
                bestLead = l
            }
        }
        return best
    }

    // Copies a JavaScript string into `scratch` as UTF-8. Returns the number of bytes.
    func readText(_ v: JSValue?) -> Int {
        guard let v = v, let ctx = v.context,
              let s = JSValueToStringCopy(ctx.jsGlobalContextRef, v.jsValueRef, nil) else { return 0 }
        defer { JSStringRelease(s) }
        let need = JSStringGetMaximumUTF8CStringSize(s)  // 3 bytes per UTF-16 unit: only the used part of it is touched
        if need > scratchSize {
            scratch.deallocate()
            scratchSize = need
            scratch = UnsafeMutablePointer<CChar>.allocate(capacity: need)
        }
        return max(0, JSStringGetUTF8CString(s, scratch, scratchSize) - 1)  // minus the end mark
    }

    func generate(_ w: World, _ lane: Lane) {
        #if !STORE
        let t = CACurrentMediaTime()
        #endif
        let n = readText(ss?.invokeMethod(lane.near ? "nearSlice" : "farNext", withArguments: [w.id]))
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(scratch).assumingMemoryBound(to: UInt8.self), count: n)
        let parsed = parser.parse(bytes)
        guard let edge = parsed.edge else {
            w.broken = true
            NSLog("ShanShui: the generator gave no answer for world %ld", w.id)
            return
        }
        lane.edge = edge
        for c in parsed.chunks {
            let l = c.near ? w.near : w.far
            l.chunks.insert(c, at: l.chunks.firstIndex { $0.y > c.y } ?? l.chunks.count)
        }
        #if !STORE
        let dt = CACurrentMediaTime() - t
        lastServed = w.id
        lastGenMs = Int(dt * 1000)
        if lane.near { w.stats.addGen(dt) }
        #endif
        if lane.near { collect() }
    }

    // Upstream builders make a lot of garbage. Free pages from the last round go back to the system first
    // (the collection runs some time after the request), then JavaScriptCore is asked to collect.
    func collect() {
        _ = malloc_zone_pressure_relief(nil, 0)
        if let c = ss?.context { JSGarbageCollect(c.jsGlobalContextRef) }
    }

    // The visible tiles of a world drawn again with `geo` (the export), at the view position u. The caller frees them.
    func exportTiles(id: Int, u: Double, geo: Geo) -> FrameCapture {
        func tiles(_ lane: Lane, from: Double) -> TileList {
            var r: TileList = []
            for k in visibleTiles(from: from, width: geo.wUnits) where lane.done.contains(k) {
                if let s = rasterize(near: lane.near, k: k, chunks: lane.chunks, geo: geo) { r.append((k, s)) }
            }
            return r
        }
        guard let w = worlds[id] else { return FrameCapture(geo: geo, u: u, near: [], far: []) }
        return FrameCapture(geo: geo, u: u, near: tiles(w.near, from: u), far: tiles(w.far, from: u * K.parallax))
    }

    func render(_ w: World, _ lane: Lane, _ k: Int) {
        #if !STORE
        let t = CACurrentMediaTime()
        #endif
        let surface = rasterize(near: lane.near, k: k, chunks: lane.chunks, geo: w.geo)
        #if !STORE
        w.stats.addRaster(CACurrentMediaTime() - t)
        #endif
        if let s = surface {
            lane.done.insert(k)
            w.failures = 0
            let isNear = lane.near
            DispatchQueue.main.async { MainActor.assumeIsolated { w.deliver(isNear, k, s) } }
        } else {
            // A tile that failed is tried again later: after 1 s, then 2 s, 4 s ... at most 30 s.
            w.failures += 1
            let delay = min(30.0, pow(2.0, Double(w.failures - 1)))
            w.blockedUntil = CACurrentMediaTime() + delay
            if w.failures == 5 { NSLog("ShanShui: tile %ld of world %ld failed 5 times", k, w.id) }
            q.asyncAfter(deadline: .now() + delay) { self.kick() }
        }
        // A chunk is not needed any more when it is behind the view. (The chunks of the visible tiles stay: the
        // PNG export draws them again at the backing scale.)
        let edge = Double(lane.want.lowerBound) * K.tileW
        lane.chunks.removeAll { $0.maxX < edge }
    }
}
