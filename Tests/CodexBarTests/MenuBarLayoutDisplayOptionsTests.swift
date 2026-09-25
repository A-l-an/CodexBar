import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutDisplayOptionsTests {
    @Test
    func `size and gap pickers show their selection in a narrow row`() {
        let hosting = Self.hostingView(width: 480, size: .small, gap: .tight)
        let popups = Self.popUpButtons(in: hosting)

        #expect(popups.count == 2)
        let titles = popups.map(\.titleOfSelectedItem)
        #expect(titles.contains(MenuBarLayoutSize.small.label))
        #expect(titles.contains(MenuBarLayoutGap.tight.label))
        for popup in popups {
            // A compressed popup collapses to its chevron and hides the selected title.
            #expect(popup.frame.width >= popup.intrinsicContentSize.width - 1)
        }
    }

    @Test
    func `row no longer shows the delete keyboard hint`() {
        let hosting = Self.hostingView(width: 720, size: .regular, gap: .regular)
        let hint = "Delete removes the selected token"

        #expect(!Self.texts(in: hosting).contains { $0.contains(hint) })
        #expect(L("menu_bar_layout_keyboard_hint") != hint)
    }

    @Test
    func `synthetic display options screenshot`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_LAYOUT_OPTIONS_SCREENSHOT_DIR"]
        else { return }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = Self.hostingView(width: 520, size: .small, gap: .tight, appearance: appearance)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = appearance == .aqua ? "light" : "dark"
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("menu-bar-layout-display-options-\(name).png"))
        }
    }

    private static func hostingView(
        width: CGFloat,
        size: MenuBarLayoutSize,
        gap: MenuBarLayoutGap,
        appearance: NSAppearance.Name = .aqua)
        -> NSHostingView<some View>
    {
        let view = MenuBarLayoutDisplayOptions(
            size: .constant(size),
            gap: .constant(gap),
            verticalAdjustment: .constant(0))
            .padding(16)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private static func popUpButtons(in view: NSView) -> [NSPopUpButton] {
        let own = (view as? NSPopUpButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { self.popUpButtons(in: $0) }
    }

    private static func texts(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        let accessibility = [view.accessibilityLabel(), view.accessibilityValue() as? String].compactMap(\.self)
        return own + accessibility + view.subviews.flatMap { self.texts(in: $0) }
    }
}
