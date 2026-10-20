// generator.js - runs inside JavaScriptCore (see Sources/Engine.swift). There is no DOM and no SVG here.
// One JSContext serves all screens. Each screen is a "world" (addWorld) with its own state.
// It loads the generator scripts of upstream index.html and hands out chunks as plain text:
//   "=<n>"            first line: the new end of what this world has generated (local units)
//   "#N x y" or "#F x y"  start of a chunk. N = near layer, F = far layer. x is the origin of the chunk (local units,
//                     a whole number). y is the painter's order key (low = far away).
//   "fill stroke width x y x y ..."  one polyline per line. x is relative to the origin of the chunk, y is absolute.
//                     Colors are packed as r*2^24 + g*2^16 + b*2^8 + a (a is 0..255).
// poly() of upstream is replaced, so no SVG string is ever built. The only other thing upstream draws is
// one <text> sign on a few houses. It is dropped.
var window = this, self = this;
var console = { log() {}, warn() {}, error() {} };
var document = { addEventListener() {}, getElementById() { return null; } };
window.location = { href: "" };
window.btoa = s => s;  // upstream Prng.hash only needs some deterministic string

var SS = (() => {
  const TW = 512;       // width of one planning slice (upstream MEM.cwid)
  const PERIOD = 409600;  // upstream placement noise repeats after this many units in x (4096 / 0.01, see mountplanner)
  const s = { r: 0 };
  const worlds = new Map();  // id -> { n, off, planTo, farTo, density }
  let W = null;      // the world that is being built
  let out = null;    // polyline lines of the chunk that is being built
  let cx = 0;        // origin of that chunk, local units
  const colors = new Map();

  function col(v) {
    let c = colors.get(v);
    if (c === undefined) {
      if (v === "white") c = 4294967295;
      else {
        const m = String(v).match(/[\d.]+/g);  // "rgba(100,100,100,0.5)" -> 100 100 100 0.5. "none" -> null.
        c = m && m.length >= 3 ? ((+m[0] * 256 + +m[1]) * 256 + +m[2]) * 256 + Math.round((m.length > 3 ? +m[3] : 1) * 255) : 0;
      }
      if (colors.size > 5000) colors.clear();
      colors.set(v, c);
    }
    return c;
  }

  // Same arguments as poly() of upstream. A polygon is filled, then stroked, like an SVG polyline.
  // x goes out as (x - world offset - chunk origin): small numbers, whatever the offset is.
  function polyOut(plist, args) {
    if (!out) return "";
    const a = args || {};
    const fil = a.fil != undefined ? a.fil : "rgba(0,0,0,0)";
    const str = a.str != undefined ? a.str : fil;
    const wid = a.wid != undefined ? a.wid : 0;
    const f = col(fil), k = wid > 0 ? col(str) : 0;
    if ((f & 255) === 0 && (k & 255) === 0) return "";  // nothing to see
    const xof = (a.xof || 0) - W.off - cx, yof = a.yof || 0;
    let line = f + " " + k + " " + (+wid).toFixed(2);
    let n = 0;
    for (let i = 0; i < plist.length; i++) {
      const x = plist[i][0] + xof, y = plist[i][1] + yof;
      if (isFinite(x) && isFinite(y)) {  // upstream writes -1000 for NaN, we skip the point
        line += " " + x.toFixed(1) + " " + y.toFixed(1);
        n++;
      }
    }
    if (n > 1) out.push(line);
    return "";
  }

  // x is the world x of the chunk
  function emit(layer, x, y, draw) {
    cx = Math.round(x - W.off);
    out = [];
    draw();
    const body = out.join("\n");
    out = null;
    return body ? "#" + layer + " " + cx + " " + y.toFixed(1) + "\n" + body + "\n" : "";
  }

  // The same builders as upstream chunkloader().
  function build(p) {
    if (p.tag == "mount")
      return emit("N", p.x, p.y, () => Mount.mountain(p.x, p.y, Math.random() * 20)) +
        emit("N", p.x, p.y - 10000, () => water(p.x, p.y, 0));  // water lines go below everything
    if (p.tag == "flatmount")
      return emit("N", p.x, p.y, () => Mount.flatMount(p.x, p.y, 2 * Math.random() * Math.PI, {
        wid: 600 + Math.random() * 400, hei: 100, cho: 0.5 + Math.random() * 0.2,
      }));
    if (p.tag == "boat")
      return emit("N", p.x, p.y, () => Arch.boat01(p.x, p.y, Math.random(), {
        sca: p.y / 800, fli: randChoice([true, false]),
      }));
    return "";
  }

  // returns "ok" when upstream loaded, else the error message.
  s.load = (html, seed) => {
    try {
      const head = html.slice(0, html.indexOf("<body"));  // the scripts before <body> are the generator. UI and downloader are skipped.
      for (const m of head.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g))
        if (!/id="(downloader|UI)"/.test(m[1])) (0, eval)(m[2]);  // indirect eval: global scope
      Math.seed(seed);  // upstream seeded itself from the clock at load. Seed again, before the first Noise call.
      poly = polyOut;
      s.r = Math.random();
      return "ok";
    } catch (e) {
      return "load: " + e;
    }
  };

  // A world is one screen. Each world reads another part of the one infinite landscape of upstream:
  // its local x = 0 is at world x = off. The placement of mountains comes from Perlin noise that has the period
  // PERIOD in x, so off mod PERIOD is chosen different for every world (golden ratio steps, random start per launch).
  // off itself is a few million, so that two worlds never overlap in x. Items are planned at world x, and the chunks
  // go out in local x (x - off).
  s.addWorld = (id, density) => {
    const used = new Set([...worlds.values()].map(w => w.n));
    let n = 0;
    while (used.has(n)) n++;
    const phase = ((n * 0.6180339887 + s.r) % 1) * PERIOD;
    worlds.set(id, { n, off: Math.floor((n + 1) * 10 * PERIOD + phase), planTo: -1024, farTo: -1500, density });
  };
  s.removeWorld = id => { worlds.delete(id); };
  s.setDensity = (id, d) => { const w = worlds.get(id); if (w) w.density = d; };

  // Plans the next slice of a world and builds what the planner found.
  // Density: below 1 each item is kept with probability density. Above 1 each mountain
  // gets an extra neighbour with probability density - 1. Upstream look = 1.
  s.nearSlice = id => {
    W = worlds.get(id);
    if (!W) return "";
    const a = W.planTo + W.off;
    W.planTo += TW;
    MEM.planmtx = [];  // mountplanner only reads counts it wrote itself in this slice
    const d = W.density, keep = Math.min(1, d);
    let text = "";
    for (const p of mountplanner(a, W.planTo + W.off)) {
      if (p.tag == "distmount" || Math.random() >= keep) continue;  // the far layer makes its own hills
      try {
        text += build(p);
        if (p.tag == "mount" && Math.random() < d - 1)
          text += build({ tag: "mount", x: p.x + (Math.random() - 0.5) * 400, y: Math.min(p.y + Math.random() * 80, 700) });
      } catch (e) {
        out = null;  // a failed item is lost, the rest stays
      }
    }
    return "=" + W.planTo + "\n" + text;
  };

  // The next far hill range of a world, in far coordinates: one per 1000 units, like upstream.
  s.farNext = id => {
    W = worlds.get(id);
    if (!W) return "";
    const x = W.farTo + W.off, y = 280 - Math.random() * 50;
    W.farTo += 1000;
    let text = "";
    try {
      text = emit("F", x, y, () => Mount.distMount(x, y, Math.random() * 100, {
        hei: 150, len: randChoice([500, 1000, 1500]),
      }));
    } catch (e) {
      out = null;
    }
    return "=" + W.farTo + "\n" + text;
  };

  return s;
})();
