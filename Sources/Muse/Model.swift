import AppKit
import ImageIO

struct ImageAsset: Codable, Identifiable, Hashable {
    var id: UUID
    /// File name inside the project's images folder.
    var file: String
    var pixelWidth: Int
    var pixelHeight: Int
    /// The page or image address it was dragged from, if it came from the web.
    var sourceURL: String?
    var tags: [String] = []
    var note: String = ""
    var added: Date

    /// The file name, unless it's a web hash like "28cbf9b6ede65e43…": then where it came from.
    var displayName: String {
        let stem = (file as NSString).deletingPathExtension
        let core = stem.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)
        let looksHashed = core.count >= 16 && core.allSatisfy { $0.isHexDigit || $0 == "-" || $0 == "_" }
        guard looksHashed else { return stem }
        let host = sourceURL.flatMap { URL(string: $0)?.host }?.replacingOccurrences(of: "www.", with: "")
        if let host, host.contains("pinterest") || host.contains("pinimg") { return "Pinterest image" }
        if let host { return "Image from \(host)" }
        return "Image"
    }
}

enum ItemKind: Codable, Hashable {
    case image(UUID)
    /// A Pigment palette, by its id in ~/Palettes/library.json.
    case palette(UUID)
    case note(String)
    /// Plain text with no card, like a Photoshop type layer.
    case text(String)
}

/// Anything placed on a board. Frames are in board coordinates (y grows downward).
struct BoardItem: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: ItemKind
    var frame: CGRect
    /// Font size for text items; scales when the text box is resized.
    var fontSize: CGFloat?
    /// Text that wraps inside a fixed width (drawn with the Type tool, or reshaped with Shift).
    var paragraph: Bool?
    /// Caption shown under an image.
    var caption: String?
    /// Layer name set in the Layers panel (otherwise a name is made up from the content).
    var name: String?
    var hidden: Bool?
}

/// A named area on a board. Exported as a layer group in the PSD.
struct Section: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var frame: CGRect
    var colorIndex: Int
    var hidden: Bool?
}

/// How a board stacks up as layers, the same way the Layers panel shows it and the PSD export writes it:
/// each section is a group holding the items whose centers sit inside it (the smallest section wins),
/// everything else is a loose layer. Item order is back-to-front, as on the board.
struct LayerTree {
    var groups: [(section: Section, items: [BoardItem])]
    var loose: [BoardItem]

    init(_ board: Board) {
        var members: [UUID: [BoardItem]] = [:]
        var loose: [BoardItem] = []
        for item in board.items {
            let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
            if let owner = board.sections.filter({ $0.frame.contains(center) })
                .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                members[owner.id, default: []].append(item)
            } else {
                loose.append(item)
            }
        }
        groups = board.sections.map { ($0, members[$0.id] ?? []) }
        self.loose = loose
    }

    /// Items hidden directly or because their section is hidden.
    static func isHidden(_ item: BoardItem, in board: Board) -> Bool {
        if item.hidden == true { return true }
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        return board.sections.filter { $0.frame.contains(center) }
            .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })?.hidden == true
    }
}

extension BoardItem {
    /// The layer's name: the one given in the Layers panel, else something from its content.
    @MainActor func layerName(project: Project?, palettes: PaletteLibrary) -> String {
        if let name, !name.isEmpty { return name }
        switch kind {
        case .image(let id):
            return project?.asset(id).map { ($0.file as NSString).deletingPathExtension } ?? "Image"
        case .text(let text):
            let line = text.split(separator: "\n").first.map(String.init) ?? ""
            return line.isEmpty ? "Text" : String(line.prefix(40))
        case .note(let text):
            return text.isEmpty ? "Note" : "Note: " + String(text.prefix(30))
        case .palette(let id):
            return palettes.palette(id)?.name ?? "Palette"
        }
    }
}

struct Camera: Codable, Hashable {
    var center: CGPoint
    var zoom: CGFloat
}

struct Board: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var items: [BoardItem] = []
    var sections: [Section] = []
    var camera = Camera(center: .zero, zoom: 1)
}

