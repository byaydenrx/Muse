import AppKit

/// Window-level UI state shared between the canvas (AppKit) and the panels (SwiftUI).
/// Board tools, on the same keys as Photoshop.
enum Tool: String, CaseIterable, Identifiable {
    case move, hand, zoom, section, text, eyedropper
    var id: String { rawValue }

    var key: String {
        switch self {
        case .move: "V"
        case .hand: "H"
        case .zoom: "Z"
        case .section: "M"
        case .text: "T"
        case .eyedropper: "I"
        }
    }

    var name: String {
        switch self {
        case .move: "Move"
        case .hand: "Hand"
        case .zoom: "Zoom"
        case .section: "Section"
        case .text: "Type"
        case .eyedropper: "Eyedropper"
        }
    }

    var symbol: String {
        switch self {
        case .move: "cursorarrow"
        case .hand: "hand.raised"
        case .zoom: "plus.magnifyingglass"
        case .section: "rectangle.dashed"
        case .text: "textformat"
        case .eyedropper: "eyedropper"
        }
    }

    /// The eyedropper fills Pigment palettes, so it only shows when Pigment is installed.
    static var available: [Tool] { PaletteLibrary.pigmentInstalled ? allCases : allCases.filter { $0 != .eyedropper } }

    static func forKey(_ key: String) -> Tool? { available.first { $0.key.lowercased() == key } }
}

@MainActor
final class UIState: ObservableObject {
    enum RightPanel { case none, inspector, palettes, layers }

    @Published var tool: Tool = .move
    /// What's selected on the board, mirrored for the Layers panel.
    @Published var selectedIDs: Set<UUID> = []
    @Published var renamingLayerID: UUID?
    @Published var collapsedSections: Set<UUID> = []
    @Published var showingLibrary = false
    @Published var expandedProjects: Set<UUID> = []
    @Published var librarySearch = ""
    @Published var libraryTag: String?
    @Published var libraryAllProjects = true
    @Published var librarySelection: [LibraryRef] = []
    @Published var libraryTileSize: Double = 170
    @Published var libraryHover: LibraryRef?
    /// Bumped to put the cursor in the Library's search field.
    @Published var librarySearchFocus = 0
    var libraryColumns = 4
    /// The palette the eyedropper is filling, so clicks in a row build one palette.
    var activePaletteID: UUID?
    private var hiddenPanels: (sidebar: Bool, right: RightPanel)?

    /// Tab, like Photoshop: hide every panel, then bring back the same ones.
    func togglePanels() {
        if let hidden = hiddenPanels {
            sidebarVisible = hidden.sidebar
            rightPanel = hidden.right
            hiddenPanels = nil
        } else {
            hiddenPanels = (sidebarVisible, rightPanel)
            sidebarVisible = false
            rightPanel = .none
        }
    }

    @Published var sidebarVisible = true
    @Published var rightPanel: RightPanel = .none
    @Published var toolbarVisible = false
    @Published var toast: String?
    /// The image selected on the canvas, shown in the inspector.
    @Published var selectedAssetID: UUID?
    @Published var renamingProjectID: UUID?
    @Published var renamingBoardID: UUID?
    @Published var renameText = ""
    @Published var tagDraft = ""

    private var toastTask: Task<Void, Never>?

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { toast = nil }
        }
    }

    func toggle(_ panel: RightPanel) {
        rightPanel = rightPanel == panel ? .none : panel
    }
}

/// Floating, see-through and click-through settings for the window, with one-click presets.
@MainActor
final class WindowModes: ObservableObject {
    enum Preset: String, CaseIterable, Identifiable {
        case normal = "Normal", float = "Float", peek = "Peek", trace = "Trace"
        var id: String { rawValue }

        var detail: String {
            switch self {
            case .normal: "Regular window"
            case .float: "Always on top"
            case .peek: "On top, 70% opacity"
            case .trace: "On top, 45%, clicks pass through the board (⌥⇧T toggles)"
            }
        }
    }

    @Published var onTop = false { didSet { apply() } }
    @Published var opacity: Double = 1 { didSet { apply() } }
    @Published var clickThrough = false { didSet { apply() } }
    weak var window: NSWindow?
    /// While click-through is on: is this screen point somewhere that should stay clickable
    /// (panels, title bar, the toolbar strip)? Everything else passes clicks to the app underneath.
    var isInteractive: ((NSPoint) -> Bool)?
    private var pointerTimer: Timer?

    var activePreset: Preset? {
        Preset.allCases.first { values(for: $0) == (onTop, opacity, clickThrough) }
    }

    private func values(for preset: Preset) -> (Bool, Double, Bool) {
        switch preset {
        case .normal: (false, 1, false)
        case .float: (true, 1, false)
        case .peek: (true, 0.7, false)
        case .trace: (true, 0.45, true)
        }
    }

    func apply(_ preset: Preset) {
        let v = values(for: preset)
        onTop = v.0
        opacity = v.1
        clickThrough = v.2
    }

    private func apply() {
        guard let window else { return }
        window.level = onTop ? .floating : .normal
        window.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        window.alphaValue = opacity
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard clickThrough else {
            window.ignoresMouseEvents = false
            return
        }
        // A window can only ignore the mouse all at once, so follow the pointer and switch as it moves.
        updatePointer()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func updatePointer() {
        guard let window else { return }
        let ignore = !(isInteractive?(NSEvent.mouseLocation) ?? false)
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }
}
