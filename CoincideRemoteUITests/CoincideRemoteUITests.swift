import XCTest

/// Coincide Remote on its sample data (`-CoincideRemoteDemo`, DemoData.swift): no Mac, no App Store and no RevenueCat.
/// The sample prices are the demo's own, and `-CoincideRemoteDemoPro` stands in for a Coincide Pro purchase.
final class CoincideRemoteUITests: XCTestCase {
    /// Long enough for a cold launch on a CI simulator; a passing check returns as soon as the element shows.
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CoincideRemoteDemo"] + arguments
        app.launch()
        return app
    }

    /// The first element of any kind whose label contains the text, such as a row that combines its name and price.
    @MainActor
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func waitForPaywall(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["Unlock Coincide"].waitForExistence(timeout: timeout), "The paywall didn't show", file: file, line: line)
        // The demo's plans, with the yearly one and its free trial picked first.
        XCTAssertTrue(element(app, containing: "Yearly").exists, file: file, line: line)
        XCTAssertTrue(element(app, containing: "Lifetime").exists, file: file, line: line)
        XCTAssertTrue(app.buttons["Start Free Trial"].exists, file: file, line: line)
    }

    // MARK: Launch

    /// A paired Mac's workspace: the tabs, and a project with its threads.
    @MainActor
    func testLaunchShowsTheTabsAndTheMacsProjects() {
        let app = launch("-CoincideRemoteTab", "projects")
        // Rows read as one element each, so they're found by part of their label.
        XCTAssertTrue(element(app, containing: "iPhone image previews in threads").waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, containing: "coincide, ~/coincide").exists)
        for tab in ["Bots", "Projects", "Chats", "Settings"] {
            XCTAssertTrue(app.buttons[tab].firstMatch.exists, "No \(tab) tab")
        }
    }

    // MARK: Pairing

    /// Before any Mac is paired, the app opens on the Connect screen: scan or paste the Mac's code, or see the plans.
    @MainActor
    func testFirstLaunchShowsThePairingScreen() {
        let app = launch("-CoincideRemoteDemoUnpaired")
        XCTAssertTrue(app.staticTexts["Connect to Coincide"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["Paste Pairing Code"].exists)
        XCTAssertTrue(app.buttons["Coincide Pro Plans"].exists)
        XCTAssertFalse(app.buttons["Projects"].exists, "The tabs showed with no Mac paired")

        // The scanner, which a simulator has no camera for, closes again.
        app.buttons["Scan Pairing Code"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Camera Unavailable"].exists || element(app, containing: "Point the camera").exists)
        cancel.tap()
        XCTAssertTrue(app.buttons["Paste Pairing Code"].waitForExistence(timeout: timeout))

        // The plans, before pairing, without an action that needs them.
        app.buttons["Coincide Pro Plans"].tap()
        waitForPaywall(app)
    }

    // MARK: Coincide Pro

    /// Browsing is free; an action (here, a new bot) shows the paywall instead of running, and closing it runs nothing.
    @MainActor
    func testAnActionShowsThePaywallWithoutPro() {
        let app = launch("-CoincideRemoteTab", "bots")
        let newBot = app.buttons["New Bot"].firstMatch
        XCTAssertTrue(newBot.waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, containing: "Brulee").exists, "Bots should be browsable without Pro")
        newBot.tap()
        waitForPaywall(app)

        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Unlock Coincide"].waitForNonExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["Create"].exists, "The bot editor opened without Pro")
    }

    /// With Coincide Pro the same action runs: the bot editor opens, with no paywall.
    @MainActor
    func testProRunsTheActionWithoutThePaywall() {
        let app = launch("-CoincideRemoteDemoPro", "-CoincideRemoteTab", "bots")
        let newBot = app.buttons["New Bot"].firstMatch
        XCTAssertTrue(newBot.waitForExistence(timeout: timeout))
        newBot.tap()
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: timeout), "The bot editor didn't open")
        XCTAssertFalse(app.staticTexts["Unlock Coincide"].exists)
        app.buttons["Cancel"].tap()
    }

    // MARK: Uncommitted changes

    /// A thread's Uncommitted Changes carries the Mac diff panel's Git actions bar, whose git state loads when it appears.
    /// Inside an empty Group it never appeared, so the state never loaded and the bar never showed (#216).
    @MainActor
    func testUncommittedChangesShowTheGitActionsBar() {
        // With the thread's turn over: a running turn keeps the app animating, and each tap then waited a minute for it to
        // go idle.
        let app = launch("-CoincideRemoteTab", "projects", "-CoincideRemoteDemoThread", "-CoincideRemoteDemoIdle")
        let threadActions = app.buttons["Thread Actions"].firstMatch
        XCTAssertTrue(threadActions.waitForExistence(timeout: timeout))
        threadActions.tap()
        let uncommittedChanges = app.buttons["Uncommitted Changes"].firstMatch
        XCTAssertTrue(uncommittedChanges.waitForExistence(timeout: timeout))
        uncommittedChanges.tap()
        XCTAssertTrue(app.buttons["Git Actions"].firstMatch.waitForExistence(timeout: timeout), "The Git actions bar didn't show")
        // The demo's branch, beside its actions.
        XCTAssertTrue(element(app, containing: "remote-image-previews").exists)
    }

    // MARK: Tips

    /// Settings lists the four tips with their prices, which need no Coincide Pro.
    @MainActor
    func testSettingsListsTheTips() {
        let app = launch("-CoincideRemoteTab", "settings", "-CoincideRemoteDemoScrollTips")
        let header = app.staticTexts["Support Coincide"]
        XCTAssertTrue(header.waitForExistence(timeout: timeout))
        let tips = [("Small Commit", "$1.99"), ("Clean Diff", "$4.99"), ("Green CI", "$9.99"), ("Ship It", "$19.99")]
        for (name, price) in tips {
            let row = element(app, containing: name)
            for _ in 0..<4 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists, "No \(name) tip")
            XCTAssertTrue(row.label.contains(price) || element(app, containing: price).exists, "No price for \(name)")
        }
        XCTAssertTrue(element(app, containing: "They unlock nothing").exists)
    }
}
