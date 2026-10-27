import AppKit
import SwiftUI

/// Help › Keyboard Shortcuts: a small reference window, grouped like Photoshop's.
struct ShortcutsView: View {
    private static let groups: [(String, [(String, String)])] = [
        ("Tools", [
            ("V", "Move"), ("H  or hold Space", "Hand"), ("Z", "Zoom — click in, ⌥-click out, drag to scrub"),
            ("M", "Section — drag a named area (a group in PSD)"), ("T", "Type — ⌘↩ keeps, Esc cancels"),
            ("I", "Eyedropper — click an image to add a color (needs Pigment)"), ("Esc", "Back to Move"),
        ]),
        ("Editing", [
            ("⌘J", "Duplicate"), ("⌘D", "Deselect"), ("⌘A", "Select all"), ("⌫", "Remove"),
            ("⌘G", "Group into section"), ("⇧⌘G", "Remove section"),
            ("⌘]  ⌘[", "Forward / backward"), ("⇧⌘]  ⇧⌘[", "To front / back"),
            ("Arrows", "Nudge 1 (⇧ for 10)"), ("⌘Z  ⇧⌘Z", "Undo / redo"),
        ]),
        ("View", [
            ("⌘0", "Fit on screen"), ("⌘1", "100%"), ("⌘+  ⌘−", "Zoom"), ("⌥ scroll, pinch", "Zoom"),
            ("Tab", "Hide panels"), ("F", "Full screen"), ("F7", "Layers"), ("⌘I", "Image info"), ("⇧⌘P", "Palettes (needs Pigment)"),
            ("⌃⌘S", "Projects sidebar"),
        ]),
        ("Library", [
            ("⌘L", "Show / hide"), ("⌘F  or start typing", "Search"), ("Arrows", "Move selection"),
            ("Space", "Quick Look"), ("Return  or double-click", "Place on the board"), ("Esc", "Back to the board"),
        ]),
        ("Window", [
            ("⌃⌘1 – 4", "Normal / Float / Peek / Trace"), ("⌥⇧T", "Trace on / off (anywhere)"),
            ("⌥⇧4", "Screenshot to board (anywhere)"), ("⇧⌘E", "Export board as PSD"),
        ]),
    ]

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                column(Array(Self.groups.prefix(2)))
                column(Array(Self.groups.suffix(3)))
            }
            .padding(24)
        }
        .frame(width: 640, height: 520)
    }

    private func column(_ groups: [(String, [(String, String)])]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(groups, id: \.0) { title, rows in
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(rows, id: \.0) { keys, action in
                            GridRow {
                                Text(keys)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .frame(minWidth: 70, alignment: .leading)
                                Text(action).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor static var window: NSWindow?

    @MainActor static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Keyboard Shortcuts"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ShortcutsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
