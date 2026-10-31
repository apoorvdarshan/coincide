import AppKit
import CoincideKit
import CoincideRemoteKit

/// Draws a bot's avatar on the Mac. The characters themselves are drawn by `BotArtwork` in CoincideRemoteKit, which
/// Coincide Remote shares, so a bot looks the same on the iPhone; this adds the Mac's colors, localized names and images.
enum BotAvatarArt {
    /// The body color of a tint.
    static func color(_ tint: BotAvatar.Tint) -> NSColor {
        let color = BotArtwork.color(artTint(tint))
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        BotArtwork.draw(artCharacter(avatar.shape), tint: artTint(avatar.tint), in: context, rect: rect, openness: openness)
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

    // The shared enums use the names the Mac saves, so these never fall back in practice.
    static func artCharacter(_ shape: BotAvatar.Shape) -> BotArtwork.Character {
        BotArtwork.Character(rawValue: shape.rawValue) ?? .alien
    }

    static func artTint(_ tint: BotAvatar.Tint) -> BotArtwork.Tint {
        BotArtwork.Tint(rawValue: tint.rawValue) ?? .leaf
    }
}
