import Foundation
import Testing
@testable import CoincideKit

struct NumberFormattingTests {
    @Test(arguments: ["en_IN", "en_US@rg=inzzzz", "en_US", "de_DE"])
    func internationalNumbersDoNotInheritRegionalGrouping(_ identifier: String) {
        let numbers = NumberFormatting(.international, systemLocale: Locale(identifier: identifier))
        #expect(numbers.integer(1_234_567_890) == "1,234,567,890")
        #expect(numbers.integer(-1_234_567_890) == "-1,234,567,890")
        #expect(numbers.decimal(1_250_000.5) == "1,250,000.5")
        #expect(numbers.decimal(-1_250_000.5) == "-1,250,000.5")
        #expect(numbers.currency(1_250_000.5) == "$1,250,000.50")
        #expect(numbers.currency(1_250_000.5, code: "INR") == "₹1,250,000.50")
        #expect(numbers.compact(1_250_000, significantDigits: 1...3) == "1.25M")
        #expect(numbers.compact(1_250_000_000, significantDigits: 1...3) == "1.25B")
        #expect(numbers.percent(0.055, fractionDigits: 1) == "5.5%")
    }

    @Test(arguments: ["en_IN", "en_US@rg=inzzzz"])
    func systemRetainsTheUsersRegionalGrouping(_ identifier: String) {
        let numbers = NumberFormatting(.system, systemLocale: Locale(identifier: identifier))
        #expect(numbers.integer(1_234_567_890) == "1,23,45,67,890")
        #expect(numbers.decimal(1_250_000.5) == "12,50,000.5")
        #expect(numbers.locale.identifier == identifier)
    }

    @Test func systemRetainsDecimalSeparatorsAndCompactNames() {
        let german = NumberFormatting(.system, systemLocale: Locale(identifier: "de_DE"))
        #expect(german.decimal(1_250_000.5) == "1.250.000,5")
        let indian = NumberFormatting(.system, systemLocale: Locale(identifier: "en_IN"))
        #expect(indian.compact(1_250_000, significantDigits: 1...3) == "12.5L")
    }

    @Test func currencyAndFractionPrecisionArePreserved() {
        let numbers = NumberFormatting(.international)
        #expect(numbers.currency(12.34567, fractionDigits: 4) == "$12.3457")
        #expect(numbers.currency(1_250_000.5, fractionDigits: 0) == "$1,250,000")
        #expect(numbers.decimal(12.34567, fractionDigits: 0...2) == "12.35")
        #expect(numbers.decimal(12, fractionDigits: 0...2) == "12")
    }

    @Test func providerNumericBalancesStayParseableBeforePresentation() throws {
        let credits = try #require(CodexUsageLimits.credits([
            "hasCredits": true, "unlimited": false, "balance": 1_250_000.5,
        ]))
        #expect(credits.balance == "1250000.5")
        #expect(credits.balance.flatMap(Double.init) == 1_250_000.5)
    }
}

struct NumberFormatSettingsTests {
    @Test func systemIsTheDefaultForOldAndInvalidSettings() throws {
        #expect(AppSettings().numberFormat == .system)
        for value in ["{}", #"{"numberFormat":"future","fontSize":15}"#, #"{"numberFormat":7,"fontSize":15}"#] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(value.utf8))
            #expect(settings.numberFormat == .system)
            if value != "{}" { #expect(settings.fontSize == 15) }
        }
    }

    @MainActor @Test func theChoiceSurvivesStoreReconstruction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("number-format-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        store.updateSettings { $0.numberFormat = .international }
        store.flush()
        #expect(AppStore(directory: directory).settings.numberFormat == .international)
        let data = try JSONEncoder().encode(store.settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == store.settings)
    }
}
