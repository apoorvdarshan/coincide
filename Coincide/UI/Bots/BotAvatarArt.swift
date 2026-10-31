import AppKit
import CoincideKit

/// Draws a bot's avatar: one of seven characters, after the hand-drawn illustrations they come from (an alien, a star,
/// a croissant cat, a pudding pup called Bomboloni, a dizzy cherry, a teddy and Brulee, a girl wearing a melting
/// ice cream). Each is laid out on a
/// 100-point grid, top down, and scaled to the rect. The body takes the bot's color, with its outline and shading
/// mixed from it; eyes, blush and props keep their own colors, switching to dark ink where one would vanish into the
/// body. Small sizes drop the fine details (sparkles, whiskers, waffle lines) and thicken lines so the face still reads
/// in a 16-point menu icon. The colors are the same in light and dark themes: mid-tones that stand out on either.
enum BotAvatarArt {
    /// The body color of a tint.
    static func color(_ tint: BotAvatar.Tint) -> NSColor {
        switch tint {
        case .sunflower: rgb(0xF5C542)
        case .tangerine: rgb(0xF7A24B)
        case .coral: rgb(0xF2786A)
        case .cherry: rgb(0xD9534F)
        case .rose: rgb(0xEE7FAA)
        case .lilac: rgb(0xA98AEF)
        case .sky: rgb(0x63AEF2)
        case .mint: rgb(0x4FCBA2)
        case .leaf: rgb(0x74C163)
        case .sage: rgb(0x93B874)
        case .caramel: rgb(0xD9A063)
        }
    }

    static func name(of shape: BotAvatar.Shape) -> String { shape.defaultName }

    static func name(of tint: BotAvatar.Tint) -> String {
        switch tint {
        case .sunflower: String(localized: "Sunflower")
        case .tangerine: String(localized: "Tangerine")
        case .coral: String(localized: "Coral")
        case .cherry: String(localized: "Cherry")
        case .rose: String(localized: "Rose")
        case .lilac: String(localized: "Lilac")
        case .sky: String(localized: "Sky")
        case .mint: String(localized: "Mint")
        case .leaf: String(localized: "Leaf")
        case .sage: String(localized: "Sage")
        case .caramel: String(localized: "Caramel")
        }
    }

    /// Draws the avatar into `rect` of the current graphics context, which must be flipped (y grows downward).
    /// `openness` is how far the eyes are open, 1 fully and near 0 mid-blink.
    static func draw(_ avatar: BotAvatar, in rect: CGRect, openness: CGFloat = 1) {
        guard let context = NSGraphicsContext.current?.cgContext, rect.width > 0, rect.height > 0 else { return }
        let side = min(rect.width, rect.height)
        let scale = side / 100
        context.saveGState()
        context.translateBy(x: rect.midX - 50 * scale, y: rect.midY - 50 * scale)
        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let pen = Pen(
            context: context, scale: scale, detail: Detail(side: side), body: color(avatar.tint),
            open: max(0.1, min(1, openness)))
        switch avatar.shape {
        case .alien: drawAlien(pen)
        case .star: drawStar(pen)
        case .croissant: drawCroissant(pen)
        case .bomboloni: drawBomboloni(pen)
        case .cherry: drawCherry(pen)
        case .teddy: drawTeddy(pen)
        case .brulee: drawBrulee(pen)
        }
        context.restoreGState()
    }

