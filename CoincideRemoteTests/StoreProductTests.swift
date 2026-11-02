import Foundation
import Testing

@testable import CoincideRemote

/// The products the app sells (Coincide Pro's plans and the tips) are the ones the local StoreKit configuration lists
/// (`CoincideRemote/StoreKit/Coincide.storekit`, which Xcode's Run buys from), so a renamed product can't drift.
struct StoreProductTests {
    private final class BundleToken {}

    /// Every `productID` in the StoreKit configuration file, which this bundle carries as a resource.
    private func storeKitProductIDs() throws -> Set<String> {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Coincide", withExtension: "storekit"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var ids = Set<String>()
        func collect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let id = dictionary["productID"] as? String { ids.insert(id) }
                dictionary.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        collect(root)
        return ids
    }

    @Test func theStoreKitConfigurationListsExactlyTheProductsTheAppSells() throws {
        let sold = Set(ProPlan.Kind.allCases.map(\.productID) + TipKind.allCases.map(\.productID))
        #expect(try storeKitProductIDs() == sold)
    }

    @Test func productIDsAreUniqueAndUnderTheAppsBundleID() {
        let ids = ProPlan.Kind.allCases.map(\.productID) + TipKind.allCases.map(\.productID)
        #expect(Set(ids).count == ids.count)
        for id in ids { #expect(id.hasPrefix("com.apoorvdarshan.coincide.remote."), "\(id)") }
    }

    /// Four tips, each with its own title, symbol and thank-you.
    @Test func everyTipHasItsOwnTitleAndThanks() {
        #expect(TipKind.allCases.count == 4)
        #expect(Set(TipKind.allCases.map(\.title)).count == 4)
        #expect(Set(TipKind.allCases.map(\.thanks)).count == 4)
        #expect(TipKind.allCases.allSatisfy { !$0.symbol.isEmpty })
    }
}