struct Project: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// Folder name inside ~/Muse.
    var folder: String
    var created: Date
    var boards: [Board]
    var images: [ImageAsset] = []

    func asset(_ id: UUID) -> ImageAsset? { images.first { $0.id == id } }
}

enum SectionColors {
    static let all: [NSColor] = [
        NSColor(srgbRed: 0.55, green: 0.60, blue: 0.68, alpha: 1), // slate
        NSColor(srgbRed: 0.93, green: 0.42, blue: 0.36, alpha: 1), // coral
        NSColor(srgbRed: 0.96, green: 0.70, blue: 0.26, alpha: 1), // amber
        NSColor(srgbRed: 0.40, green: 0.75, blue: 0.45, alpha: 1), // green
        NSColor(srgbRed: 0.36, green: 0.62, blue: 0.95, alpha: 1), // blue
        NSColor(srgbRed: 0.72, green: 0.50, blue: 0.93, alpha: 1), // violet
    ]
}

/// All projects, saved as ~/Documents/Muse/<Project>/project.json with images in ~/Documents/Muse/<Project>/images.
@MainActor
final class Store: ObservableObject {
    /// ~/Documents/Muse, or MUSE_ROOT when testing.
    static let root = ProcessInfo.processInfo.environment["MUSE_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Muse")

