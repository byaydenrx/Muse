import AppKit
import SwiftUI

/// One image in one project.
struct LibraryRef: Hashable {
    let projectID: UUID
    let assetID: UUID
}

/// Every image you've saved, across projects: search, filter by tag, see details, place on the current board.
struct LibraryView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject var thumbs: LibraryThumbs
    let canvas: CanvasView

    @FocusState private var searchFocused: Bool

    struct Entry: Identifiable {
        let ref: LibraryRef
        let asset: ImageAsset
        let project: Project
        var id: LibraryRef { ref }
    }

    static func scoped(_ store: Store, _ ui: UIState) -> [Entry] {
        let projects = ui.libraryAllProjects ? store.projects : store.projects.filter { $0.id == store.currentProjectID }
        return projects.flatMap { project in
            project.images.map { Entry(ref: LibraryRef(projectID: project.id, assetID: $0.id), asset: $0, project: project) }
        }
        .sorted { $0.asset.added > $1.asset.added }
    }

    /// What the grid shows, in order: the scope, then the tag filter, then the search words.
    static func results(_ store: Store, _ ui: UIState) -> [Entry] {
        let words = ui.librarySearch.lowercased().split(separator: " ").map(String.init)
        return scoped(store, ui).filter { e in
            if let tag = ui.libraryTag, !e.asset.tags.contains(tag) { return false }
            guard !words.isEmpty else { return true }
            let haystack = ([e.asset.file, e.asset.note, e.project.name, e.asset.sourceURL.flatMap { URL(string: $0)?.host } ?? ""]
                + e.asset.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var scoped: [Entry] { Self.scoped(store, ui) }
    private var results: [Entry] { Self.results(store, ui) }

    var body: some View {
        let results = self.results
        let selected = ui.librarySelection.count == 1 ? results.first { $0.ref == ui.librarySelection[0] } : nil
        return VStack(spacing: 0) {
            header(count: results.count)
            tagRow
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                if results.isEmpty {
                    emptyState
                } else {
                    grid(results)
                }
                if let selected {
                    Divider()
                    details(selected)
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: selected?.ref)
        }
        .background(Color(white: 0.09))
        .onChange(of: ui.librarySearchFocus) { _, _ in searchFocused = true }
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(spacing: 12) {
            Text("Library").font(.system(size: 17, weight: .bold))
            Picker("", selection: $ui.libraryAllProjects) {
                Text("This Project").tag(false)
                Text("All Projects").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text("\(count) images").font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search names, tags, notes, sites", text: $ui.librarySearch)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { ui.librarySearch = ""; searchFocused = false }
                    .frame(minWidth: 60, maxWidth: 220)
                if !ui.librarySearch.isEmpty {
                    Button { ui.librarySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
                Slider(value: $ui.libraryTileSize, in: 110...300)
                    .controlSize(.small)
                    .frame(width: 80)
                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .help("Thumbnail size")
            Button { addImages() } label: { Image(systemName: "plus") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Add images to this project's library without placing them on a board")
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var tagRow: some View {
        let counts = Dictionary(scoped.flatMap(\.asset.tags).map { ($0, 1) }, uniquingKeysWith: +)
        if !counts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", active: ui.libraryTag == nil) { ui.libraryTag = nil }
                    ForEach(counts.keys.sorted { counts[$0]! == counts[$1]! ? $0 < $1 : counts[$0]! > counts[$1]! }, id: \.self) { tag in
                        chip("\(tag)  \(counts[tag]!)", active: ui.libraryTag == tag) {
                            ui.libraryTag = ui.libraryTag == tag ? nil : tag
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 10)
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(Capsule().fill(active ? Color.accentColor : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Grid

    private func grid(_ results: [Entry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: ui.libraryTileSize), spacing: 12)], spacing: 14) {
                    ForEach(results) { tile($0).id($0.ref) }
                }
                .padding(18)
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.size.width, initial: true) { _, width in
                        // Columns in the grid, so ↑ / ↓ can move a whole row.
                        ui.libraryColumns = max(1, Int((width - 36 + 12) / (ui.libraryTileSize + 12)))
                    }
                })
                .contentShape(Rectangle())
                .onTapGesture { ui.librarySelection = [] }
            }
            .onChange(of: ui.librarySelection.last) { _, ref in
                if let ref { withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(ref) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(_ e: Entry) -> some View {
        let selected = ui.librarySelection.contains(e.ref)
        let hovered = ui.libraryHover == e.ref
        let url = store.imageURL(e.asset, in: e.project)
        return VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.white.opacity(hovered ? 0.08 : 0.04)
                if let image = thumbs.image(url) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: thumbs.image(url) != nil)
            .frame(height: ui.libraryTileSize)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(hovered ? 0.16 : 0.06), lineWidth: selected ? 3 : 1))
            Text(e.asset.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)
            if ui.libraryAllProjects {
                Text(e.project.name).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { ui.libraryHover = e.ref } else if ui.libraryHover == e.ref { ui.libraryHover = nil }
        }
        // One gesture for both, so a single click selects right away (Finder-style) instead of waiting out a double-click.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { place([e.ref]) } else { select(e.ref) }
        }
        .onDrag {
            // Out to Finder, Photoshop or any app that takes image files.
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button(ui.librarySelection.count > 1 && selected ? "Place \(ui.librarySelection.count) on Current Board" : "Place on Current Board") {
                place(selected ? ui.librarySelection : [e.ref])
            }
            Button("Quick Look") {
                ui.librarySelection = [e.ref]
                canvas.toggleQuickLook()
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if let source = e.asset.sourceURL, let link = URL(string: source) {
                Button("Open Source Page") { NSWorkspace.shared.open(link) }
            }
            Button("Copy Image") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
        }
        .help(e.asset.tags.isEmpty ? e.asset.file : e.asset.file + " — " + e.asset.tags.joined(separator: ", "))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.stack").font(.system(size: 30, weight: .light))
            Text(scoped.isEmpty ? "No images yet" : "Nothing matches").font(.system(size: 14, weight: .semibold))
            Text(scoped.isEmpty ? "Images you add to boards collect here." : "Try another search or tag.")
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Details

    private func details(_ e: Entry) -> some View {
        let url = store.imageURL(e.asset, in: e.project)
        let boards = store.boards(using: e.asset.id, in: e.project.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image = thumbs.large(url) ?? thumbs.image(url) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture { canvas.toggleQuickLook() }
                        .help("Quick Look (Space)")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.asset.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    if e.asset.displayName != (e.asset.file as NSString).deletingPathExtension {
                        Text(e.asset.file).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Text("\(e.asset.pixelWidth) × \(e.asset.pixelHeight) · \(e.project.name)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Added \(e.asset.added.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    if let source = e.asset.sourceURL, let link = URL(string: source) {
                        Button(link.host ?? source) { NSWorkspace.shared.open(link) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                }
                HStack {
                    Button("Place on Board") { place([e.ref]) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.glass)
                }
                .controlSize(.regular)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        ForEach(e.asset.tags, id: \.self) { tag in
                            HStack(spacing: 3) {
                                Text(tag).font(.system(size: 11, weight: .medium))
                                Button {
                                    store.updateAsset(e.asset.id, inProject: e.project.id) { $0.tags.removeAll { $0 == tag } }
                                } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                        }
                    }
                    TextField("Add a tag and press Return", text: $ui.tagDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            let tag = ui.tagDraft.trimmingCharacters(in: .whitespaces).lowercased()
                            guard !tag.isEmpty else { return }
                            store.updateAsset(e.asset.id, inProject: e.project.id) { if !$0.tags.contains(tag) { $0.tags.append(tag) } }
                            ui.tagDraft = ""
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Note").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { store.projects.first { $0.id == e.project.id }?.asset(e.asset.id)?.note ?? "" },
                        set: { text in store.updateAsset(e.asset.id, inProject: e.project.id) { $0.note = text } }
                    ))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 90)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Used on").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if boards.isEmpty {
                        Text("Not on any board").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    ForEach(boards) { board in
                        Button {
                            store.select(project: e.project.id, board: board.id)
                            ui.showingLibrary = false
                        } label: {
                            Label("\(e.project.name) › \(board.name)", systemImage: "rectangle.on.rectangle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .padding(.top, 4)
        }
        .background(Color(white: 0.115))
    }

    // MARK: Actions

    private func select(_ ref: LibraryRef) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            if let i = ui.librarySelection.firstIndex(of: ref) { ui.librarySelection.remove(at: i) } else { ui.librarySelection.append(ref) }
        } else {
            ui.librarySelection = [ref]
        }
    }

    /// Back to the board with these images placed in the middle of the view (copied in if they're from another project).
    func place(_ refs: [LibraryRef]) {
        let assets = refs.compactMap { store.assetInCurrentProject($0.assetID, from: $0.projectID) }
        guard !assets.isEmpty else { return }
        ui.showingLibrary = false
        DispatchQueue.main.async { canvas.placeAssets(assets) }
    }

    /// Keys while the Library is up (the board view keeps keyboard focus and hands them here).
    /// Arrows move the selection, Return places, Space is Quick Look, Esc goes back to the board.
    @MainActor static func handleKey(_ event: NSEvent, store: Store, ui: UIState, canvas: CanvasView) -> Bool {
        let entries = results(store, ui)
        let refs = entries.map(\.ref)
        let current = ui.librarySelection.last.flatMap { refs.firstIndex(of: $0) }
        func move(_ by: Int) {
            guard !refs.isEmpty else { return }
            let next = current.map { min(max($0 + by, 0), refs.count - 1) } ?? 0
            if event.modifierFlags.contains(.shift) {
                if !ui.librarySelection.contains(refs[next]) { ui.librarySelection.append(refs[next]) }
            } else {
                ui.librarySelection = [refs[next]]
            }
            canvas.refreshQuickLook()
        }
        switch event.keyCode {
        case 123: move(-1)
        case 124: move(1)
        case 125: move(ui.libraryColumns)
        case 126: move(-ui.libraryColumns)
        case 49: canvas.toggleQuickLook()
        case 36, 76:
            let assets = ui.librarySelection.compactMap { store.assetInCurrentProject($0.assetID, from: $0.projectID) }
            guard !assets.isEmpty else { return true }
            ui.showingLibrary = false
            DispatchQueue.main.async { canvas.placeAssets(assets) }
        case 53:
            if !ui.librarySelection.isEmpty { ui.librarySelection = [] } else { ui.showingLibrary = false }
        default:
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                // Start typing to search.
                ui.librarySearch += chars
                ui.librarySearchFocus += 1
                return true
            }
            return false
        }
        return true
    }

    private func addImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .folder]
        guard panel.runModal() == .OK else { return }
        let files = panel.urls.flatMap(Importer.expandFolder)
        let added = files.compactMap { store.addImage(copying: $0, sourceURL: nil) }
        ui.libraryAllProjects = false
        ui.show(added.count == 1 ? "Added 1 image to the library" : "Added \(added.count) images to the library")
    }
}

/// Library thumbnails, decoded in the background; the grid redraws as they arrive.
@MainActor
final class LibraryThumbs: ObservableObject {
    static let shared = LibraryThumbs()
    @Published private var small: [URL: NSImage] = [:]
    @Published private var big: [URL: NSImage] = [:]
    private var loading: Set<URL> = []

    func image(_ url: URL) -> NSImage? { load(url, size: 420, large: false) }
    func large(_ url: URL) -> NSImage? { load(url, size: 900, large: true) }

    private func load(_ url: URL, size: Int, large: Bool) -> NSImage? {
        if let hit = (large ? big : small)[url] { return hit }
        let token = url.appendingPathExtension("\(size)")
        guard !loading.contains(token) else { return nil }
        loading.insert(token)
        DispatchQueue.global(qos: .userInitiated).async {
            let cg = ImageCache.decode(url, maxPixels: size)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading.remove(token)
                    guard let cg else { return }
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    if large { self.big[url] = image } else { self.small[url] = image }
                }
            }
        }
        return nil
    }
}
