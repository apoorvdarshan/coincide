import Foundation

// The Mac's Settings window, described for the phone to draw the iOS way: pages (the Mac's sidebar), sections and rows,
// with titles already in the Mac's language. The phone renders whatever rows it knows and changes a setting by its key;
// the Mac checks every change against what it just described. Nothing secret is ever described: API keys, tokens,
// password-vault contents and credential-bearing settings stay on the Mac, which sends only whether they are set.

/// Everything Settings shows, in the Mac sidebar's order.
public struct RemoteSettingsSnapshot: Codable, Hashable, Sendable {
    public var pages: [RemoteSettingsPage]

    public init(pages: [RemoteSettingsPage] = []) {
        self.pages = pages
    }

    public func page(_ id: String) -> RemoteSettingsPage? { pages.first { $0.id == id } }
}

/// One of the Mac's Settings panes.
public struct RemoteSettingsPage: Codable, Hashable, Sendable, Identifiable {
    /// `app` for the Mac's panes, `provider` for an agent under Providers, `about` for About.
    public enum Group: String, Codable, Sendable {
        case app, provider, about, unknown

        public init(from decoder: Decoder) throws {
            self = Group(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: String
    public var title: String
    /// An SF Symbol.
    public var symbol: String
    /// The tile's color by name: `gray`, `indigo`, `purple`, `green`, `teal`, `brown`, `cyan`, `blue`, `orange`, `red`.
    public var color: String
    public var group: Group
    /// For a provider: `ready`, `attention` or `off`, the Mac sidebar's status dot.
    public var status: String?
    public var sections: [RemoteSettingsSection]

    public init(
        id: String, title: String, symbol: String, color: String = "gray", group: Group = .app, status: String? = nil,
        sections: [RemoteSettingsSection] = []
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.color = color
        self.group = group
        self.status = status
        self.sections = sections
    }
}

public struct RemoteSettingsSection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var footer: String?
    public var rows: [RemoteSettingsRow]

    public init(id: String, title: String? = nil, footer: String? = nil, rows: [RemoteSettingsRow]) {
        self.id = id
        self.title = title
        self.footer = footer
        self.rows = rows
    }
}

/// A setting's value on the wire.
public enum RemoteSettingValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
}

public struct RemoteSettingOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// One row. Its `id` is the key to change it by (for toggles, choices, numbers and text) or the action to run.
public struct RemoteSettingsRow: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// An on/off setting (`value` is a bool).
        case toggle
        /// One of `options` (`value` is the option's id).
        case choice
        /// A number between `minimum` and `maximum` in steps of `step`.
        case number
        /// Free text.
        case text
        /// A label and its value, read only.
        case info
        /// A state with `state` (`ok`, `warning`, `error`, `off`); with `action`, a button to deal with it.
        case status
        /// A button that runs `id` on the Mac.
        case action
        /// The usage limits gauges, which the phone draws from its own usage request.
        case usage
        /// Another page (`target`), such as a provider's.
        case page
        /// A web link (`url`).
        case link
        /// A kind this version doesn't know, which the phone leaves out.
        case unknown

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var value: RemoteSettingValue?
    public var options: [RemoteSettingOption]?
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    /// A unit after a number, such as "pt".
    public var unit: String?
    public var state: String?
    /// The button of a status row, or the title of an action.
    public var action: String?
    /// The action can't finish on the phone: running it brings up the right place on the Mac.
    public var finishesOnMac: Bool?
    public var isDestructive: Bool?
    /// False for a setting shown but not changeable here right now.
    public var isEnabled: Bool?
    public var target: String?
    public var url: String?

    public init(
        id: String, kind: Kind, title: String, detail: String? = nil, value: RemoteSettingValue? = nil,
        options: [RemoteSettingOption]? = nil, minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil,
        unit: String? = nil, state: String? = nil, action: String? = nil, finishesOnMac: Bool? = nil,
        isDestructive: Bool? = nil, isEnabled: Bool? = nil, target: String? = nil, url: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.value = value
        self.options = options
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.unit = unit
        self.state = state
        self.action = action
        self.finishesOnMac = finishesOnMac
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.target = target
        self.url = url
    }

    /// Every row in a snapshot by id, for checking a change against what was described.
    public static func index(_ snapshot: RemoteSettingsSnapshot) -> [String: RemoteSettingsRow] {
        var rows: [String: RemoteSettingsRow] = [:]
        for page in snapshot.pages {
            for section in page.sections {
                for row in section.rows { rows[row.id] = row }
            }
        }
        return rows
    }
}
