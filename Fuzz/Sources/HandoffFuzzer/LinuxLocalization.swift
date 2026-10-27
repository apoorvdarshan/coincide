import Foundation

#if !canImport(Darwin)
// Linux Foundation has no String(localized:), which Models.swift uses for a few literal display
// names (public, because one is a default argument of a public initializer). The English text is
// enough for fuzzing.
extension String {
    public init(localized key: StaticString) {
        self.init(describing: key)
    }
}
#endif