    @Published private(set) var projects: [Project] = []
    @Published var currentProjectID: UUID?
    @Published var currentBoardID: UUID?
    let undoManager = UndoManager()
    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        load()
        if projects.isEmpty { createProject(named: "My Project") }
        currentProjectID = UserDefaults.standard.string(forKey: "currentProject").flatMap(UUID.init)
            .flatMap { id in projects.contains { $0.id == id } ? id : nil } ?? projects.first?.id
        currentBoardID = currentProject?.boards.first?.id
        if let saved = UserDefaults.standard.string(forKey: "currentBoard").flatMap(UUID.init),
           currentProject?.boards.contains(where: { $0.id == saved }) == true {
            currentBoardID = saved
        }
    }

    var currentProject: Project? { projects.first { $0.id == currentProjectID } }
    var currentBoard: Board? { currentProject?.boards.first { $0.id == currentBoardID } }

    func folderURL(_ project: Project) -> URL { Self.root.appendingPathComponent(project.folder) }
    func imagesURL(_ project: Project) -> URL { folderURL(project).appendingPathComponent("images") }
    /// Only the file name counts, so a project.json from elsewhere can't point outside its own images folder.
    func imageURL(_ asset: ImageAsset, in project: Project) -> URL { imagesURL(project).appendingPathComponent((asset.file as NSString).lastPathComponent) }

    // MARK: Loading and saving

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        projects = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
                  var project = try? decoder.decode(Project.self, from: data) else { return nil }
            project.folder = folder.lastPathComponent
            return project
        }
        .sorted { $0.created < $1.created }
    }

    /// Saves shortly after the last change, so dragging doesn't write the file on every frame.
    private func scheduleSave(_ projectID: UUID) {
        saveTasks[projectID]?.cancel()
        saveTasks[projectID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow(projectID)
        }
    }

    func saveNow(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: imagesURL(project), withIntermediateDirectories: true)
            try encoder.encode(project).write(to: folderURL(project).appendingPathComponent("project.json"), options: .atomic)
        } catch {
            NSLog("Muse: saving \(project.name) failed: \(error)")
        }
    }

    func saveAll() {
        for (id, task) in saveTasks { task.cancel(); saveNow(id) }
        saveTasks = [:]
    }

    // MARK: Projects

    @discardableResult
    func createProject(named base: String) -> Project {
        let name = uniqueProjectName(base)
        let project = Project(id: UUID(), name: name, folder: uniqueFolder(name), created: Date(),
                              boards: [Board(id: UUID(), name: "Board 1")])
        projects.append(project)
        saveNow(project.id)
        return project
    }

    func renameProject(_ id: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = projects.firstIndex(where: { $0.id == id }), projects[i].name != name else { return }
        let old = folderURL(projects[i])
        let folder = uniqueFolder(name)
        if (try? FileManager.default.moveItem(at: old, to: Self.root.appendingPathComponent(folder))) != nil {
            projects[i].folder = folder
        }
        projects[i].name = uniqueProjectName(name, excluding: id)
        saveNow(id)
    }

    /// Moves the project folder to the Trash, so it can be recovered from there.
    func deleteProject(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        saveTasks[id]?.cancel()
        NSWorkspace.shared.recycle([folderURL(project)])
        projects.removeAll { $0.id == id }
        if projects.isEmpty { createProject(named: "My Project") }
        if currentProjectID == id { select(project: projects[0].id) }
    }

    func select(project id: UUID, board boardID: UUID? = nil) {
        currentProjectID = id
        currentBoardID = boardID ?? projects.first { $0.id == id }?.boards.first?.id
        UserDefaults.standard.set(id.uuidString, forKey: "currentProject")
        UserDefaults.standard.set(currentBoardID?.uuidString, forKey: "currentBoard")
    }

    // MARK: Boards

    @discardableResult
    func addBoard(to projectID: UUID) -> Board? {
        guard let i = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let board = Board(id: UUID(), name: "Board \(projects[i].boards.count + 1)")
        projects[i].boards.append(board)
        scheduleSave(projectID)
        return board
    }

    func renameBoard(_ boardID: UUID, in projectID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let p = projects.firstIndex(where: { $0.id == projectID }),
              let b = projects[p].boards.firstIndex(where: { $0.id == boardID }) else { return }
        projects[p].boards[b].name = trimmed
        scheduleSave(projectID)
    }

    func deleteBoard(_ boardID: UUID, in projectID: UUID) {
        guard let p = projects.firstIndex(where: { $0.id == projectID }), projects[p].boards.count > 1 else { return }
        projects[p].boards.removeAll { $0.id == boardID }
        if currentBoardID == boardID { currentBoardID = projects[p].boards.first?.id }
        scheduleSave(projectID)
    }

    /// Every edit to the current board goes through here, so it can be undone.
    func updateBoard(_ actionName: String? = nil, undoable: Bool = true, _ change: (inout Board) -> Void) {
        guard let p = projects.firstIndex(where: { $0.id == currentProjectID }),
              let b = projects[p].boards.firstIndex(where: { $0.id == currentBoardID }) else { return }
        let before = projects[p].boards[b]
        change(&projects[p].boards[b])
        guard projects[p].boards[b] != before else { return }
        if undoable { registerUndo(before, projectID: projects[p].id, actionName: actionName) }
        scheduleSave(projects[p].id)
    }

    private func registerUndo(_ board: Board, projectID: UUID, actionName: String?) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                guard let p = store.projects.firstIndex(where: { $0.id == projectID }),
                      let b = store.projects[p].boards.firstIndex(where: { $0.id == board.id }) else { return }
                let current = store.projects[p].boards[b]
                store.projects[p].boards[b] = board
                store.registerUndo(current, projectID: projectID, actionName: actionName)
                store.scheduleSave(projectID)
            }
        }
        if let actionName { undoManager.setActionName(actionName) }
    }

    // MARK: Layers

    /// Puts a group's layers in the given order (top first), keeping the slots they had in the board's stack.
    func reorderLayers(topFirst ids: [UUID]) {
        updateBoard("Reorder Layers") { board in
            let wanted = Set(ids)
            let slots = board.items.indices.filter { wanted.contains(board.items[$0].id) }
            let byID = Dictionary(uniqueKeysWithValues: board.items.map { ($0.id, $0) })
            for (slot, id) in zip(slots, ids.reversed()) { board.items[slot] = byID[id]! }
        }
    }

    /// Moves a section (a layer group) up or down in the group order.
    func moveSection(_ id: UUID, up: Bool) {
        updateBoard(up ? "Move Group Up" : "Move Group Down") { board in
            guard let i = board.sections.firstIndex(where: { $0.id == id }) else { return }
            let j = up ? i + 1 : i - 1
            guard board.sections.indices.contains(j) else { return }
            board.sections.swapAt(i, j)
        }
    }

    func renameLayer(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateBoard("Rename Layer") { board in
            if let i = board.items.firstIndex(where: { $0.id == id }) { board.items[i].name = trimmed.isEmpty ? nil : trimmed }
            if let i = board.sections.firstIndex(where: { $0.id == id }), !trimmed.isEmpty { board.sections[i].name = trimmed }
        }
    }

    func toggleHidden(_ id: UUID) {
        updateBoard("Show/Hide Layer") { board in
            if let i = board.items.firstIndex(where: { $0.id == id }) { board.items[i].hidden = board.items[i].hidden == true ? nil : true }
            if let i = board.sections.firstIndex(where: { $0.id == id }) { board.sections[i].hidden = board.sections[i].hidden == true ? nil : true }
        }
    }

    func setCamera(_ camera: Camera) {
        updateBoard(undoable: false) { $0.camera = camera }
    }

    // MARK: Images

    /// Copies an image into the current project and returns its asset.
    func addImage(copying file: URL, sourceURL: String?) -> ImageAsset? {
        guard let p = projects.firstIndex(where: { $0.id == currentProjectID }) else { return nil }
        let project = projects[p]
        guard let size = Self.pixelSize(of: file) else { return nil }
        try? FileManager.default.createDirectory(at: imagesURL(project), withIntermediateDirectories: true)
        let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
        let dest = Self.unique(imagesURL(project), base: Self.cleanBase(file.deletingPathExtension().lastPathComponent), ext: ext)
        do {
            try FileManager.default.copyItem(at: file, to: dest)
        } catch {
            NSLog("Muse: copying \(file.path) failed: \(error)")
            return nil
        }
        let asset = ImageAsset(id: UUID(), file: dest.lastPathComponent, pixelWidth: size.width, pixelHeight: size.height,
                               sourceURL: sourceURL, added: Date())
        projects[p].images.append(asset)
        scheduleSave(project.id)
        return asset
    }

    func updateAsset(_ id: UUID, _ change: (inout ImageAsset) -> Void) {
        guard let p = projects.firstIndex(where: { $0.id == currentProjectID }),
              let a = projects[p].images.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[p].images[a])
        scheduleSave(projects[p].id)
    }

    /// Edits an image in any project (the Library spans them all).
    func updateAsset(_ assetID: UUID, inProject projectID: UUID, _ change: (inout ImageAsset) -> Void) {
        guard let p = projects.firstIndex(where: { $0.id == projectID }),
              let a = projects[p].images.firstIndex(where: { $0.id == assetID }) else { return }
        change(&projects[p].images[a])
        scheduleSave(projectID)
    }

    /// The current project's copy of an image: itself if it's already here, else a copy with its tags and note.
    func assetInCurrentProject(_ assetID: UUID, from projectID: UUID) -> ImageAsset? {
        if projectID == currentProjectID { return currentProject?.asset(assetID) }
        guard let project = projects.first(where: { $0.id == projectID }), let original = project.asset(assetID),
              var copy = addImage(copying: imageURL(original, in: project), sourceURL: original.sourceURL) else { return nil }
        updateAsset(copy.id) {
            $0.tags = original.tags
            $0.note = original.note
        }
        copy.tags = original.tags
        copy.note = original.note
        return copy
    }

    /// Boards (in a project) that show an image.
    func boards(using assetID: UUID, in projectID: UUID) -> [Board] {
        projects.first { $0.id == projectID }?.boards.filter { board in
            board.items.contains { if case .image(let id) = $0.kind { return id == assetID }; return false }
        } ?? []
    }

    nonisolated static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Rotated photos report their stored size; swap for orientations 5–8.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    // MARK: Names

    private func uniqueProjectName(_ base: String, excluding id: UUID? = nil) -> String {
        let taken = Set(projects.filter { $0.id != id }.map { $0.name.lowercased() })
        var name = base, n = 2
        while taken.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    private func uniqueFolder(_ name: String) -> String {
        let safe = Self.cleanBase(name)
        var folder = safe, n = 2
        while FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(folder).path) { folder = "\(safe) \(n)"; n += 1 }
        return folder
    }

    nonisolated static func cleanBase(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "image" : String(cleaned.prefix(80))
    }

    nonisolated static func unique(_ dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
