import AppKit

/// Pigment's palettes as Muse sees them. Pigment owns ~/Palettes/library.json; Muse only reads it and asks for
/// changes through request files in ~/Palettes/.requests (the same way the Photoshop panel does).
struct PigmentPalette: Decodable, Identifiable, Hashable {
    struct Color: Decodable, Hashable {
        var hex: String
        var name: String?
    }

    var id: UUID
    var name: String
    var colors: [Color]
    var kind: String?
    var project: String?
    var projectID: UUID?
    var thumbnail: String?
}

@MainActor
final class PaletteLibrary: ObservableObject {
    /// ~/Palettes, or PIGMENT_ROOT when testing.
    static let root = ProcessInfo.processInfo.environment["PIGMENT_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Palettes")
    static var jsonURL: URL { root.appendingPathComponent("library.json") }
    static var requestsDir: URL { root.appendingPathComponent(".requests") }
    /// Palettes are made and stored by Pigment; without it, Muse hides its palette tools.
    nonisolated static let pigmentInstalled = ProcessInfo.processInfo.environment["PIGMENT_ROOT"] != nil
        || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.byaydenrx.pigment") != nil

    @Published private(set) var palettes: [PigmentPalette] = []
    private var lastModified: Date?
    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func palette(_ id: UUID) -> PigmentPalette? { palettes.first { $0.id == id } }

    func reload() {
        let modified = (try? Self.jsonURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != lastModified else { return }
        lastModified = modified
        struct File: Decodable { var palettes: [PigmentPalette] }
        guard let data = try? Data(contentsOf: Self.jsonURL), let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        palettes = file.palettes
    }

    // MARK: Requests to Pigment

    /// Makes a palette from an image file (Pigment extracts and names it). `id` is chosen here so the card can show it.
    func createFromImage(id: UUID, path: String, project: Project) {
        send(["action": "createFromImage", "id": id.uuidString, "path": path,
              "project": project.name, "projectID": project.id.uuidString])
    }

    /// Creates or updates a hand-made palette. Only the fields given are changed.
    func upsert(id: UUID, name: String? = nil, colors: [String]? = nil, project: Project? = nil) {
        var body: [String: Any] = ["action": "upsert", "id": id.uuidString]
        if let name { body["name"] = name }
        if let colors { body["colors"] = colors }
        if let project {
            body["project"] = project.name
            body["projectID"] = project.id.uuidString
        }
        send(body)
    }

    func rename(_ id: UUID, to name: String) {
        send(["action": "rename", "id": id.uuidString, "name": name])
    }

    private func send(_ body: [String: Any]) {
        ensurePigmentRunning()
        try? FileManager.default.createDirectory(at: Self.requestsDir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 0..<1_000_000)).json"
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            try? data.write(to: Self.requestsDir.appendingPathComponent(name), options: .atomic)
        }
    }

    private func ensurePigmentRunning() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.byaydenrx.pigment").isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.byaydenrx.pigment") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// Palettes dragged from Pigment or the palette drawer carry this text.
    nonisolated static let dragPrefix = "pigment-palette:"
}

extension PigmentPalette.Color {
    var nsColor: NSColor {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
