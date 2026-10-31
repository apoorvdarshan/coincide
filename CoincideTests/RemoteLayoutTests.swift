import CoreGraphics
import Testing

/// Coincide Remote's layout rules (`CoincideRemote/UI/RemoteLayout.swift`, compiled into this suite): when the list
/// and a thread sit side by side, and where the composer's controls go at every width.
struct RemoteLayoutTests {
    // MARK: Side by side

    @Test func theListAndThreadSitSideBySideOnlyWithRoomForBoth() {
        // Regular-width windows wide enough for a 300-point list and a readable thread.
        #expect(RemoteLayout.showsSideBySide(width: 744, isRegular: true))  // iPad mini, portrait
        #expect(RemoteLayout.showsSideBySide(width: 834, isRegular: true))  // iPad Pro 11, portrait
        #expect(RemoteLayout.showsSideBySide(width: 803, isRegular: true))  // two thirds of a landscape iPad
        #expect(RemoteLayout.showsSideBySide(width: 1376, isRegular: true))
        // The unfolded iPhone Duo is regular but too narrow for two columns: the thread is pushed instead.
        #expect(!RemoteLayout.showsSideBySide(width: 669, isRegular: true))
        // Compact windows never split, however wide: the folded Duo, iPhones, Split View halves, Slide Over.
        #expect(!RemoteLayout.showsSideBySide(width: 466, isRegular: false))
        #expect(!RemoteLayout.showsSideBySide(width: 440, isRegular: false))
        #expect(!RemoteLayout.showsSideBySide(width: 597, isRegular: false))
        #expect(!RemoteLayout.showsSideBySide(width: 320, isRegular: false))
        #expect(!RemoteLayout.showsSideBySide(width: 932, isRegular: false))  // a Pro Max in landscape
    }

    // MARK: Composer footer

    /// The footer's menus as measured at the default text size: model, effort, access, mode.
    private let menus = [
        RemoteLayout.Chip(full: 86, compact: 44), RemoteLayout.Chip(full: 91, compact: 44),
        RemoteLayout.Chip(full: 132, compact: 44), RemoteLayout.Chip(full: 75, compact: 44),
    ]
    private let steer = RemoteLayout.Chip(full: 91, compact: 44)
    /// Attach (40) and send or stop (44), with the spacing between them.
    private let attachAndSend: CGFloat = 86

    /// Nothing overlaps, everything stays inside the footer, and the trailing controls are on the first line.
    private func expectWellFormed(_ footer: RemoteLayout.Footer, width: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) {
        let frames = footer.chips.map(\.frame) + footer.pinned.map(\.frame) + [footer.fixed]
        for (index, frame) in frames.enumerated() {
            #expect(frame.minX >= 0 && frame.maxX <= width + 0.5, "frame \(index) leaves the footer: \(frame)", sourceLocation: sourceLocation)
            for other in frames[(index + 1)...] {
                #expect(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(other), "\(frame) overlaps \(other)", sourceLocation: sourceLocation)
            }
        }
        #expect(footer.fixed.minY == 0, sourceLocation: sourceLocation)
        #expect(footer.pinned.allSatisfy { $0.line == 0 }, sourceLocation: sourceLocation)
        #expect(footer.size.width == width, sourceLocation: sourceLocation)
    }

    @Test func sendStopAndSteerNeverOverlapTheMenusAtAnyWidth() {
        for width in stride(from: CGFloat(240), through: 900, by: 7) {
            for running in [false, true] {
                let footer = RemoteLayout.footer(
                    width: width, chips: menus, pinned: running ? [steer] : [], fixed: attachAndSend, height: 44)
                expectWellFormed(footer, width: width)
                #expect(footer.pinned.count == (running ? 1 : 0))
                #expect(footer.chips.count == menus.count, "every menu stays reachable at \(width)")
            }
        }
    }

    @Test func aWideComposerShowsEveryLabelOnOneLine() {
        let footer = RemoteLayout.footer(width: 820, chips: menus, pinned: [steer], fixed: attachAndSend, height: 44)
        #expect(footer.chips.allSatisfy { !$0.isCompact && $0.line == 0 })
        #expect(footer.pinned.allSatisfy { !$0.isCompact })
        #expect(footer.size.height == 44)
        // Menus run from the leading edge in order.
        #expect(footer.chips.map(\.frame.minX) == footer.chips.map(\.frame.minX).sorted())
    }

    @Test func narrowerComposersDropLabelsFromTheEndAndSteerFirst() {
        // An iPhone 17 Pro's composer (366 points) while the agent works: steer shows its symbol (send shows it too),
        // the model keeps its name, and the later menus show their symbols.
        let phone = RemoteLayout.footer(width: 366, chips: menus, pinned: [steer], fixed: attachAndSend, height: 44)
        #expect(phone.pinned.allSatisfy { $0.isCompact })
        #expect(phone.chips.map(\.isCompact) == [false, true, true, true])
        #expect(phone.chips.allSatisfy { $0.line == 0 })
        // Idle, the effort's label fits too.
        let idle = RemoteLayout.footer(width: 366, chips: menus, fixed: attachAndSend, height: 44)
        #expect(idle.chips.map(\.isCompact) == [false, false, true, true])
    }

    @Test func menusThatDontFitEvenAsSymbolsContinueOnAnotherLine() {
        // Slide Over (284 points inside the composer) while the agent works: seven 44-point controls can't share a line.
        let slideOver = RemoteLayout.footer(width: 284, chips: menus, pinned: [steer], fixed: attachAndSend, height: 44)
        expectWellFormed(slideOver, width: 284)
        #expect(slideOver.chips.allSatisfy { $0.isCompact })
        #expect(slideOver.chips.map(\.line).max() == 1)
        #expect(slideOver.size.height == 88)
        // Accessibility text sizes make every control taller and wider; lines grow to hold them.
        let large = [RemoteLayout.Chip(full: 190, compact: 70), RemoteLayout.Chip(full: 160, compact: 70),
                     RemoteLayout.Chip(full: 260, compact: 70), RemoteLayout.Chip(full: 150, compact: 70)]
        let footer = RemoteLayout.footer(
            width: 330, chips: large, pinned: [RemoteLayout.Chip(full: 150, compact: 70)], fixed: 150, height: 70)
        expectWellFormed(footer, width: 330)
        #expect(footer.size.height == CGFloat(footer.chips.map(\.line).max()! + 1) * 70)
    }
}
