#!/usr/bin/env swift
import CoreGraphics
import Foundation

// Usage: swift scripts/bot-symbol.swift
// Generates the Bots tab's custom SF Symbol, Coincide's alien drawn as a template: a round head, big almond eyes
// leaning in, and the two eyes on stalks that read as a bot's antennae. Static glyphs for all nine weights and three
// scales, each drawn with the stroke the system's own symbols use at that weight and scale.

let weights = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
let scaleNames = ["S", "M", "L"]
// Measured from the system's `circle` symbol at 100 pt.
let strokes: [[CGFloat]] = [
    [2.25, 3.5, 5.75, 7.5, 8.75, 9.5, 10.75, 12.5, 14.25],
    [2.25, 3.75, 6.25, 8.25, 9.75, 11, 12.75, 15, 17.25],
    [2.5, 4, 7, 9.25, 11.25, 12.75, 15, 18, 20.25],
]
let geometryScale: [CGFloat] = [1, 98.75 / 78.75, 129 / 78.75]
let capMiddle: CGFloat = 35.23

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ deg: CGFloat = 0) -> CGPath {
    var t = CGAffineTransform(translationX: cx, y: cy).rotated(by: deg * .pi / 180)
    return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &t)
}
func stroked(_ p: CGPath, _ w: CGFloat) -> CGPath {
    p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4)
}
func union(_ paths: [CGPath]) -> CGPath { paths.dropFirst().reduce(paths[0]) { $0.union($1) } }
func build(_ b: (CGMutablePath) -> Void) -> CGPath { let p = CGMutablePath(); b(p); return p }

/// The glyph at the Regular-S size (y down), drawn with lines `w` wide; heavier weights shrink the eyes a little so
/// they keep clear of the head's edge.
func alien(_ w: CGFloat, filled: Bool) -> CGPath {
    let cx: CGFloat = 41, cy: CGFloat = 53.5, rx: CGFloat = 33, ry: CGFloat = 27
    let extra = w - 7.5
    let eyeRX = 8.6 - extra * 0.28, eyeRY = 13.2 - extra * 0.3
    let eyeDX = 15.5 - extra * 0.12
    let eyes = [ellipse(cx - eyeDX, 53, eyeRX, eyeRY, 18), ellipse(cx + eyeDX, 53, eyeRX, eyeRY, -18)]
    let stems = [
        build { $0.move(to: CGPoint(x: 29, y: 30)); $0.addQuadCurve(to: CGPoint(x: 11, y: 11), control: CGPoint(x: 22, y: 16)) },
        build { $0.move(to: CGPoint(x: 53, y: 30)); $0.addQuadCurve(to: CGPoint(x: 71, y: 11), control: CGPoint(x: 60, y: 16)) },
    ].map { stroked($0, w) }
    let ballR = 8.5 + extra * 0.5
    let balls = [ellipse(10, 10, ballR, ballR), ellipse(72, 10, ballR, ballR)]
    if filled {
        return union(stems + balls + [ellipse(cx, cy, rx + w / 2, ry + w / 2)]).subtracting(union(eyes))
    }
    let ring = union(stems + balls + [stroked(ellipse(cx, cy, rx, ry), w)]).subtracting(ellipse(cx, cy, rx - w / 2, ry - w / 2))
    return union([ring] + eyes)
}

func f(_ v: CGFloat) -> String {
    let s = String(format: "%.3f", Double(v))
    var t = s
    while t.hasSuffix("0") { t.removeLast() }
    if t.hasSuffix(".") { t.removeLast() }
    return t == "-0" ? "0" : t
}
func svgPath(_ path: CGPath) -> String {
    var out = ""
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: out += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: out += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: out += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: out += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: out += "Z"
        @unknown default: break
        }
    }
    return out
}

/// One glyph, placed with its left edge at x = 0 and centred on the cap height's middle above a baseline at y = 0.
struct Placed { let path: CGPath; let width: CGFloat }
func placed(weight: Int, scale: Int, filled: Bool) -> Placed {
    let k = geometryScale[scale]
    let w = strokes[scale][weight] / k  // in Regular-S units, so it comes out right after scaling
    let raw = alien(w, filled: filled)
    let box = raw.boundingBox
    var t = CGAffineTransform(translationX: -box.minX, y: -box.midY).concatenating(CGAffineTransform(scaleX: k, y: k))
        .concatenating(CGAffineTransform(translationX: 0, y: -capMiddle))
    return Placed(path: raw.copy(using: &t)!, width: box.width * k)
}

func template(filled: Bool) -> String {
    let baselines: [CGFloat] = [696, 1126, 1556]
    let capOffset: CGFloat = 70.459
    let columnX: [CGFloat] = (0..<9).map { 559.5 + CGFloat($0) * 296.5 }
    var guides = "", symbols = "", notes = ""
    notes += """
      <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
      <line style="fill:none;stroke:black;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="292" y2="292"/>
      <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;font-weight:bold;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
      <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
      <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1951)">Coincide bot (the alien), generated</text>

    """
    for (si, sn) in scaleNames.enumerated() {
        guides += "  <line id=\"Baseline-\(sn)\" style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\" x1=\"263\" x2=\"3036\" y1=\"\(f(baselines[si]))\" y2=\"\(f(baselines[si]))\"/>\n"
        guides += "  <line id=\"Capline-\(sn)\" style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\" x1=\"263\" x2=\"3036\" y1=\"\(f(baselines[si] - capOffset))\" y2=\"\(f(baselines[si] - capOffset))\"/>\n"
        for (wi, wn) in weights.enumerated() {
            let g = placed(weight: wi, scale: si, filled: filled)
            let left = columnX[wi] - g.width / 2
            let right = left + g.width
            let y1 = f(baselines[si] - 95), y2 = f(baselines[si] + 24)
            guides += "  <line id=\"left-margin-\(wn)-\(sn)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(f(left))\" x2=\"\(f(left))\" y1=\"\(y1)\" y2=\"\(y2)\"/>\n"
            guides += "  <line id=\"right-margin-\(wn)-\(sn)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(f(right))\" x2=\"\(f(right))\" y1=\"\(y1)\" y2=\"\(y2)\"/>\n"
            symbols += "  <g id=\"\(wn)-\(sn)\" transform=\"matrix(1 0 0 1 \(f(left)) \(f(baselines[si])))\">\n   <path d=\"\(svgPath(g.path))\"/>\n  </g>\n"
        }
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <!--Generated by scripts/bot-symbol.swift; edit that and run it again rather than this file.-->
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <!--glyph: "coincide.bot\(filled ? ".fill" : "")", point size: 100.0-->
     <g id="Notes">
    \(notes) </g>
     <g id="Guides">
    \(guides) </g>
     <g id="Symbols">
    \(symbols) </g>
    </svg>

    """
}

// Coincide Remote's Bots tab.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
for catalog in ["CoincideRemote/Assets.xcassets"] {
    for filled in [false, true] {
        let name = filled ? "coincide.bot.fill" : "coincide.bot"
        let file = root.appendingPathComponent("\(catalog)/\(name).symbolset/\(name).svg")
        try! template(filled: filled).write(to: file, atomically: true, encoding: .utf8)
        print(file.path)
    }
}
