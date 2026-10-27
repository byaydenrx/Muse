import AppKit
import SwiftUI

/// Photoshop-style layers: frontmost on top, sections as groups. Drag to reorder, double-click to rename,
/// the eye shows and hides.
struct LayersPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject var palettes: PaletteLibrary
    let canvas: CanvasView

    var body: some View {
        let board = store.currentBoard ?? Board(id: UUID(), name: "")
        let tree = LayerTree(board)
        let loose = Array(tree.loose.reversed())
        let groups = Array(tree.groups.reversed())
        return VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Layers") {
                Text("\(board.items.count + board.sections.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .padding(.horizontal, 14)

            List {
                ForEach(loose) { item in layerRow(item, indent: 0) }
                    .onMove { from, to in
                        var ids = loose.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        store.reorderLayers(topFirst: ids)
                    }
                ForEach(groups, id: \.section.id) { group in
                    sectionRow(group.section, count: group.items.count)
                    if !ui.collapsedSections.contains(group.section.id) {
                        let children = Array(group.items.reversed())
                        ForEach(children) { item in layerRow(item, indent: 1) }
                            .onMove { from, to in
                                var ids = children.map(\.id)
                                ids.move(fromOffsets: from, toOffset: to)
                                store.reorderLayers(topFirst: ids)
                            }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 34)

            Text("Drag to reorder · double-click to rename")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Rows

    private func layerRow(_ item: BoardItem, indent: Int) -> some View {
        let selected = ui.selectedIDs.contains(item.id)
        let name = item.layerName(project: store.currentProject, palettes: palettes)
        return HStack(spacing: 8) {
            eye(item.hidden == true) { store.toggleHidden(item.id) }
            thumbnail(item)
                .padding(.leading, CGFloat(indent) * 16)
            if ui.renamingLayerID == item.id {
                renameField(item.id)
            } else {
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(item.hidden == true ? .secondary : .primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.28) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(item.id, name) }
        .onTapGesture { select(item.id) }
        .contextMenu {
            Button("Rename…") { startRename(item.id, name) }
            Button(item.hidden == true ? "Show" : "Hide") { store.toggleHidden(item.id) }
            Divider()
            Button("Bring Forward") { canvas.select([item.id]); canvas.arrangeStep(true) }
            Button("Send Backward") { canvas.select([item.id]); canvas.arrangeStep(false) }
            Divider()
            Button("Remove from Board", role: .destructive) { canvas.select([item.id]); canvas.removeSelection() }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }

    private func sectionRow(_ section: Section, count: Int) -> some View {
        let selected = ui.selectedIDs.contains(section.id)
        let collapsed = ui.collapsedSections.contains(section.id)
        let color = Color(nsColor: SectionColors.all[section.colorIndex % SectionColors.all.count])
        return HStack(spacing: 8) {
            eye(section.hidden == true) { store.toggleHidden(section.id) }
            Button {
                if collapsed { ui.collapsedSections.remove(section.id) } else { ui.collapsedSections.insert(section.id) }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: "folder.fill").foregroundStyle(color)
            if ui.renamingLayerID == section.id {
                renameField(section.id)
            } else {
                Text(section.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(section.hidden == true ? .secondary : .primary)
            }
            Spacer(minLength: 0)
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(section.id, section.name) }
        .onTapGesture { select(section.id) }
        .contextMenu {
            Button("Rename…") { startRename(section.id, section.name) }
            Button(section.hidden == true ? "Show Group" : "Hide Group") { store.toggleHidden(section.id) }
            Divider()
            Button("Move Group Up") { store.moveSection(section.id, up: true) }
            Button("Move Group Down") { store.moveSection(section.id, up: false) }
            Divider()
            Button("Remove Section (keeps its layers)") { canvas.select([section.id]); canvas.ungroupSections() }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 1, trailing: 6))
    }

    private func eye(_ hidden: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .font(.system(size: 11))
                .foregroundStyle(hidden ? .tertiary : .secondary)
                .frame(width: 18)
        }
        .buttonStyle(.plain)
        .help(hidden ? "Show" : "Hide")
    }

    @ViewBuilder private func thumbnail(_ item: BoardItem) -> some View {
        Group {
            switch item.kind {
            case .image(let id):
                if let project = store.currentProject, let asset = project.asset(id),
                   let image = LayerThumbs.image(store.imageURL(asset, in: project)) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
                }
            case .text: Image(systemName: "textformat").font(.system(size: 12, weight: .semibold))
            case .note: Image(systemName: "note.text")
            case .palette(let id):
                HStack(spacing: 0) {
                    ForEach(Array((palettes.palette(id)?.colors ?? []).prefix(5).enumerated()), id: \.offset) { _, c in
                        Rectangle().fill(Color(nsColor: c.nsColor))
                    }
                }
            }
        }
        .frame(width: 28, height: 28)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .foregroundStyle(.secondary)
    }

    private func renameField(_ id: UUID) -> some View {
        TextField("Name", text: $ui.renameText)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .onSubmit {
                store.renameLayer(id, to: ui.renameText)
                ui.renamingLayerID = nil
            }
            .onExitCommand { ui.renamingLayerID = nil }
    }

    private func startRename(_ id: UUID, _ name: String) {
        ui.renameText = name
        ui.renamingLayerID = id
    }

    private func select(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            var ids = ui.selectedIDs
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            canvas.select(ids)
        } else {
            canvas.select([id])
        }
    }
}

/// Small layer thumbnails, decoded once.
@MainActor
enum LayerThumbs {
    private static var cache: [URL: NSImage] = [:]

    static func image(_ url: URL) -> NSImage? {
        if let hit = cache[url] { return hit }
        guard let cg = ImageCache.decode(url, maxPixels: 64) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url] = image
        return image
    }
}
