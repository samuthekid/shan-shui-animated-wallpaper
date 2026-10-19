import AppKit
import ImageIO
import IOSurface
import QuartzCore
import UniformTypeIdentifiers

// Composing one full frame from the tiles (paper, far, near), and "Export Current Frame…" (a PNG through a save panel).
// The debug frames (Debug.swift) use the same composeFrame.

// Everything that composeFrame needs, taken on the main thread at one moment. The surfaces are shared memory:
// holding them copies nothing.
typealias TileList = [(k: Int, surface: IOSurface)]

struct FrameCapture {
    let geo: Geo
    let u: Double  // near scroll position (world units) at that moment. Far and paper follow from it.
    let near: TileList
    let far: TileList
}

extension Landscape {
    // The tiles that cover the visible range, and the pan offset, at one `now`. Main thread. The pan keeps running.
    func captureFrame() -> FrameCapture {
        let u = currentU(CACurrentMediaTime())
        func visible(_ tiles: [Int: CALayer], from: Double) -> TileList {
            var r: TileList = []
            for k in visibleTiles(from: from, width: geo.wUnits) {
                if let s = tiles[k]?.contents as? IOSurface { r.append((k, s)) }
            }
            return r
        }
        return FrameCapture(geo: geo, u: u, near: visible(nearTiles, from: u), far: visible(farTiles, from: u * K.parallax))
    }

    // The geometry of the PNG export: the tiles are drawn again at the backing scale.
    var exportGeo: Geo { Geo(wPts: geo.wPts, hPts: geo.hPts, scale: geo.scale, pixelScale: geo.scale) }
}

// Draws one tile surface into c. The pixels are read while the surface is locked.
func drawSurface(_ s: IOSurface, in c: CGContext, rect: CGRect) {
    s.lock(options: .readOnly, seed: nil)
    defer { s.unlock(options: .readOnly, seed: nil) }
    guard let src = CGContext(data: s.baseAddress, width: s.width, height: s.height, bitsPerComponent: 8,
                              bytesPerRow: s.bytesPerRow, space: sRGB, bitmapInfo: K.bitmapInfo),
          let img = src.makeImage()
    else { return }
    c.draw(img, in: rect)
}

// The picture of the screen: paper, far, near, in the full pixel size of the screen. Far tiles have fewer pixels
// (see Geo): they are scaled up with high quality. One bitmap of the screen size; the image is made from it
// without a copy.
func composeFrame(_ f: FrameCapture) -> CGImage? {
    let geo = f.geo
    let pw = Int((geo.wPts * geo.px).rounded()), ph = geo.pxH
    guard let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: K.bitmapInfo),
          let paperImage = paper.image.cropping(to: CGRect(x: 1, y: 0, width: K.paperW, height: K.paperH))  // without the border columns
    else { return nil }
    let paperPx = Double(K.paperW) * geo.pn
    var x = -f.u.truncatingRemainder(dividingBy: Double(K.paperW)) * geo.pn
    c.interpolationQuality = .none
    while x < Double(pw) {
        c.draw(paperImage, in: CGRect(x: x, y: 0, width: paperPx, height: Double(ph)))
        x += paperPx
    }
    c.interpolationQuality = .high
    for t in f.far {
        drawSurface(t.surface, in: c, rect: CGRect(x: (Double(t.k) * K.tileW - f.u * K.parallax) * geo.pn, y: 0, width: Double(geo.pxW), height: Double(ph)))
    }
    for t in f.near {
        drawSurface(t.surface, in: c, rect: CGRect(x: (Double(t.k) * K.tileW - f.u) * geo.pn, y: 0, width: Double(geo.pxW), height: Double(ph)))
    }
    return c.makeImage()
}

// Writes the frame as a PNG (sRGB, DPI = 72 x backing scale, so that macOS shows the size in points).
// Returns nil, or the message of the error.
func writePNG(_ f: FrameCapture, to url: URL) -> String? {
    guard let img = composeFrame(f) else { return "The frame could not be composed." }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return "The file could not be created." }
    let dpi = 72 * f.geo.px
    let props = [kCGImagePropertyDPIWidth as String: dpi, kCGImagePropertyDPIHeight as String: dpi] as CFDictionary
    CGImageDestinationAddImage(dest, img, props)
    return CGImageDestinationFinalize(dest) ? nil : "The PNG could not be written."
}

extension Wallpaper {
    // The Export Frame item follows the screens: it is made again when the menu opens.
    // One screen: the item exports it at once. Several: a submenu with one item per screen.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let e = menu.items.first(where: { $0.tag == Wallpaper.exportTag }) else { return }
        e.submenu = nil
        e.title = "Export Frame"
        e.action = nil
        e.isHidden = Opt.window || landscapes.isEmpty
        if e.isHidden { return }
        let keys = landscapes.keys.sorted()
        let screens = NSScreen.screens
        if screens.count > 1 {
            let sub = NSMenu()
            for key in keys {
                let name = screens.first { displayID($0) == key }?.localizedName ?? "Screen"
                let i = sub.addItem(withTitle: "\(name)…", action: #selector(exportFrame(_:)), keyEquivalent: "")
                i.representedObject = NSNumber(value: key)
                i.target = self
            }
            e.submenu = sub
        } else {
            e.title = "Export Current Frame…"
            e.action = #selector(exportFrame(_:))
            e.target = self
            e.representedObject = NSNumber(value: keys[0])
        }
    }

    @objc func exportFrame(_ sender: NSMenuItem) {
        guard let key = (sender.representedObject as? NSNumber)?.uint32Value, landscapes[key] != nil else { return }
        NSApp.activate(ignoringOtherApps: true)  // the app has no Dock icon: bring the panel to the front
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "ShanShui \(stamp.string(from: Date())).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, let land = landscapes[key], !land.stopped else { return }
        // The state is taken now, on the main thread. The panning goes on while the PNG is made.
        // The tiles are drawn again at the backing scale (the live tiles have K.pixelScale): temporary, freed after the PNG.
        let u = land.currentU(CACurrentMediaTime())
        let geo = land.exportGeo, engine = land.engine, id = land.id
        DispatchQueue.global(qos: .utility).async {
            let capture = engine.q.sync { engine.exportTiles(id: id, u: u, geo: geo) }
            let error = writePNG(capture, to: url)
            _ = malloc_zone_pressure_relief(nil, 0)  // the screen-size bitmap is freed by now
            guard let message = error else { return }
            DispatchQueue.main.async {
                NSLog("ShanShui export failed: %@", message)
                let alert = NSAlert()
                alert.messageText = "The frame could not be exported."
                alert.informativeText = message
                alert.runModal()
            }
        }
    }
}
