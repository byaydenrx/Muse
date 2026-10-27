import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject var palettes: PaletteLibrary
    @ObservedObject var modes: WindowModes
    let canvas: CanvasView

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { ui.sidebarVisible ? .all : .detailOnly },
            set: { ui.sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView(store: store, ui: ui, canvas: canvas)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            board
                .inspector(isPresented: Binding(
                    get: { ui.rightPanel != .none },
                    set: { if !$0 { ui.rightPanel = .none } }
                )) {
                    rightPanel
                        .inspectorColumnWidth(min: 260, ideal: 280, max: 400)
                }
        }
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.18), value: ui.toolbarVisible)
        .animation(.snappy(duration: 0.2), value: ui.toast)
        .animation(.snappy(duration: 0.22), value: ui.showingLibrary)
    }

    private var board: some View {
        ZStack(alignment: .top) {
            CanvasHost(canvas: canvas)
            if store.currentBoard?.items.isEmpty == true && store.currentBoard?.sections.isEmpty == true {
                emptyHint
            }
            if ui.showingLibrary {
                LibraryView(store: store, ui: ui, thumbs: LibraryThumbs.shared, canvas: canvas)
                    .transition(.opacity)
            }
            if ui.toolbarVisible && !ui.showingLibrary {
                HoverToolbar(ui: ui, canvas: canvas)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack {
                Spacer()
                PinMenu(modes: modes)
            }
            .padding(10)
            if ui.tool != .move && !ui.showingLibrary {
                VStack {
                    Spacer()
                    HStack {
                        Label("\(ui.tool.name)  \(ui.tool.key)", systemImage: ui.tool.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: Capsule())
                        Spacer()
                    }
                }
                .padding(12)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if let toast = ui.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, 18)
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(white: 0.09))
        // Never wider than the window gives it: a big minimum here would make the split view grow the window.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        // Under the title bar, but not under the sidebar or inspector.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy(duration: 0.15), value: ui.tool)
    }

    @ViewBuilder private var rightPanel: some View {
        switch ui.rightPanel {
        case .inspector: InspectorView(store: store, ui: ui)
        case .palettes: PaletteDrawer(store: store, palettes: palettes, canvas: canvas)
        case .layers, .none: LayersPanel(store: store, ui: ui, palettes: palettes, canvas: canvas)
        }
    }
}

private extension RootView {
    var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
            Text("Drop images here")
                .font(.system(size: 16, weight: .semibold))
            Text("Drag from Finder, Pinterest or any browser · ⌘V to paste · ⌥⇧4 to screenshot\n"
                 + (PaletteLibrary.pigmentInstalled ? "Palettes: drag from Pigment or open the palette drawer (⇧⌘P) · " : "") + "Shortcuts: ⌘/")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct CanvasHost: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

// MARK: - Shared bits

/// A round icon button face, used where buttons float over the board or sit in panel headers.
struct CircleIcon: View {
    let symbol: String
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(active ? Color.accentColor : Color.white.opacity(0.0001)))
            .contentShape(Circle())
    }
}

/// Panel title row, the same in every inspector panel.
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            trailing
        }
        .frame(height: 28)
    }
}