    /// The avatar as an image, for menus and text.
    static func image(_ avatar: BotAvatar, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(avatar, in: rect)
            return true
        }
        image.accessibilityDescription = String(localized: "Bot avatar")
        return image
    }

    // MARK: Characters

    /// A round green head with eyes on stalks, big starry eyes, pink cheeks and a blue tongue poking out.
    private static func drawAlien(_ pen: Pen) {
        let head = path { p in
            p.move(to: CGPoint(x: 52, y: 26))
            p.curve(73, 25, 88, 40, 87, 59)
            p.curve(86, 78, 71, 90, 51, 90)
            p.curve(31, 89, 16, 77, 16, 58)
            p.curve(16, 39, 31, 27, 52, 26)
        }
        // Stalks and their eyes first, so the head covers where they join.
        for stalk in [(CGPoint(x: 37, y: 33), CGPoint(x: 26, y: 22), CGPoint(x: 17, y: 25)),
            (CGPoint(x: 64, y: 31), CGPoint(x: 72, y: 18), CGPoint(x: 80, y: 15))]
        {
            let line = path { p in
                p.move(to: stalk.0)
                p.addQuadCurve(to: stalk.2, control: stalk.1)
            }
            pen.stroke(line, pen.body, 3.6, minimum: 1.1)
        }
        let balls = [(CGPoint(x: 15, y: 25), CGFloat(-12)), (CGPoint(x: 82, y: 14), CGFloat(-18))]
        for (center, angle) in balls {
            let ball = ellipse(center, 11.5, 8, rotation: angle)
            pen.fill(ball, pen.body)
            pen.edge(ball, soft: true)
            let pupil = ellipse(CGPoint(x: center.x + (center.x < 50 ? -2 : 2), y: center.y), 5, 3.6 * pen.open, rotation: angle)
            pen.fill(pupil, ink)
        }
        // The tongue sits behind the chin, under the head's edge.
        let tongue = path { p in
            p.move(to: CGPoint(x: 44.5, y: 84))
            p.curve(44, 100, 60, 100, 59.5, 84)
            p.closeSubpath()
        }
        pen.fill(tongue, rgb(0x4A6FBF))
        if pen.detail > .tiny {
            pen.stroke(tongue, rgb(0x1D2442), 1.5, minimum: 0.6)
            let groove = path { p in
                p.move(to: CGPoint(x: 52, y: 90))
                p.addLine(to: CGPoint(x: 52, y: 95))
            }
            pen.stroke(groove, rgb(0x1D2442), 1.5, minimum: 0.6)
        }
        pen.fill(head, pen.body)
        pen.edge(head, soft: true)

        // Big almond eyes hugging the sides of the head, leaning in at the top.
        pen.context.saveGState()
        pen.context.addPath(head)
        pen.context.clip()
        let eyes = [(CGPoint(x: 30.5, y: 58), CGFloat(13)), (CGPoint(x: 72.5, y: 54.5), CGFloat(-13))]
        for (center, angle) in eyes {
            pen.fill(ellipse(center, 12.8, 20 * pen.open, rotation: angle), ink)
        }
        pen.context.restoreGState()
        if pen.open > 0.6 {
            for (center, angle) in eyes {
                let side: CGFloat = center.x < 50 ? 1 : -1
                if pen.detail == .full {
                    sparkle(pen, at: rotate(CGPoint(x: center.x + 1, y: center.y - 7.5), around: center, by: angle), radius: 5.2)
                    sparkle(pen, at: rotate(CGPoint(x: center.x - 2 * side, y: center.y + 6.5), around: center, by: angle), radius: 4.6)
                    pen.fill(ellipse(rotate(CGPoint(x: center.x + 4.5 * side, y: center.y + 1), around: center, by: angle), 2.4, 1.6), .white)
                } else if pen.detail == .small {
                    pen.fill(ellipse(rotate(CGPoint(x: center.x + 1, y: center.y - 6), around: center, by: angle), 3.4, 3.4), rgb(0xD8D7D3))
                }
            }
        }
        if pen.detail > .tiny {
            pen.fill(ellipse(CGPoint(x: 40.5, y: 78), 5.2, 2.8, rotation: 20), rgb(0xF4A9D2))
            pen.fill(ellipse(CGPoint(x: 64.5, y: 74.5), 5.2, 2.8, rotation: -10), rgb(0xF4A9D2))
        }
    }

    /// A chubby golden star with brown eyes, peachy blush and a puckered kiss.
    private static func drawStar(_ pen: Pen) {
        // Five slightly uneven arms, the whole star tipped a little to the left, as drawn by hand.
        let center = CGPoint(x: 50, y: 55)
        let outer: [CGFloat] = [47, 46, 47.5, 45.5, 46.5]
        let vertices = (0..<10).map { index -> CGPoint in
            let radius = index.isMultiple(of: 2) ? outer[index / 2] : 23
            let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / 5 - 0.12
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        let star = roundedPolygon(vertices, roundness: { $0.isMultiple(of: 2) ? 0.2 : 0.32 })
        pen.fill(star, pen.body)
        pen.edge(star, soft: true)

        let brown = readable(rgb(0x8A4519), on: pen.body)
        for x: CGFloat in [41.5, 59] {
            pen.fill(ellipse(CGPoint(x: x, y: 47), 4.8, 8 * pen.open, rotation: x < 50 ? 6 : -6), brown)
            if pen.detail == .full, pen.open > 0.6 {
                pen.fill(ellipse(CGPoint(x: x - 1.4, y: 44), 1.7, 2.1), NSColor.white.withAlphaComponent(0.85))
            }
        }
        if pen.detail > .tiny {
            pen.fill(ellipse(CGPoint(x: 34.5, y: 58), 5.4, 3), rgb(0xFA9C9C).withAlphaComponent(0.85))
            pen.fill(ellipse(CGPoint(x: 66, y: 58), 5.4, 3), rgb(0xFA9C9C).withAlphaComponent(0.85))
        }
        let red = rgb(0xE5443B)
        if pen.detail == .tiny {
            pen.fill(ellipse(CGPoint(x: 51, y: 63), 2.6, 2.6), red)
        } else {
            let kiss = path { p in
                p.move(to: CGPoint(x: 53.5, y: 58.8))
                p.curve(49.4, 58, 48.8, 62.2, 51.8, 62.7)
                p.curve(48.6, 63.4, 49.4, 67.8, 53.6, 66.8)
            }
            pen.stroke(kiss, red, 2.4, minimum: 0.9)
        }
    }

    /// A flat orange croissant of a cat: pastry ridges, sparkly eyes close together, whiskers and a little frown.
    private static func drawCroissant(_ pen: Pen) {
        let loaf = path { p in
            p.move(to: CGPoint(x: 13, y: 47))
            p.curve(18, 34, 32, 30, 43, 33)
            p.curve(51, 28, 63, 28, 71, 33)
            p.curve(83, 30, 95, 39, 94, 51)
            p.curve(97, 60, 95, 71, 87, 74)
            p.curve(78, 81, 61, 80, 50, 79)
            p.curve(35, 81, 17, 81, 9, 73)
            p.curve(3, 67, 4, 55, 13, 47)
        }
        pen.fill(loaf, pen.body)
        pen.stroke(loaf, darker(pen.body, 0.18), 2.8, minimum: 0.9)

        let ridge = darker(pen.body, 0.42)
        let ridges: [(CGPoint, CGPoint, CGPoint)] =
            pen.detail == .tiny
            ? [(CGPoint(x: 38, y: 37), CGPoint(x: 33, y: 43), CGPoint(x: 36, y: 50)),
                (CGPoint(x: 62, y: 36), CGPoint(x: 67, y: 42), CGPoint(x: 64, y: 49))]
            : [(CGPoint(x: 33, y: 37), CGPoint(x: 28.5, y: 43), CGPoint(x: 31, y: 51)),
                (CGPoint(x: 45, y: 34), CGPoint(x: 42, y: 39.5), CGPoint(x: 44, y: 46)),
                (CGPoint(x: 57, y: 34), CGPoint(x: 60, y: 39.5), CGPoint(x: 58.5, y: 46)),
                (CGPoint(x: 70, y: 37), CGPoint(x: 74.5, y: 43), CGPoint(x: 72, y: 50))]
        for (start, control, end) in ridges {
            let line = path { p in
                p.move(to: start)
                p.addQuadCurve(to: end, control: control)
            }
            pen.stroke(line, ridge, 2.4, minimum: 0.8)
        }
        if pen.detail == .full {
            for (y, tilt) in [(58.0, -2.0), (62.5, 0.0), (67.0, 2.0)] as [(CGFloat, CGFloat)] {
                for (inner, outer) in [(CGFloat(30), CGFloat(20)), (CGFloat(71), CGFloat(81))] {
                    let whisker = path { p in
                        p.move(to: CGPoint(x: inner, y: y))
                        p.addLine(to: CGPoint(x: outer, y: y + (outer < inner ? tilt : -tilt) * 1.2))
                    }
                    pen.stroke(whisker, ridge, 1.4, minimum: 0.6)
                }
            }
        }

        let radius: CGFloat = pen.detail == .tiny ? 7.5 : 6.6
        for x: CGFloat in [42.5, 59.5] {
            pen.fill(ellipse(CGPoint(x: x, y: 59), radius, radius * pen.open), ink)
            guard pen.open > 0.6 else { continue }
            if pen.detail == .full {
                pen.fill(ellipse(CGPoint(x: x - 2.2, y: 56.4), 2.6, 2.6), .white)
                pen.fill(ellipse(CGPoint(x: x + 2.6, y: 62), 1.3, 1.3), .white)
            } else if pen.detail == .small {
                pen.fill(ellipse(CGPoint(x: x - 2, y: 56.6), 2, 2), .white)
            }
        }
        if pen.detail == .full {
            let red = rgb(0xE5533F).withAlphaComponent(0.85)
            for x: CGFloat in [35, 38.4, 63.6, 67] {
                let dash = path { p in
                    p.move(to: CGPoint(x: x + 1.2, y: 66))
                    p.addLine(to: CGPoint(x: x - 1.2, y: 69))
                }
                pen.stroke(dash, red, 1.3, minimum: 0.6)
            }
        } else if pen.detail == .small {
            pen.fill(ellipse(CGPoint(x: 35.5, y: 67), 3.6, 2), rgb(0xFF6F7F).withAlphaComponent(0.7))
            pen.fill(ellipse(CGPoint(x: 66.5, y: 67), 3.6, 2), rgb(0xFF6F7F).withAlphaComponent(0.7))
        }
        if pen.detail > .tiny {
            let frown = path { p in
                p.move(to: CGPoint(x: 48.5, y: 70))
                p.addQuadCurve(to: CGPoint(x: 53.5, y: 70), control: CGPoint(x: 51, y: 67.6))
            }
            pen.stroke(frown, darker(pen.body, 0.6), 1.5, minimum: 0.7)
        }
    }

    /// A wobbly pudding with a caramel top and a cherry, floppy pup ears, round black eyes and red cheeks.
    private static func drawBomboloni(_ pen: Pen) {
        let outline = darker(pen.body, 0.3)
        let pudding = roundedPolygon(
            [CGPoint(x: 27, y: 24), CGPoint(x: 73.5, y: 23.5), CGPoint(x: 90.5, y: 84), CGPoint(x: 10, y: 84.5)],
            roundness: { _ in 0.08 })
        pen.fill(pudding, lighter(pen.body, 0.55))

        // The caramel pools on top and drips down the sides, kept inside the pudding.
        pen.context.saveGState()
        pen.context.addPath(pudding)
        pen.context.clip()
        let caramel = path { p in
            p.addRect(CGRect(x: 0, y: 0, width: 100, height: 33))
            for (x, width, bottom) in [(33.0, 7.0, 42.0), (48.5, 8.5, 46.5), (63.0, 7.0, 41.0), (76.0, 6.0, 37.0)]
                as [(CGFloat, CGFloat, CGFloat)]
            {
                p.addRoundedRect(
                    in: CGRect(x: x - width / 2, y: 28, width: width, height: bottom - 28), cornerWidth: width / 2,
                    cornerHeight: width / 2)
            }
        }
        pen.fill(caramel, rgb(0x9C5A16))
        pen.context.restoreGState()
        pen.stroke(pudding, outline, 2.4, minimum: 0.8)
        for side: CGFloat in [-1, 1] {
            let ear = path { p in
                p.move(to: CGPoint(x: 50 + 13 * side, y: 25))
                p.curve(50 + 24 * side, 15, 50 + 43 * side, 16, 50 + 48 * side, 27)
                p.curve(50 + 52 * side, 36, 50 + 47 * side, 45, 50 + 39 * side, 43)
                p.curve(50 + 31 * side, 41, 50 + 25 * side, 34, 50 + 19 * side, 31)
                p.curve(50 + 14 * side, 29, 50 + 11 * side, 28, 50 + 13 * side, 25)
            }
            pen.fill(ear, pen.body)
            pen.stroke(ear, outline, 2.2, minimum: 0.7)
        }

        let stem = path { p in
            p.move(to: CGPoint(x: 67.5, y: 11.5))
            p.addQuadCurve(to: CGPoint(x: 77, y: 3.5), control: CGPoint(x: 69.5, y: 4.5))
        }
        pen.stroke(stem, rgb(0x3F7D2E), 2, minimum: 0.7)
        pen.fill(ellipse(CGPoint(x: 66, y: 17), 6.6, 6.2), rgb(0xC8302B))
        if pen.detail == .full {
            pen.fill(ellipse(CGPoint(x: 63.6, y: 15), 1.7, 1.4), NSColor.white.withAlphaComponent(0.8))
        }

        let radius: CGFloat = pen.detail == .tiny ? 7.4 : 6.8
        for x: CGFloat in [37, 63] {
            pen.fill(ellipse(CGPoint(x: x, y: 58), radius, radius * pen.open), ink)
            if pen.detail > .tiny, pen.open > 0.6 {
                pen.fill(ellipse(CGPoint(x: x - 2.3, y: 55.4), 2.1, 2.1), .white)
            }
        }
        if pen.detail > .tiny {
            pen.fill(ellipse(CGPoint(x: 27.5, y: 65.5), 5, 3), rgb(0xF2453D).withAlphaComponent(0.85))
            pen.fill(ellipse(CGPoint(x: 72.5, y: 65.5), 5, 3), rgb(0xF2453D).withAlphaComponent(0.85))
            let mouth = path { p in
                p.move(to: CGPoint(x: 47.4, y: 65))
                p.addQuadCurve(to: CGPoint(x: 50, y: 66.6), control: CGPoint(x: 48.4, y: 67))
                p.addQuadCurve(to: CGPoint(x: 52.6, y: 65), control: CGPoint(x: 51.6, y: 67))
            }
            pen.stroke(mouth, rgb(0x7A4A20), 1.4, minimum: 0.6)
        }
    }

    /// A plump cherry on a hooked stem, with dizzy spiral eyes, red cheeks and a wobbly frown.
    private static func drawCherry(_ pen: Pen) {
        let fruit = path { p in
            p.move(to: CGPoint(x: 51, y: 34))
            p.curve(43, 23, 26, 23, 18, 33)
            p.curve(8, 44, 9, 64, 20, 77)
            p.curve(30, 89, 44, 91, 51, 89)
            p.curve(58, 91, 72, 89, 81, 77)
            p.curve(92, 64, 92, 44, 83, 33)
            p.curve(74, 23, 59, 23, 51, 34)
        }
        if pen.detail > .tiny {
            // The color bleeds a little past the outline, as the watercolor fill does in the drawing.
            var nudge = CGAffineTransform(translationX: -2.4, y: 1.6).translatedBy(x: 50, y: 58).scaledBy(x: 1.04, y: 1.04)
                .translatedBy(x: -50, y: -58)
            if let bleed = fruit.copy(using: &nudge) { pen.fill(bleed, lighter(pen.body, 0.35).withAlphaComponent(0.75)) }
        }
        let green = readable(rgb(0x2A6B2E), on: pen.body)
        let stem = path { p in
            p.move(to: CGPoint(x: 51, y: 34))
            p.curve(50, 24, 53, 13, 64, 8)
        }
        pen.stroke(stem, rgb(0x2A6B2E), 3, minimum: 0.9)
        if pen.detail == .full {
            pen.fill(ellipse(CGPoint(x: 56, y: 16), 4.2, 2.2, rotation: -40), rgb(0x5FA347))
        }
        pen.fill(fruit, pen.body)
        pen.stroke(fruit, darker(pen.body, 0.32), 3, minimum: 0.9)

        let turns: CGFloat = pen.detail == .full ? 2.25 : pen.detail == .small ? 1.75 : 1.25
        let lineWidth: CGFloat = pen.detail == .full ? 2 : 2.8
        for x: CGFloat in [36, 65] {
            pen.stroke(spiral(center: CGPoint(x: x, y: 55), radius: 9.5, turns: turns, squash: pen.open), green, lineWidth,
                minimum: 0.8)
        }
        if pen.detail > .tiny {
            pen.fill(ellipse(CGPoint(x: 23.5, y: 67), 5.6, 3), rgb(0xE6463C).withAlphaComponent(0.9))
            pen.fill(ellipse(CGPoint(x: 77.5, y: 67), 5.6, 3), rgb(0xE6463C).withAlphaComponent(0.9))
        }
        let frown = path { p in
            p.move(to: CGPoint(x: 44, y: 74.5))
            p.curve(45, 68.5, 56, 68.5, 57, 74.5)
            p.curve(54, 72.6, 47, 72.6, 44, 74.5)
        }
        pen.fill(frown, green)
        pen.stroke(frown, green, 1, minimum: 0.5)
    }

    /// A round teddy face with ears, shiny black eyes, pink blush and a soft muzzle.
    private static func drawTeddy(_ pen: Pen) {
        let outline = darker(pen.body, 0.42)
        for x: CGFloat in [22, 78] {
            let ear = ellipse(CGPoint(x: x, y: 26), 14, 13.5)
            pen.fill(ear, pen.body)
            pen.stroke(ear, outline, 2.4, minimum: 0.8)
            if pen.detail > .tiny {
                pen.fill(ellipse(CGPoint(x: x + (x < 50 ? 1 : -1), y: 27.5), 7.5, 7), darker(pen.body, 0.24))
            }
        }
        let face = path { p in
            p.move(to: CGPoint(x: 50, y: 23))
            p.curve(73, 22, 90, 37, 89, 57)
            p.curve(88, 78, 71, 92, 50, 92)
            p.curve(28, 92, 11, 79, 11, 57)
            p.curve(11, 37, 27, 24, 50, 23)
        }
        if pen.detail > .tiny {
            var nudge = CGAffineTransform(translationX: -2, y: 1.8).translatedBy(x: 50, y: 57).scaledBy(x: 1.035, y: 1.035)
                .translatedBy(x: -50, y: -57)
            if let bleed = face.copy(using: &nudge) { pen.fill(bleed, lighter(pen.body, 0.3).withAlphaComponent(0.8)) }
        }
        pen.fill(face, pen.body)
        pen.stroke(face, outline, 2.6, minimum: 0.9)

        for x: CGFloat in [37, 63] {
            pen.fill(ellipse(CGPoint(x: x, y: 51), 5.4, 6.8 * pen.open), ink)
            if pen.detail > .tiny, pen.open > 0.6 {
                pen.fill(ellipse(CGPoint(x: x - 1.6, y: 48.6), 2.1, 2.1), .white)
            }
        }
        if pen.detail > .tiny {
            pen.fill(ellipse(CGPoint(x: 27.5, y: 61), 5, 2.8), rgb(0xF79AC4).withAlphaComponent(0.85))
            pen.fill(ellipse(CGPoint(x: 72.5, y: 61), 5, 2.8), rgb(0xF79AC4).withAlphaComponent(0.85))
        }
        pen.fill(ellipse(CGPoint(x: 50, y: 70), 14, 10.5), darker(pen.body, 0.16))
        pen.fill(ellipse(CGPoint(x: 50, y: 67), 7.5, 4.6), darker(pen.body, 0.45))
    }

    /// A girl with a blocky bob in the bot's color, sleepy blue eyes, a tongue poking out and an ice cream melting on her
    /// head.
    private static func drawBrulee(_ pen: Pen) {
        let line = rgb(0x2E2428)
        let hair = path { p in
            p.move(to: CGPoint(x: 17, y: 34))
            p.addLine(to: CGPoint(x: 83.5, y: 33))
            p.addLine(to: CGPoint(x: 84, y: 95))
            p.addLine(to: CGPoint(x: 59, y: 95.5))
            p.addLine(to: CGPoint(x: 59, y: 86))
            p.addLine(to: CGPoint(x: 41, y: 86))
            p.addLine(to: CGPoint(x: 41, y: 96))
            p.addLine(to: CGPoint(x: 16.5, y: 96))
            p.closeSubpath()
        }
        pen.fill(hair, pen.body)
        pen.stroke(hair, line, 1.5, minimum: 0.6)
        let face = CGPath(rect: CGRect(x: 28, y: 44, width: 44, height: 42), transform: nil)
        pen.fill(face, rgb(0xF8DDB4))
        let bangs = path { p in
            p.move(to: CGPoint(x: 27.5, y: 43))
            p.addLine(to: CGPoint(x: 72.5, y: 43))
            p.addLine(to: CGPoint(x: 72.5, y: 56))
            p.addLine(to: CGPoint(x: 64, y: 56))
            p.addLine(to: CGPoint(x: 64, y: 50))
            p.addLine(to: CGPoint(x: 57, y: 50))
            p.addLine(to: CGPoint(x: 57, y: 54))
            p.addLine(to: CGPoint(x: 46, y: 54))
            p.addLine(to: CGPoint(x: 46, y: 49))
            p.addLine(to: CGPoint(x: 40, y: 49))
            p.addLine(to: CGPoint(x: 40, y: 58))
            p.addLine(to: CGPoint(x: 27.5, y: 58))
            p.closeSubpath()
        }
        pen.fill(bangs, pen.body)
        if pen.detail > .tiny {
            pen.stroke(bangs, line, 1.2, minimum: 0.5)
        }
        if pen.detail == .full {
            // A few strands in a deeper shade, and a shine across the top.
            let strand = darker(pen.body, 0.25)
            for (a, b, c) in [((22.0, 88.0), (25.0, 92.0), (31.0, 85.0)), ((66.0, 90.0), (69.0, 93.0), (75.0, 86.0)),
                ((76.0, 40.0), (79.0, 44.0), (81.0, 37.0)), ((20.0, 46.0), (23.0, 50.0), (25.0, 44.0))]
                as [((CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat))]
            {
                let tick = path { p in
                    p.move(to: CGPoint(x: a.0, y: a.1))
                    p.addLine(to: CGPoint(x: b.0, y: b.1))
                    p.addLine(to: CGPoint(x: c.0, y: c.1))
                }
                pen.stroke(tick, strand, 1.3, minimum: 0.5)
            }
            pen.fill(ellipse(CGPoint(x: 47, y: 38.5), 10, 2.4, rotation: -3), lighter(pen.body, 0.45))
        }

        // Half-shut blue eyes under heavy lids.
        for x: CGFloat in [39.5, 60.5] {
            if pen.open > 0.25 {
                let iris = path { p in
                    p.move(to: CGPoint(x: x - 5.4, y: 66.5))
                    p.addCurve(
                        to: CGPoint(x: x + 5.4, y: 66.5), control1: CGPoint(x: x - 5, y: 66.5 + 7 * pen.open),
                        control2: CGPoint(x: x + 5, y: 66.5 + 7 * pen.open))
                    p.closeSubpath()
                }
                pen.fill(iris, rgb(0x4FB0E6))
                if pen.detail == .full {
                    pen.fill(ellipse(CGPoint(x: x + 0.5, y: 68.6), 1.6, 1.2), NSColor.white.withAlphaComponent(0.85))
                }
            }
            let lid = path { p in
                p.move(to: CGPoint(x: x - 6.2, y: 66.8))
                p.addQuadCurve(to: CGPoint(x: x + 6.2, y: 66.8), control: CGPoint(x: x, y: 64.6))
            }
            pen.stroke(lid, line, 1.6, minimum: 0.7)
            if pen.detail == .full {
                let outward: CGFloat = x < 50 ? -1 : 1
                for (dx, dy) in [(5.6, -1.4), (3.8, -2.6)] as [(CGFloat, CGFloat)] {
                    let lash = path { p in
                        p.move(to: CGPoint(x: x + dx * outward, y: 66 + dy * 0.4))
                        p.addLine(to: CGPoint(x: x + (dx + 1.8) * outward, y: 66 + dy))
                    }
                    pen.stroke(lash, line, 1, minimum: 0.4)
                }
            }
        }
        if pen.detail > .tiny {
            pen.fill(ellipse(CGPoint(x: 34.5, y: 74.5), 4.4, 2.1), rgb(0xF48FA6).withAlphaComponent(0.75))
            pen.fill(ellipse(CGPoint(x: 65.5, y: 74.5), 4.4, 2.1), rgb(0xF48FA6).withAlphaComponent(0.75))
            let mouth = path { p in
                p.move(to: CGPoint(x: 48.2, y: 77))
                p.addQuadCurve(to: CGPoint(x: 51.8, y: 77), control: CGPoint(x: 50, y: 78.2))
            }
            pen.stroke(mouth, line, 1, minimum: 0.5)
        }
        pen.fill(ellipse(CGPoint(x: 50.2, y: 79.4), 1.7, 2), rgb(0xF2708F))

        // The cone tips over on the scoop, which melts down onto the hair.
        let cone = roundedPolygon(
            [CGPoint(x: 28.5, y: 4), CGPoint(x: 57, y: 23), CGPoint(x: 43, y: 31.5)], roundness: { _ in 0.08 })
        pen.fill(cone, rgb(0xF5A0C3))
        if pen.detail == .full {
            pen.context.saveGState()
            pen.context.addPath(cone)
            pen.context.clip()
            let waffle = path { p in
                for offset in stride(from: CGFloat(-10), through: 40, by: 6.5) {
                    p.move(to: CGPoint(x: 20 + offset, y: 0))
                    p.addLine(to: CGPoint(x: 0 + offset, y: 40))
                    p.move(to: CGPoint(x: 10 + offset, y: 0))
                    p.addLine(to: CGPoint(x: 40 + offset, y: 40))
                }
            }
            pen.stroke(waffle, rgb(0x9A5A3A).withAlphaComponent(0.7), 0.9, minimum: 0.35)
            pen.context.restoreGState()
        }
        pen.stroke(cone, rgb(0x6E4129), 1.3, minimum: 0.5)
        let scoop = path { p in
            p.move(to: CGPoint(x: 37, y: 34))
            p.curve(37, 27.5, 44, 24.5, 50, 25.5)
            p.curve(56, 22, 66, 24, 69, 30)
            p.curve(72, 33, 70.5, 36.5, 67, 35.5)
            p.curve(66.5, 40.5, 61.5, 41, 61, 36.5)
            p.curve(57, 37.5, 50, 37.5, 47.5, 36.5)
            p.curve(47, 41.5, 42, 42, 42, 37.5)
            p.curve(39.5, 37.5, 37, 36.5, 37, 34)
        }
        pen.fill(scoop, rgb(0xF7E8C9))
        pen.stroke(scoop, rgb(0x8C5A2B), 1.3, minimum: 0.5)
    }

    // MARK: Drawing helpers

    private static let ink = rgb(0x231E21)

    /// What one avatar is drawn with: the context on its 100-point grid, how much detail its size allows, the body
    /// color and how far the eyes are open.
    private struct Pen {
        let context: CGContext
        let scale: CGFloat
        let detail: Detail
        let body: NSColor
        let open: CGFloat

        func fill(_ path: CGPath, _ color: NSColor) {
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()
        }

        /// A line `units` grid points wide, never thinner than `minimum` points on screen.
        func stroke(_ path: CGPath, _ color: NSColor, _ units: CGFloat, minimum: CGFloat) {
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(units, minimum / scale))
            context.strokePath()
        }

        /// The body's own edge, a shade darker, so pale colors hold their shape on light backgrounds.
        func edge(_ path: CGPath, soft: Bool) {
            stroke(path, BotAvatarArt.darker(body, soft ? 0.2 : 0.38), soft ? 1.5 : 2.4, minimum: 0.7)
        }
    }

    /// How much fits at a size: everything from 34 points, faces without the fine details below that, and only the
    /// shapes that still read below 20.
    private enum Detail: Comparable {
        case tiny, small, full

        init(side: CGFloat) {
            self = side < 20 ? .tiny : side < 34 ? .small : .full
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func darker(_ color: NSColor, _ fraction: CGFloat) -> NSColor {
        color.blended(withFraction: fraction, of: .black) ?? color
    }

    private static func lighter(_ color: NSColor, _ fraction: CGFloat) -> NSColor {
        color.blended(withFraction: fraction, of: .white) ?? color
    }

    /// `preferred` where it stands out on `body`, otherwise dark ink, so a feature never vanishes into a recolored body
    /// (green spirals on a green cherry, say).
    private static func readable(_ preferred: NSColor, on body: NSColor) -> NSColor {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let a = luminance(preferred), b = luminance(body)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05) >= 2.4 ? preferred : ink
    }

    private static func path(_ build: (CGMutablePath) -> Void) -> CGPath {
        let path = CGMutablePath()
        build(path)
        return path
    }

    private static func ellipse(_ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat, rotation degrees: CGFloat = 0) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: degrees * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &transform)
    }

    private static func rotate(_ point: CGPoint, around center: CGPoint, by degrees: CGFloat) -> CGPoint {
        let angle = degrees * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(angle) - dy * sin(angle), y: center.y + dx * sin(angle) + dy * cos(angle))
    }

    /// A closed polygon whose corners are rounded: each corner's curve starts `roundness(index)` of the way along its
    /// two edges.
    private static func roundedPolygon(_ points: [CGPoint], roundness: (Int) -> CGFloat) -> CGPath {
        let path = CGMutablePath()
        func toward(_ from: CGPoint, _ to: CGPoint, _ fraction: CGFloat) -> CGPoint {
            CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
        }
        let count = points.count
        for index in 0..<count {
            let corner = points[index]
            let previous = points[(index + count - 1) % count], next = points[(index + 1) % count]
            let fraction = roundness(index)
            let start = toward(corner, previous, fraction), end = toward(corner, next, fraction)
            if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
            path.addQuadCurve(to: end, control: corner)
        }
        path.closeSubpath()
        return path
    }

    /// An Archimedean spiral winding out from `center`, flattened vertically by `squash` for a blink.
    private static func spiral(center: CGPoint, radius: CGFloat, turns: CGFloat, squash: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let steps = Int(turns * 36)
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let angle = t * turns * 2 * .pi
            let r = radius * t
            let point = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle) * squash)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// A small five-point sparkle, grey with a paler middle, as in the alien's eyes.
    private static func sparkle(_ pen: Pen, at center: CGPoint, radius: CGFloat) {
        let points = (0..<10).map { index -> CGPoint in
            let r = index.isMultiple(of: 2) ? radius : radius * 0.5
            let angle = CGFloat(index) * .pi / 5 - .pi / 2 + 0.2
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        pen.fill(roundedPolygon(points, roundness: { _ in 0.3 }), rgb(0xA9A8A4))
        pen.fill(ellipse(center, radius * 0.34, radius * 0.3), rgb(0xD9D8D4))
    }
}

private extension CGMutablePath {
    /// A cubic curve from the current point, written as the control points and end point's coordinates.
    func curve(_ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
    }
}
