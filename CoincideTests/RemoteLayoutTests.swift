import CoreGraphics
import Testing

/// Coincide Remote's layout rules (`CoincideRemote/UI/RemoteLayout.swift`, compiled into this suite): when the list
/// and a thread sit side by side, where the composer's controls go at every width, and how large a message's pictures are.
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

    /// A model with effort and speed at the default text size: model, effort, speed, access and mode, each 44 points
    /// as its symbol.
    private let fullMenus = [
        RemoteLayout.Chip(full: 120, compact: 44), RemoteLayout.Chip(full: 96, compact: 44), RemoteLayout.Chip(full: 98, compact: 44),
        RemoteLayout.Chip(full: 118, compact: 44), RemoteLayout.Chip(full: 72, compact: 44),
    ]
    /// Attach (40), dictation (40) and send or stop (44), flush.
    private let attachDictateAndSend: CGFloat = 124
    /// The footer of an iPhone's composer, by screen width: 10 points of margin and 8 of the composer's padding on
    /// each side, less the 4 the footer reaches into it (`ComposerFooterLayout.bleed`).
    private let phoneFooters: [(screen: CGFloat, footer: CGFloat)] = [375, 390, 393, 402, 420, 430, 440].map { ($0, $0 - 28) }

    @Test func everyControlFitsOnOneLineOnEveryPhone() {
        for (screen, width) in phoneFooters {
            let idle = RemoteLayout.footer(
                width: width, chips: fullMenus, fixed: attachDictateAndSend, height: 44, spacing: 0, inset: 4)
            expectWellFormed(idle, width: width)
            #expect(idle.chips.allSatisfy { $0.line == 0 }, "\(screen)-point phone, idle")
            #expect(idle.size.height == 44)
            // While the agent works, steer or queue joins them. Narrower phones choose the speed in the model's menu
            // (`ComposerControls.foldsSpeed`), one menu fewer; an iPhone Air and wider keep it.
            let unfolded = RemoteLayout.footerMinimumWidth(chips: fullMenus, pinned: [steer], fixed: attachDictateAndSend, spacing: 0)
            let menus = unfolded <= width ? fullMenus : fullMenus.enumerated().filter { $0.offset != 2 }.map(\.element)
            #expect((unfolded <= width) == (screen >= 420), "\(screen)-point phone folds the speed only when it must")
            let running = RemoteLayout.footer(
                width: width, chips: menus, pinned: [steer], fixed: attachDictateAndSend, height: 44, spacing: 0, inset: 4)
            expectWellFormed(running, width: width)
            #expect(running.chips.allSatisfy { $0.line == 0 }, "\(screen)-point phone while the agent works")
            #expect(running.pinned.allSatisfy { $0.isCompact })
        }
    }

    @Test func theFirstMenuLinesUpWithTheMessageUntilItNeedsTheRoom() {
        // A 393-point phone has room to spare: the model's menu starts 4 points in, under the message's text.
        let roomy = RemoteLayout.footer(width: 365, chips: fullMenus, fixed: attachDictateAndSend, height: 44, spacing: 0, inset: 4)
        #expect(roomy.chips.first?.frame.minX == 4)
        // A 375-point phone needs those 4 points for its last menu.
        let tight = RemoteLayout.footer(width: 347, chips: fullMenus, fixed: attachDictateAndSend, height: 44, spacing: 0, inset: 4)
        #expect(tight.chips.first?.frame.minX == 0)
        #expect(tight.chips.allSatisfy { $0.isCompact && $0.line == 0 })
        // The trailing controls end at the footer's edge either way.
        #expect(roomy.fixed.maxX == 365 && tight.fixed.maxX == 347)
    }

    @Test func theFooterTakesOneLineExactlyWhenItsMinimumWidthFits() {
        for width in stride(from: CGFloat(240), through: 520, by: 3) {
            for pinned in [[], [steer]] {
                let minimum = RemoteLayout.footerMinimumWidth(chips: fullMenus, pinned: pinned, fixed: attachDictateAndSend, spacing: 0)
                let footer = RemoteLayout.footer(
                    width: width, chips: fullMenus, pinned: pinned, fixed: attachDictateAndSend, height: 44, spacing: 0, inset: 4)
                expectWellFormed(footer, width: width)
                #expect((footer.size.height == 44) == (width >= minimum), "at \(width) with a minimum of \(minimum)")
                #expect(footer.chips.count == fullMenus.count)
            }
        }
    }

    // MARK: Pictures

    /// The room a picture has: inside the user's bubble on an iPhone (282), a folded Duo (358), an unfolded Duo (561),
    /// and a reply's column beside the list on an iPad (480) or alone on a landscape iPad (790).
    private let pictureRooms: [CGFloat] = [282, 358, 561, 480, 790]

    @Test func aLonePictureKeepsItsShapeWithinItsMessageAndTheHeightCap() {
        // A Mac screenshot (2940 × 1912), a phone screenshot (1179 × 2556), a square, and one still loading.
        for aspect: CGFloat? in [2940.0 / 1912, 1179.0 / 2556, 1, nil] {
            for width in pictureRooms {
                let grid = RemoteLayout.pictureGrid(aspects: [aspect], width: width)
                let frame = grid.frames[0]
                #expect(frame.width <= width, "\(String(describing: aspect)) is wider than its message at \(width)")
                #expect(frame.height <= RemoteLayout.pictureMaximumHeight)
                #expect(frame.width > 0 && frame.height > 0)
                #expect(grid.size == frame.size)
                // Its shape, within a point of rounding, cropped only past the limits.
                let shape = min(max(aspect ?? 4 / 3, RemoteLayout.pictureAspects.lowerBound), RemoteLayout.pictureAspects.upperBound)
                #expect(abs(frame.width - frame.height * shape) <= 1, "\(String(describing: aspect)) at \(width): \(frame)")
            }
        }
        // The Mac screenshot fills an iPhone bubble's width, a third of the screen tall, not the whole screen.
        let phone = RemoteLayout.pictureGrid(aspects: [2940.0 / 1912], width: 282).size
        #expect(phone.width == 282)
        #expect(phone.height == 183)
        // On an iPad it stops at the height cap rather than growing across the column.
        #expect(RemoteLayout.pictureGrid(aspects: [2940.0 / 1912], width: 790).size.height == RemoteLayout.pictureMaximumHeight)
        // A long phone screenshot is cropped to a readable shape instead of a sliver.
        #expect(RemoteLayout.pictureGrid(aspects: [1179.0 / 2556], width: 282).size == CGSize(width: 120, height: 240))
    }

    @Test func severalPicturesSitTwoToARowInTilesThatFitTheirMessage() {
        for count in 2...5 {
            for width in pictureRooms + [120] {
                let grid = RemoteLayout.pictureGrid(aspects: Array(repeating: 1.5, count: count), width: width)
                #expect(grid.frames.count == count)
                #expect(grid.size.width <= width, "\(count) pictures are wider than their message at \(width)")
                for (index, frame) in grid.frames.enumerated() {
                    #expect(frame.width <= RemoteLayout.pictureTileMaximumWidth)
                    #expect(frame.height == (frame.width * 0.75).rounded())
                    #expect(frame.maxX <= grid.size.width && frame.maxY <= grid.size.height)
                    #expect(frame.minX == (index % 2 == 0 ? 0 : frame.width + RemoteLayout.pictureSpacing))
                    for other in grid.frames[(index + 1)...] { #expect(!frame.intersects(other)) }
                }
            }
        }
        #expect(RemoteLayout.pictureGrid(aspects: [1, 1, 1], width: 282).size == CGSize(width: 282, height: 103 * 2 + 8))
        #expect(RemoteLayout.pictureGrid(aspects: [1, 1], width: 790).size == CGSize(width: 328, height: 120))
    }

    @Test func noRoomLaysOutNothing() {
        #expect(RemoteLayout.pictureGrid(aspects: [1.5], width: 0).size == .zero)
        #expect(RemoteLayout.pictureGrid(aspects: [], width: 300).frames.isEmpty)
    }

    // MARK: Search

    /// The search button filters the open tab as the Mac sidebar's search does: every word, any order, any case and
    /// accent; empty matches everything.
    @Test func searchMatchesEveryWordInAnyOrderCaseAndAccent() {
        #expect(SearchMatch("").isEmpty)
        #expect(SearchMatch("  ").isEmpty)
        #expect(SearchMatch("push").matches("Run git push for the remote branch"))
        #expect(SearchMatch("REMOTE push").matches("Run git push for the remote branch"))
        #expect(!SearchMatch("push pull").matches("Run git push for the remote branch"))
        #expect(SearchMatch("brulee").matches("Brûlée"))
        // A word may match any of the texts given: a project's name or its thread's title.
        #expect(SearchMatch("coincide push").matches("coincide", "Run git push"))
        #expect(!SearchMatch("fud push").matches("coincide", "Run git push"))
    }
}