private struct PaletteStrip: View {
    let colors: [PigmentPalette.Color]
    var height: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.prefix(14).enumerated()), id: \.offset) { _, c in
                Rectangle().fill(Color(nsColor: c.nsColor))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Toolbar and pin

struct HoverToolbar: View {
    @ObservedObject var ui: UIState
    let canvas: CanvasView

    var body: some View {
        HStack(spacing: 2) {
            button("sidebar.left", "Projects (⌃⌘S)", active: ui.sidebarVisible) { ui.sidebarVisible.toggle() }
            separator
            ForEach(Tool.available) { tool in
                button(tool.symbol, "\(tool.name) (\(tool.key))", active: ui.tool == tool) { ui.tool = tool }
            }
            separator
            button("photo.badge.plus", "Add images… (⌘O)") { canvas.chooseImages(at: canvas.centerWorld) }
            separator
            button("square.3.layers.3d", "Layers (F7)", active: ui.rightPanel == .layers) { ui.toggle(.layers) }
            if PaletteLibrary.pigmentInstalled {
                button("swatchpalette", "Palettes (⇧⌘P)", active: ui.rightPanel == .palettes) { ui.toggle(.palettes) }
            }
            button("info.circle", "Image info (⌘I)", active: ui.rightPanel == .inspector) { ui.toggle(.inspector) }
            button("arrow.up.left.and.arrow.down.right", "Fit on screen (⌘0)") { canvas.fitAll() }
            button("square.and.arrow.up", "Export as PSD (⇧⌘E)") { NSApp.sendAction(#selector(AppDelegate.exportPSD), to: nil, from: nil) }
        }
        .padding(5)
        .glassEffect(.regular, in: Capsule())
        .onHover { if $0 { ui.toolbarVisible = true } }
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }

    private func button(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { CircleIcon(symbol: symbol, active: active) }
            .buttonStyle(.plain)
            .help(help)
    }
}

struct PinMenu: View {
    @ObservedObject var modes: WindowModes

    var body: some View {
        Menu {
            SwiftUI.Section("Presets") {
                ForEach(WindowModes.Preset.allCases) { preset in
                    Toggle(isOn: Binding(get: { modes.activePreset == preset }, set: { _ in modes.apply(preset) })) {
                        Text(preset.rawValue)
                        Text(preset.detail)
                    }
                }
            }
            Divider()
            Toggle("Always on Top", isOn: $modes.onTop)
            Toggle("Click-Through (⌥⇧T)", isOn: $modes.clickThrough)
            Picker("Opacity", selection: $modes.opacity) {
                ForEach([100, 85, 70, 55, 40, 25], id: \.self) { value in
                    Text("\(value)%").tag(Double(value) / 100)
                }
            }
        } label: {
            Image(systemName: modes.onTop ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(modes.onTop ? .regular.tint(.accentColor) : .regular, in: Circle())
        .help("Window: pin on top, see-through, click-through")
    }
}

// MARK: - Sidebar

enum SidebarItem: Hashable {
    case library
    case project(UUID)
    case board(UUID, UUID)
}

struct SidebarView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    let canvas: CanvasView
    @FocusState private var renameFocused: Bool

    private var selection: Binding<SidebarItem?> {
        Binding(get: {
            if ui.showingLibrary { return .library }
            guard let project = store.currentProjectID else { return nil }
            if let board = store.currentBoardID { return .board(project, board) }
            return .project(project)
        }, set: { item in
            switch item {
            case .library:
                ui.showingLibrary = true
            case .project(let id):
                store.select(project: id)
                ui.expandedProjects.insert(id)
                ui.showingLibrary = false
            case .board(let project, let board):
                store.select(project: project, board: board)
                ui.showingLibrary = false
            case nil:
                return
            }
            // Keys go back to the board (tool shortcuts) after picking something here.
            DispatchQueue.main.async { canvas.window?.makeFirstResponder(canvas) }
        })
    }

    var body: some View {
        List(selection: selection) {
            Label("Library", systemImage: "photo.stack")
                .badge(store.projects.reduce(0) { $0 + $1.images.count })
                .tag(SidebarItem.library)

            SwiftUI.Section {
                ForEach(store.projects) { project in
                    DisclosureGroup(isExpanded: Binding(
                        get: { ui.expandedProjects.contains(project.id) || project.id == store.currentProjectID },
                        set: { open in
                            if open { ui.expandedProjects.insert(project.id) } else { ui.expandedProjects.remove(project.id) }
                        }
                    )) {
                        ForEach(project.boards) { board in
                            boardRow(board, in: project)
                                .tag(SidebarItem.board(project.id, board.id))
                        }
                    } label: {
                        projectRow(project)
                            .tag(SidebarItem.project(project.id))
                    }
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button(action: newProject) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New Project (⇧⌘N)")
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: ui.renamingProjectID) { _, id in renameFocused = id != nil || ui.renamingBoardID != nil }
        .onChange(of: ui.renamingBoardID) { _, id in renameFocused = id != nil || ui.renamingProjectID != nil }
        .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
    }

    private func newProject() {
        let project = store.createProject(named: "New Project")
        store.select(project: project.id)
        ui.showingLibrary = false
        ui.renameText = project.name
        ui.renamingProjectID = project.id
    }

    private func commitRename() {
        if let id = ui.renamingProjectID { store.renameProject(id, to: ui.renameText) }
        if let id = ui.renamingBoardID, let project = store.projects.first(where: { $0.boards.contains { $0.id == id } }) {
            store.renameBoard(id, in: project.id, to: ui.renameText)
        }
        ui.renamingProjectID = nil
        ui.renamingBoardID = nil
    }

    private func renameField() -> some View {
        TextField("Name", text: $ui.renameText)
            .textFieldStyle(.plain)
            .focused($renameFocused)
            .onSubmit { commitRename() }
            .onExitCommand {
                ui.renamingProjectID = nil
                ui.renamingBoardID = nil
            }
    }

    private func projectRow(_ project: Project) -> some View {
        Label {
            if ui.renamingProjectID == project.id { renameField() } else { Text(project.name) }
        } icon: {
            Image(systemName: "folder")
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            ui.renameText = project.name
            ui.renamingProjectID = project.id
        })
        .contextMenu {
            Button("Rename") {
                ui.renameText = project.name
                ui.renamingProjectID = project.id
            }
            Button("New Board") {
                if let board = store.addBoard(to: project.id) {
                    store.select(project: project.id, board: board.id)
                    ui.showingLibrary = false
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folderURL(project)]) }
            Divider()
            Button("Move to Trash", role: .destructive) { store.deleteProject(project.id) }
        }
    }

    private func boardRow(_ board: Board, in project: Project) -> some View {
        Label {
            if ui.renamingBoardID == board.id { renameField() } else { Text(board.name) }
        } icon: {
            Image(systemName: "rectangle.on.rectangle")
        }
        .badge(board.items.count)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            ui.renameText = board.name
            ui.renamingBoardID = board.id
        })
        .contextMenu {
            Button("Rename") {
                ui.renameText = board.name
                ui.renamingBoardID = board.id
            }
            Button("New Board") {
                if let new = store.addBoard(to: project.id) { store.select(project: project.id, board: new.id) }
            }
            if project.boards.count > 1 {
                Divider()
                Button("Delete Board", role: .destructive) { store.deleteBoard(board.id, in: project.id) }
            }
        }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: "Image Info") { EmptyView() }
                .padding(.top, 8)
            if let project = store.currentProject, let id = ui.selectedAssetID, let asset = project.asset(id) {
                details(asset, project: project)
            } else {
                Text("Select one image on the board to see its info, tags and note.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func details(_ asset: ImageAsset, project: Project) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let image = NSImage(contentsOf: store.imageURL(asset, in: project)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.file).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text("\(asset.pixelWidth) × \(asset.pixelHeight)").font(.system(size: 11)).foregroundStyle(.secondary)
                if let source = asset.sourceURL, let url = URL(string: source) {
                    Button(url.host ?? source) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                FlowTags(tags: asset.tags) { tag in
                    store.updateAsset(asset.id) { $0.tags.removeAll { $0 == tag } }
                }
                TextField("Add a tag and press Return", text: $ui.tagDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit {
                        let tag = ui.tagDraft.trimmingCharacters(in: .whitespaces).lowercased()
                        guard !tag.isEmpty else { return }
                        store.updateAsset(asset.id) { if !$0.tags.contains(tag) { $0.tags.append(tag) } }
                        ui.tagDraft = ""
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Note").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { store.currentProject?.asset(asset.id)?.note ?? "" },
                    set: { text in store.updateAsset(asset.id) { $0.note = text } }
                ))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
            }
        }
    }
}

/// Tag chips that wrap onto new lines; clicking the × removes one.
private struct FlowTags: View {
    let tags: [String]
    let remove: (String) -> Void

    var body: some View {
        let rows = layout()
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag).font(.system(size: 11, weight: .medium))
                            Button { remove(tag) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    }
                }
            }
        }
    }

    /// Rough wrapping by character count; the panel has a fixed width.
    private func layout() -> [[String]] {
        var rows: [[String]] = [[]]
        var width = 0
        for tag in tags {
            let w = tag.count * 7 + 34
            if width + w > 228, !rows[rows.count - 1].isEmpty { rows.append([]); width = 0 }
            rows[rows.count - 1].append(tag)
            width += w
        }
        return rows.filter { !$0.isEmpty }
    }
}

