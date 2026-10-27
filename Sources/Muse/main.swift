import AppKit
import Carbon
import SwiftUI

/// Clicks land on what they hit even when Muse is behind another app (no extra click to activate first).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = Store()
    private let palettes = PaletteLibrary()
    private let ui = UIState()
    private let modes = WindowModes()
    private lazy var canvas = CanvasView(store: store, palettes: palettes, ui: ui)
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Muse"
        window.minSize = NSSize(width: 520, height: 360)
        window.delegate = self
        let hosting = FirstClickHostingView(rootView: RootView(store: store, ui: ui, palettes: palettes, modes: modes, canvas: canvas))
        // The window keeps whatever size you give it; panels opening never grow it.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrameAutosaveName("MuseMain")
        if !window.setFrameUsingName("MuseMain") { window.center() }
        // One-time fix for a build where opening the Library's details grew the window to fill the screen.
        if !UserDefaults.standard.bool(forKey: "didResetOversizedWindow2") {
            UserDefaults.standard.set(true, forKey: "didResetOversizedWindow2")
            if window.frame.width > 1700 { window.setContentSize(NSSize(width: 1280, height: 820)); window.center() }
        }
        if let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame, !screen.contains(window.frame) {
            window.setFrame(window.frame.intersection(screen).isEmpty ? screen.insetBy(dx: 60, dy: 40) : window.frame.intersection(screen), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        modes.window = window
        modes.isInteractive = { [weak self] screenPoint in
            guard let self, let window = self.window else { return false }
            guard window.frame.contains(screenPoint) else { return false }
            let inWindow = window.convertPoint(fromScreen: screenPoint)
            let canvasRect = self.canvas.convert(self.canvas.bounds, to: nil)
            // Panels and title bar stay clickable; on the board, only the strip with the toolbar and pin does.
            guard canvasRect.contains(inWindow) else { return true }
            let inTopStrip = inWindow.y > canvasRect.maxY - 64
            if self.ui.toolbarVisible != inTopStrip { self.ui.toolbarVisible = inTopStrip }
            return inTopStrip
        }

        NSApp.mainMenu = buildMenu()

        // While the Library is up it gets the keys (arrows, Space, Return, typing to search) wherever focus is,
        // unless a text field is being edited.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.ui.showingLibrary, event.window === self.window else { return event }
            if let text = self.window.firstResponder as? NSTextView, text.isEditable { return event }
            if !event.modifierFlags.intersection([.command, .control]).isEmpty { return event }
            if self.window.firstResponder !== self.canvas { self.window.makeFirstResponder(self.canvas) }
            return LibraryView.handleKey(event, store: self.store, ui: self.ui, canvas: self.canvas) ? nil : event
        }

        // ⌥⇧T: toggle Trace (and the way back out of click-through). ⌥⇧4: screenshot straight onto the board.
        HotKeys.register(id: 1, keyCode: kVK_ANSI_T, modifiers: optionKey | shiftKey) { [weak self] in
            guard let self else { return }
            if self.modes.clickThrough {
                self.modes.clickThrough = false
                self.ui.show("Click-through off")
            } else {
                self.modes.apply(.trace)
                self.ui.show("Trace on — ⌥⇧T to turn off")
            }
        }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_4, modifiers: optionKey | shiftKey) { [weak self] in
            self?.screenshotToBoard()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        canvas.endEditing()
        store.saveAll()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }

    /// Saves the current board as a layered PSD (into the project's Exports folder by default).
    @objc func exportPSD() {
        guard let project = store.currentProject, let board = store.currentBoard else { return }
        canvas.endEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "psd")!]
        panel.nameFieldStringValue = "\(project.name) – \(board.name).psd"
        let exports = store.folderURL(project).appendingPathComponent("Exports")
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        panel.directoryURL = exports
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            MainActor.assumeIsolated {
                self.ui.show("Exporting PSD…")
                Task {
                    do {
                        let result = try await PSDExport.export(board: board, project: project, store: self.store, palettes: self.palettes, to: url)
                        self.exportFinished(url, result)
                    } catch {
                        self.ui.show("Export failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func exportFinished(_ url: URL, _ result: PSDExport.Result) {
        let alert = NSAlert()
        alert.messageText = "Exported \(url.lastPathComponent)"
        alert.informativeText = "\(result.layers) layers, \(result.width) × \(result.height) px. Sections are layer groups; palettes have one layer per color."
        alert.addButton(withTitle: "Open in Photoshop")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn:
                    if let app = Self.photoshopURL() {
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                case .alertSecondButtonReturn:
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                default:
                    break
                }
            }
        }
    }

    /// The regular Photoshop, newest first. The Beta shares its bundle id, so it's only used if it's the only one.
    static func photoshopURL() -> URL? {
        let all = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.adobe.Photoshop")
        let byNewest = all.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        return byNewest.first { !$0.lastPathComponent.localizedCaseInsensitiveContains("beta") } ?? byNewest.first
    }

    /// Drag out a region with the system screenshot tool; the result lands in the middle of the board.
    @objc func screenshotToBoard() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Muse Screenshot \(Int(Date().timeIntervalSince1970)).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard FileManager.default.fileExists(atPath: file.path) else { return }
                    self?.canvas.importFile(file)
                }
            }
        }
        try? process.run()
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Muse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Muse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(shortcut(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"), "h", [.command, .option]))
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Muse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main, title: "Muse")

        let file = NSMenu(title: "File")
        file.addItem(shortcut(MenuAction("New Project") { [weak self] in
            guard let self else { return }
            let project = self.store.createProject(named: "New Project")
            self.store.select(project: project.id)
            self.ui.sidebarVisible = true
            self.ui.renameText = project.name
            self.ui.renamingProjectID = project.id
        }, "n", [.command, .shift]))
        file.addItem(shortcut(MenuAction("New Board") { [weak self] in
            guard let self, let id = self.store.currentProjectID, let board = self.store.addBoard(to: id) else { return }
            self.store.select(project: id, board: board.id)
        }, "n"))
        file.addItem(.separator())
        file.addItem(shortcut(MenuAction("Add Images…") { [weak self] in
            guard let self else { return }
            self.canvas.chooseImages(at: self.canvas.centerWorld)
        }, "o"))
        let screenshot = MenuAction("Screenshot to Board") { [weak self] in self?.screenshotToBoard() }
        file.addItem(shortcut(screenshot, "4", [.option, .shift]))
        file.addItem(.separator())
        file.addItem(shortcut(MenuAction("Export Board as PSD…") { [weak self] in self?.exportPSD() }, "e", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(shortcut(MenuAction("Show Project in Finder") { [weak self] in
            guard let self, let project = self.store.currentProject else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.store.folderURL(project)])
        }, "r", [.command, .shift]))
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(shortcut(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z"), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(shortcut(MenuAction("Find in Library") { [weak self] in
            guard let self else { return }
            self.ui.showingLibrary = true
            self.ui.librarySearchFocus += 1
        }, "f"))
        edit.addItem(.separator())
        edit.addItem(shortcut(MenuAction("Deselect") { [weak self] in self?.canvas.deselectAll(nil) }, "d"))
        edit.addItem(shortcut(MenuAction("Duplicate") { [weak self] in self?.canvas.duplicateSelection() }, "j"))
        edit.addItem(shortcut(NSMenuItem(title: "Delete", action: #selector(CanvasView.delete(_:)), keyEquivalent: "\u{8}"), "\u{8}", []))
        add(edit, to: main, title: "Edit")

        let arrange = NSMenu(title: "Arrange")
        arrange.addItem(shortcut(MenuAction("Group into Section") { [weak self] in self?.canvas.addSection() }, "g"))
        arrange.addItem(shortcut(MenuAction("Remove Section (keep items)") { [weak self] in self?.canvas.ungroupSections() }, "g", [.command, .shift]))
        arrange.addItem(.separator())
        arrange.addItem(shortcut(MenuAction("Bring Forward") { [weak self] in self?.canvas.arrangeStep(true) }, "]"))
        arrange.addItem(shortcut(MenuAction("Send Backward") { [weak self] in self?.canvas.arrangeStep(false) }, "["))
        arrange.addItem(shortcut(MenuAction("Bring to Front") { [weak self] in self?.canvas.bringToFront(true) }, "]", [.command, .shift]))
        arrange.addItem(shortcut(MenuAction("Send to Back") { [weak self] in self?.canvas.bringToFront(false) }, "[", [.command, .shift]))
        add(arrange, to: main, title: "Arrange")

        // Single-letter tools are handled by the board itself, so typing in text fields still works.
        let tools = NSMenu(title: "Tools")
        for tool in Tool.available {
            let item = MenuAction("\(tool.name)\t\(tool.key)") { [weak self] in self?.ui.tool = tool }
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            tools.addItem(item)
        }
        add(tools, to: main, title: "Tools")

        let view = NSMenu(title: "View")
        view.addItem(shortcut(MenuAction("Projects Sidebar") { [weak self] in self?.ui.sidebarVisible.toggle() }, "s", [.command, .control]))
        view.addItem(shortcut(MenuAction("Library") { [weak self] in self?.ui.showingLibrary.toggle() }, "l"))
        view.addItem(shortcut(MenuAction("Layers") { [weak self] in self?.ui.toggle(.layers) },
                              String(Character(UnicodeScalar(NSF7FunctionKey)!)), []))
        view.addItem(shortcut(MenuAction("Image Info") { [weak self] in self?.ui.toggle(.inspector) }, "i"))
        if PaletteLibrary.pigmentInstalled {
            view.addItem(shortcut(MenuAction("Palettes") { [weak self] in self?.ui.toggle(.palettes) }, "p", [.command, .shift]))
        }
        view.addItem(.separator())
        view.addItem(shortcut(MenuAction("Fit on Screen") { [weak self] in self?.canvas.fitAll() }, "0"))
        view.addItem(shortcut(MenuAction("100%") { [weak self] in self?.canvas.actualSize() }, "1"))
        view.addItem(shortcut(MenuAction("Zoom In") { [weak self] in self?.canvas.zoomStep(1.25) }, "="))
        view.addItem(shortcut(MenuAction("Zoom Out") { [weak self] in self?.canvas.zoomStep(0.8) }, "-"))
        view.addItem(.separator())
        view.addItem(MenuAction("Hide Panels\tTab") { [weak self] in self?.ui.togglePanels() })
        view.addItem(shortcut(NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"), "f", [.command, .control]))
        add(view, to: main, title: "View")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        for (i, preset) in WindowModes.Preset.allCases.enumerated() {
            windowMenu.addItem(shortcut(MenuAction("\(preset.rawValue) — \(preset.detail)") { [weak self] in self?.modes.apply(preset) },
                                        "\(i + 1)", [.command, .control]))
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(windowMenu, to: main, title: "Window")
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: "Help")
        help.addItem(shortcut(MenuAction("Keyboard Shortcuts") { ShortcutsView.show() }, "/"))
        NSApp.helpMenu = help
        add(help, to: main, title: "Help")
        return main
    }

    private func add(_ menu: NSMenu, to main: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    private func shortcut(_ item: NSMenuItem, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

// Test mode: Muse --hidden <file> shows what the Pinterest search finds in saved drag data.
if let i = CommandLine.arguments.firstIndex(of: "--hidden"), CommandLine.arguments.count > i + 1,
   let data = FileManager.default.contents(atPath: CommandLine.arguments[i + 1]) {
    let found = Importer.hiddenPinterest(in: Importer.lenientText(data))
    print("image: \(found.image?.absoluteString ?? "-")\npin: \(found.pin?.absoluteString ?? "-")")
    exit(0)
}

// Test mode: Muse --fetch <url> <dir> runs the web import path (Pinterest upgrade, then page preview image).
// Test mode: Muse --photoshop prints which Photoshop "Open in Photoshop" uses.
if CommandLine.arguments.contains("--photoshop") {
    MainActor.assumeIsolated { print(AppDelegate.photoshopURL()?.path ?? "none") }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--fetch"), CommandLine.arguments.count > i + 2 {
    let url = URL(string: CommandLine.arguments[i + 1])!
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 2])
    Task {
        var tries = [url]
        if url.host?.contains("pinimg.com") == true {
            tries = Importer.bestPinterestURLs(for: url)
        } else if let image = await Importer.pageImage(url) {
            print("page image: \(image.absoluteString)")
            tries = image.host?.contains("pinimg.com") == true ? Importer.bestPinterestURLs(for: image) : [image]
        }
        print("trying: \(tries.map(\.absoluteString))")
        if let file = await Importer.download(tries, to: dir), let size = Store.pixelSize(of: file) {
            print("downloaded \(file.lastPathComponent): \(size.width)×\(size.height)")
        } else {
            print("no image")
        }
        exit(0)
    }
    dispatchMain()
}

// Test mode (with MUSE_ROOT set to a scratch folder): Muse --selftest <out.png> <images…>
// Imports the images, adds a note, a section and a palette card, then renders the board to a PNG.
if let i = CommandLine.arguments.firstIndex(of: "--selftest"), CommandLine.arguments.count > i + 2 {
    // Never touch the real libraries from a test run.
    if ProcessInfo.processInfo.environment["PIGMENT_ROOT"] == nil {
        setenv("PIGMENT_ROOT", FileManager.default.temporaryDirectory.appendingPathComponent("muse-selftest-palettes").path, 1)
    }
    if ProcessInfo.processInfo.environment["MUSE_ROOT"] == nil {
        setenv("MUSE_ROOT", FileManager.default.temporaryDirectory.appendingPathComponent("muse-selftest-boards").path, 1)
    }
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        let files = CommandLine.arguments[(i + 2)...].map { URL(fileURLWithPath: $0) as NSURL }
        let store = Store(), palettes = PaletteLibrary(), ui = UIState()
        let canvas = CanvasView(store: store, palettes: palettes, ui: ui)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        let pb = NSPasteboard(name: NSPasteboard.Name("muse.selftest"))
        pb.clearContents()
        pb.writeObjects(files)
        canvas.importFrom(pb, at: .zero)
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        spin(0.5)
        canvas.selectAll(nil)
        canvas.addSection()
        canvas.endEditing()
        canvas.addNote(at: CGPoint(x: -260, y: 0))
        canvas.endEditing()
        if let palette = palettes.palettes.first { canvas.addPalettes([palette.id], at: CGPoint(x: 0, y: 520)) }
        spin(0.3)
        canvas.fitAll()
        spin(1.5)

        // Tools, driven by real key and mouse events.
        @MainActor func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            canvas.keyDown(with: e)
        }
        @MainActor func click(_ w: CGPoint) {
            let p = canvas.windowPoint(forWorld: w)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                type == .leftMouseDown ? canvas.mouseDown(with: e) : canvas.mouseUp(with: e)
            }
        }
        let firstImage = store.currentBoard!.items.first { if case .image = $0.kind { return true }; return false }!
        key("i", code: 34)
        print("tool after I: \(ui.tool.rawValue)")
        click(CGPoint(x: firstImage.frame.midX, y: firstImage.frame.minY + 10))
        click(CGPoint(x: firstImage.frame.midX, y: firstImage.frame.maxY - 10))
        spin(0.2)
        let requests = (try? FileManager.default.contentsOfDirectory(atPath: PaletteLibrary.requestsDir.path)) ?? []
        for r in requests.sorted() {
            print("request: " + ((try? String(contentsOfFile: PaletteLibrary.requestsDir.appendingPathComponent(r).path, encoding: .utf8)) ?? ""))
        }
        key("t", code: 17)
        click(CGPoint(x: firstImage.frame.minX, y: firstImage.frame.minY - 120))
        canvas.editingText?.string = "Moodboard — Autumn"
        canvas.endEditing()
        key("v", code: 9)
        let textItem = store.currentBoard!.items.first { if case .text = $0.kind { return true }; return false }
        print("text item: \(textItem.map { "\($0.kind) \($0.frame.size)" } ?? "none"), tool now \(ui.tool.rawValue)")
        // Exiting the Type tool: Esc cancels new text, clicking the board confirms, ⌘Return confirms and returns to Move.
        @MainActor func textCount() -> Int { store.currentBoard!.items.filter { if case .text = $0.kind { return true }; return false }.count }
        @MainActor func editorKey(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            canvas.editingText?.keyDown(with: e)
        }
        let spot = CGPoint(x: firstImage.frame.maxX + 200, y: firstImage.frame.minY - 300)
        let start = textCount()
        key("t", code: 17)
        click(spot)
        let barShown = canvas.subviews.contains { $0 is EditBar }
        canvas.editingText?.string = "throwaway"
        editorKey(53)
        print("Esc: bar shown \(barShown), texts \(start) → \(textCount()), tool \(ui.tool.rawValue)")
        key("t", code: 17)
        click(spot)
        canvas.editingText?.string = "kept by clicking away"
        click(CGPoint(x: spot.x + 400, y: spot.y + 200))
        print("click away: texts → \(textCount()), still editing \(canvas.editingText != nil), tool \(ui.tool.rawValue)")
        click(CGPoint(x: spot.x, y: spot.y + 260))
        canvas.editingText?.string = "kept by ⌘Return"
        editorKey(36, .command)
        print("⌘Return: texts → \(textCount()), editing \(canvas.editingText != nil), bar gone \(!canvas.subviews.contains { $0 is EditBar }), tool \(ui.tool.rawValue)")
        // Scrubby zoom: drag right to zoom in, left to zoom out; the point under the cursor stays put.
        @MainActor func drag(from w: CGPoint, dx: CGFloat) {
            let start = canvas.windowPoint(forWorld: w)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            canvas.mouseDown(with: down)
            for step in 1...10 {
                let p = CGPoint(x: start.x + dx * CGFloat(step) / 10, y: start.y)
                canvas.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: p, modifierFlags: [], timestamp: 0,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            canvas.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: start.x + dx, y: start.y), modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        key("z", code: 6)
        let anchor = CGPoint(x: firstImage.frame.midX, y: firstImage.frame.midY)
        let anchorBefore = canvas.windowPoint(forWorld: anchor)
        let z0 = canvas.zoomLevel
        drag(from: anchor, dx: 120)
        let z1 = canvas.zoomLevel
        let anchorAfter = canvas.windowPoint(forWorld: anchor)
        drag(from: anchor, dx: -240)
        let z2 = canvas.zoomLevel
        click(anchor)
        let z3 = canvas.zoomLevel
        print(String(format: "scrub: %.2f → right 120px %.2f → left 240px %.2f → click %.2f; anchor moved %.1fpx", z0, z1, z2, z3,
                     hypot(anchorAfter.x - anchorBefore.x, anchorAfter.y - anchorBefore.y)))
        key("v", code: 9)

        // Handles: text corners scale the font, image side handles scale without stretching, sections move from anywhere.
        @MainActor func dragWorld(_ from: CGPoint, _ to: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            let a = canvas.windowPoint(forWorld: from), b = canvas.windowPoint(forWorld: to)
            func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: ev(.leftMouseDown, a))
            for i in 1...10 { canvas.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 10, y: a.y + (b.y - a.y) * CGFloat(i) / 10))) }
            canvas.mouseUp(with: ev(.leftMouseUp, b))
        }
        @MainActor func item(_ id: UUID) -> BoardItem { store.currentBoard!.items.first { $0.id == id }! }
        if let t = textItem {
            click(CGPoint(x: t.frame.midX, y: t.frame.midY))
            dragWorld(CGPoint(x: t.frame.maxX, y: t.frame.maxY), CGPoint(x: t.frame.minX + t.frame.width * 1.5, y: t.frame.minY + t.frame.height * 1.5))
            let after = item(t.id)
            print("text corner drag: font \(t.fontSize ?? 26) → \(after.fontSize ?? 0), size \(t.frame.size) → \(after.frame.size)")
        }
        let img = item(firstImage.id)
        click(CGPoint(x: img.frame.midX, y: img.frame.midY))
        dragWorld(CGPoint(x: img.frame.maxX, y: img.frame.midY), CGPoint(x: img.frame.maxX + 100, y: img.frame.midY))
        let img2 = item(img.id)
        print(String(format: "image side drag: %.0f×%.0f → %.0f×%.0f, aspect %.3f → %.3f", img.frame.width, img.frame.height,
                     img2.frame.width, img2.frame.height, img.frame.width / img.frame.height, img2.frame.width / img2.frame.height))
        let sec = store.currentBoard!.sections[0]
        // An empty spot inside the section (not covered by any item).
        var grab = CGPoint(x: sec.frame.minX + 8, y: sec.frame.maxY - 8)
        search: for y in stride(from: sec.frame.minY + 50, to: sec.frame.maxY, by: 6) {
            for x in stride(from: sec.frame.minX + 4, to: sec.frame.maxX, by: 6) {
                let p = CGPoint(x: x, y: y)
                if !store.currentBoard!.items.contains(where: { $0.frame.contains(p) })
                    && !store.currentBoard!.sections.contains(where: { $0.id != sec.id && $0.frame.contains(p) }) { grab = p; break search }
            }
        }
        let inside = store.currentBoard!.items.filter { sec.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        dragWorld(grab, CGPoint(x: grab.x + 100, y: grab.y + 50))
        let sec2 = store.currentBoard!.sections.first { $0.id == sec.id }!
        let movedInside = inside.filter { abs(item($0.id).frame.minX - $0.frame.minX - 100) < 0.01 && abs(item($0.id).frame.minY - $0.frame.minY - 50) < 0.01 }.count
        print("section body drag: moved \(sec2.frame.origin.x - sec.frame.origin.x), \(sec2.frame.origin.y - sec.frame.origin.y); items carried \(movedInside)/\(inside.count)")
        // Photoshop-style modifiers.
        func r(_ f: CGRect) -> String { String(format: "%.0f×%.0f @ (%.0f,%.0f)", f.width, f.height, f.midX, f.midY) }
        let i0 = item(img.id)
        click(CGPoint(x: i0.frame.midX, y: i0.frame.midY))
        dragWorld(CGPoint(x: i0.frame.maxX, y: i0.frame.maxY), CGPoint(x: i0.frame.maxX + 80, y: i0.frame.maxY - 40), .shift)
        let i1 = item(img.id)
        print("image corner + Shift (stretch): \(r(i0.frame)) → \(r(i1.frame))")
        dragWorld(CGPoint(x: i1.frame.maxX, y: i1.frame.maxY), CGPoint(x: i1.frame.maxX + 60, y: i1.frame.maxY + 60), .option)
        let i2 = item(img.id)
        print("image corner + Option (from center): \(r(i1.frame)) → \(r(i2.frame))")
        @MainActor func emptySpot(in id: UUID) -> CGPoint? {
            let f = store.currentBoard!.sections.first { $0.id == id }!.frame
            for y in stride(from: f.minY + 50, to: f.maxY, by: 6) {
                for x in stride(from: f.minX + 4, to: f.maxX, by: 6) {
                    let p = CGPoint(x: x, y: y)
                    if !store.currentBoard!.items.contains(where: { $0.frame.insetBy(dx: -2, dy: -40).contains(p) })
                        && !store.currentBoard!.sections.contains(where: { $0.id != id && $0.frame.contains(p) }) { return p }
                }
            }
            return nil
        }
        let s0 = store.currentBoard!.sections.first { $0.id == sec.id }!
        if let spot = emptySpot(in: sec.id) { click(spot) }
        dragWorld(CGPoint(x: s0.frame.maxX, y: s0.frame.maxY), CGPoint(x: s0.frame.maxX + 100, y: s0.frame.maxY + 10))
        let s1 = store.currentBoard!.sections.first { $0.id == sec.id }!
        dragWorld(CGPoint(x: s1.frame.maxX, y: s1.frame.maxY), CGPoint(x: s1.frame.maxX + 100, y: s1.frame.maxY + 10), .shift)
        let s2 = store.currentBoard!.sections.first { $0.id == sec.id }!
        print(String(format: "section corner free: aspect %.3f → %.3f; + Shift keeps aspect: → %.3f", s0.frame.width / s0.frame.height,
                     s1.frame.width / s1.frame.height, s2.frame.width / s2.frame.height))
        if let t = textItem {
            let t0 = item(t.id)
            click(CGPoint(x: t0.frame.midX, y: t0.frame.midY))
            dragWorld(CGPoint(x: t0.frame.maxX, y: t0.frame.midY), CGPoint(x: t0.frame.minX + t0.frame.width * 0.5, y: t0.frame.midY), .shift)
            let t1 = item(t.id)
            print("text side + Shift (re-wrap): font \(t0.fontSize ?? 0) → \(t1.fontSize ?? 0), \(r(t0.frame)) → \(r(t1.frame)), paragraph \(t1.paragraph ?? false)")
        }
        key("t", code: 17)
        let boxStart = CGPoint(x: grab.x + 900, y: grab.y - 400)
        dragWorld(boxStart, CGPoint(x: boxStart.x + 240, y: boxStart.y + 80))
        canvas.editingText?.string = "A paragraph box wraps its words inside the width you drew with the Type tool."
        canvas.endEditing(commit: true, backToMove: true)
        if let para = store.currentBoard!.items.last, case .text = para.kind {
            print("type drag → paragraph \(para.paragraph ?? false), width \(Int(para.frame.width)), height \(Int(para.frame.height))")
        }
        canvas.editCaption(item(img.id))
        canvas.editingText?.string = "Sonoma hills, warm late light"
        canvas.endEditing()
        print("caption: \(item(img.id).caption ?? "none")")
        let dbl = canvas.windowPoint(forWorld: emptySpot(in: sec.id) ?? grab)
        canvas.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: dbl, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
        print("double-click section body opens rename: \(canvas.editingText?.string ?? "no")")
        canvas.endEditing(commit: false)
        let before = store.currentBoard!.items.count
        click(CGPoint(x: firstImage.frame.midX, y: firstImage.frame.midY))
        canvas.duplicateSelection()
        key("", code: 124, flags: .shift)
        canvas.addSection()
        canvas.endEditing()
        print("items \(before) → \(store.currentBoard!.items.count) after ⌘J, sections: \(store.currentBoard!.sections.count)")
        // Layers: grouping, reorder within a group, rename, hide.
        @MainActor func describe() -> String {
            let tree = LayerTree(store.currentBoard!)
            let n = { (i: BoardItem) in i.layerName(project: store.currentProject, palettes: palettes) + (i.hidden == true ? " (hidden)" : "") }
            let loose = tree.loose.reversed().map(n).joined(separator: ", ")
            let groups = tree.groups.reversed().map { "[\($0.section.name): " + $0.items.reversed().map(n).joined(separator: ", ") + "]" }.joined(separator: " ")
            return "loose: \(loose) | groups: \(groups)"
        }
        print("layers before: " + describe())
        if let g = LayerTree(store.currentBoard!).groups.first(where: { $0.items.count >= 2 }) {
            let topFirst = g.items.reversed().map(\.id)
            store.reorderLayers(topFirst: Array(topFirst.dropFirst()) + [topFirst[0]])
            store.renameLayer(topFirst[0], to: "Hero shot")
            store.toggleHidden(topFirst[1])
        }
        print("layers after:  " + describe())
        canvas.fitAll()
        spin(1.0)
        if let psdIndex = CommandLine.arguments.firstIndex(of: "--psd"), CommandLine.arguments.count > psdIndex + 1 {
            let psdURL = URL(fileURLWithPath: CommandLine.arguments[psdIndex + 1])
            var finished = false
            Task {
                do {
                    let r = try await PSDExport.export(board: store.currentBoard!, project: store.currentProject!, store: store, palettes: palettes, to: psdURL)
                    print("psd: \(r.layers) layers, \(r.width)×\(r.height)")
                } catch { print("psd failed: \(error)") }
                finished = true
            }
            while !finished { spin(0.1) }
        }
        // Library: tag in project 1, place into project 2 (copied with its tags), "used on" lookup.
        do {
            let p1 = store.currentProject!
            let original = p1.images[0]
            store.updateAsset(original.id, inProject: p1.id) { $0.tags = ["sky", "warm"]; $0.note = "late light" }
            let used = store.boards(using: original.id, in: p1.id).map(\.name)
            let p2 = store.createProject(named: "Second Project")
            store.select(project: p2.id)
            spin(0.2)
            let copy = store.assetInCurrentProject(original.id, from: p1.id)
            canvas.placeAssets(copy.map { [$0] } ?? [])
            spin(0.2)
            let p2now = store.currentProject!
            print("library: used on \(used); copied into \(p2now.name): \(copy?.file ?? "none"), tags \(p2now.images.first?.tags ?? []), note \(p2now.images.first?.note ?? ""), board items \(store.currentBoard!.items.count), file exists \(copy.map { FileManager.default.fileExists(atPath: store.imageURL($0, in: p2now).path) } ?? false)")
            store.select(project: p1.id)
            spin(0.2)
        }
        let board = store.currentBoard!
        print("project: \(store.currentProject!.name), images: \(store.currentProject!.images.count), items: \(board.items.count), sections: \(board.sections.map(\.name))")
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(1200 * scale), pixelsHigh: Int(800 * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.translateBy(x: 0, y: 800 * scale)
        ctx.scaleBy(x: scale, y: -scale)
        canvas.layer!.render(in: ctx)
        try? rep.representation(using: .png, properties: [:])!.write(to: out)
        store.saveAll()
        print("wrote \(out.path)")
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate()
    app.run()
}
