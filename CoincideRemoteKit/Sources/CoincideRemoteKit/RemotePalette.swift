import Foundation

/// Coincide's color themes as sRGB hex values, the same as the Mac's `AppTheme`, for Coincide Remote to draw with.
public struct RemotePalette: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let sidebar: UInt32
    public let content: UInt32
    public let surface: UInt32
    public let raised: UInt32
    public let border: UInt32
    /// The conversation's text, or nil for the system's label color.
    public let ink: UInt32?
    public let accent: UInt32
    public var borderWidth: Double = 1
    public var emphasis: Double = 1

    public static let defaultDarkID = "carbon"
    public static let defaultLightID = "carbon-light"

    public static let dark: [RemotePalette] = [
        RemotePalette(
            id: "carbon", name: "Carbon", isDark: true, sidebar: 0x0B0B0B, content: 0x000000, surface: 0x161616, raised: 0x141414,
            border: 0x2A2A2A, ink: nil, accent: 0xFF8A3D),
        RemotePalette(
            id: "graphite", name: "Graphite", isDark: true, sidebar: 0x181818, content: 0x212121, surface: 0x2B2B2B,
            raised: 0x282828, border: 0x333333, ink: nil, accent: 0x9DB4FF),
        RemotePalette(
            id: "midnight", name: "Midnight", isDark: true, sidebar: 0x0E1320, content: 0x141A28, surface: 0x1C2333,
            raised: 0x1A2130, border: 0x2A3347, ink: 0xDCE3F0, accent: 0x6FA8FF),
        RemotePalette(
            id: "slate", name: "Slate", isDark: true, sidebar: 0x23262B, content: 0x2A2E34, surface: 0x333840, raised: 0x31353C,
            border: 0x40464F, ink: 0xD8DCE2, accent: 0x7FB8C9),
        RemotePalette(
            id: "forest", name: "Forest", isDark: true, sidebar: 0x0D1410, content: 0x111A15, surface: 0x18241D, raised: 0x16211A,
            border: 0x26362C, ink: 0xD4E2D8, accent: 0x6FD08C),
        RemotePalette(
            id: "plum", name: "Plum", isDark: true, sidebar: 0x140F18, content: 0x1A1420, surface: 0x241B2C, raised: 0x211928,
            border: 0x352841, ink: 0xE6DDF0, accent: 0xC58BF2),
        RemotePalette(
            id: "ocean", name: "Ocean", isDark: true, sidebar: 0x08161B, content: 0x0C1D23, surface: 0x12292F, raised: 0x10252B,
            border: 0x1E3B43, ink: 0xD3EBEF, accent: 0x3FC5D6),
        RemotePalette(
            id: "ember", name: "Ember", isDark: true, sidebar: 0x15100D, content: 0x1B1512, surface: 0x261D18, raised: 0x231B16,
            border: 0x3A2C24, ink: 0xEDE2D6, accent: 0xFF7A45),
        RemotePalette(
            id: "dusk", name: "Dusk", isDark: true, sidebar: 0x12111F, content: 0x171627, surface: 0x201F35, raised: 0x1D1C31,
            border: 0x2F2D4A, ink: 0xDEDCF5, accent: 0xA08CFF),
        RemotePalette(
            id: "phosphor", name: "Phosphor", isDark: true, sidebar: 0x040805, content: 0x060B07, surface: 0x0D150F,
            raised: 0x0B130D, border: 0x1C2B1F, ink: 0xB7F5C2, accent: 0x5CF07A),
        RemotePalette(
            id: "high-contrast", name: "High Contrast", isDark: true, sidebar: 0x000000, content: 0x000000, surface: 0x000000,
            raised: 0x000000, border: 0xFFFFFF, ink: 0xFFFFFF, accent: 0xFFD400, borderWidth: 2, emphasis: 2.5),
    ]

    public static let light: [RemotePalette] = [
        RemotePalette(
            id: "carbon-light", name: "Carbon Light", isDark: false, sidebar: 0xF5F5F5, content: 0xFFFFFF, surface: 0xFFFFFF,
            raised: 0xF5F5F5, border: 0xE1E1E1, ink: 0x111111, accent: 0xE8660F),
        RemotePalette(
            id: "paper", name: "Paper", isDark: false, sidebar: 0xF2F0EC, content: 0xFBFAF8, surface: 0xFFFFFF, raised: 0xF2F0EC,
            border: 0xE4E0D8, ink: nil, accent: 0xC26A2E),
        RemotePalette(
            id: "arctic", name: "Arctic", isDark: false, sidebar: 0xEDF2F6, content: 0xF7FAFC, surface: 0xFFFFFF, raised: 0xEDF2F6,
            border: 0xD9E2EA, ink: 0x1E2A36, accent: 0x2F7FD6),
        RemotePalette(
            id: "sepia", name: "Sepia", isDark: false, sidebar: 0xEEE5D3, content: 0xF6EFE1, surface: 0xFBF6EC, raised: 0xEEE5D3,
            border: 0xDDD0B8, ink: 0x3B2F22, accent: 0xA0602A),
        RemotePalette(
            id: "rose", name: "Rose", isDark: false, sidebar: 0xF5EBED, content: 0xFCF6F7, surface: 0xFFFFFF, raised: 0xF5EBED,
            border: 0xEBD8DC, ink: 0x2E1D24, accent: 0xD14D72),
        RemotePalette(
            id: "lavender", name: "Lavender", isDark: false, sidebar: 0xEFEBF8, content: 0xF8F6FC, surface: 0xFFFFFF,
            raised: 0xEFEBF8, border: 0xDDD6EE, ink: 0x241F33, accent: 0x7A5AE0),
        RemotePalette(
            id: "sand", name: "Sand", isDark: false, sidebar: 0xEDE9E1, content: 0xF7F5F0, surface: 0xFFFFFF, raised: 0xEDE9E1,
            border: 0xDDD7CB, ink: 0x2B2A24, accent: 0xB8862E),
        RemotePalette(
            id: "mint", name: "Mint", isDark: false, sidebar: 0xEAF4EE, content: 0xF5FAF7, surface: 0xFFFFFF, raised: 0xEAF4EE,
            border: 0xD3E6DA, ink: 0x1C2A22, accent: 0x1F9D6A),
    ]

    public static func dark(_ id: String) -> RemotePalette { dark.first { $0.id == id } ?? dark[0] }
    public static func light(_ id: String) -> RemotePalette { light.first { $0.id == id } ?? light[0] }

    /// Each agent's color (light, dark), as on the Mac.
    public static func agentColor(_ provider: String) -> (light: UInt32, dark: UInt32) {
        switch provider {
        case "claude": (0xC2603D, 0xE08A6B)
        case "codex": (0x0E8A6A, 0x3CC79A)
        case "cursor": (0x5A5FD6, 0x9A9EFF)
        case "grok": (0x6B7077, 0xA9AEB4)
        case "opencode": (0xB7700C, 0xE9B04E)
        case "antigravity": (0x2F6BDB, 0x6FA3FF)
        default: (0x6B7077, 0xA9AEB4)
        }
    }
}