// MARK: - Palette drawer

struct PaletteDrawer: View {
    @ObservedObject var store: Store
    @ObservedObject var palettes: PaletteLibrary
    let canvas: CanvasView

    var body: some View {
        let projectID = store.currentProjectID
        let mine = palettes.palettes.filter { $0.projectID == projectID && $0.projectID != nil }
        let others = palettes.palettes.filter { !($0.projectID == projectID && $0.projectID != nil) }
        return VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Palettes") {
                Button { canvas.newPalette(at: canvas.centerWorld) } label: { Image(systemName: "eyedropper") }
                    .buttonStyle(.borderless)
                    .help("New project palette from a color anywhere on screen (on the board, use the I tool)")
            }
            .padding(.top, 8)
            Text("Drag onto the board, or click to add.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    header("This project")
                    if mine.isEmpty {
                        Text("None yet: use the eyedropper (I) on an image, or right-click an image → Make Palette.")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 6)
                    }
                    ForEach(mine) { row($0) }
                    header("All palettes")
                    ForEach(others) { row($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private func row(_ palette: PigmentPalette) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(palette.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if let project = palette.project, palette.projectID != store.currentProjectID {
                    Text(project).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            PaletteStrip(colors: palette.colors)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture { canvas.addPalettes([palette.id], at: canvas.centerWorld) }
        .onDrag { NSItemProvider(object: (PaletteLibrary.dragPrefix + palette.id.uuidString) as NSString) }
    }
}
