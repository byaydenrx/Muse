import AppKit
import Combine
import Quartz

/// The board: an endless dark canvas drawn with Core Animation layers.
/// Board coordinates have y growing downward; the camera maps them to the view.
@MainActor
final class CanvasView: NSView, NSTextViewDelegate {
    let store: Store
    let palettes: PaletteLibrary
    let ui: UIState

    private let world = CALayer()
    private let overlay = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private let sizeReadout = CATextLayer()
    private var itemLayers: [UUID: CALayer] = [:]
    private var sectionLayers: [UUID: CALayer] = [:]
    private var renderedKeys: [UUID: String] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    private(set) var selection: Set<UUID> = [] { didSet { selectionChanged() } }
    private var camera = Camera(center: .zero, zoom: 1)
    private var shownBoardID: UUID?
    private var spaceDown = false
    private var drag: Drag = .none
    private var editor: NSTextView?
    private var editorCommit: ((String) -> Void)?
    private var cameraSaveTask: Task<Void, Never>?

    private enum Drag {
        case none
        case pan(startPoint: CGPoint, startCenter: CGPoint)
        case move(startWorld: CGPoint, frames: [UUID: CGRect], moved: Bool)
        case marquee(startWorld: CGPoint, base: Set<UUID>)
        case resize(anchor: CGPoint, startBounds: CGRect, frames: [UUID: CGRect], onlySections: Bool, x: Bool, y: Bool)
        /// Photoshop's scrubby zoom: drag right to zoom in, left to zoom out, around where the drag started.
        case scrubZoom(startPoint: CGPoint, startZoom: CGFloat, anchor: CGPoint, moved: Bool)
        case drawSection(startWorld: CGPoint)
        /// Type tool: a click places a line of text, a drag draws a paragraph box.
        case drawText(startWorld: CGPoint)
    }

    init(store: Store, palettes: PaletteLibrary, ui: UIState) {
        self.store = store
        self.palettes = palettes
        self.ui = ui
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.115, alpha: 1).cgColor
        layer?.masksToBounds = true

        world.anchorPoint = .zero
        world.position = .zero
        layer?.addSublayer(world)
        for l in [overlay, handlesLayer, marqueeLayer] {
            l.fillColor = nil
            l.actions = ["path": NSNull()]
            layer?.addSublayer(l)
        }
        overlay.strokeColor = NSColor.controlAccentColor.cgColor
        overlay.lineWidth = 1.5
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = NSColor.controlAccentColor.cgColor
        handlesLayer.lineWidth = 1.5
        marqueeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        marqueeLayer.lineWidth = 1

        sizeReadout.fontSize = 11
        sizeReadout.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        sizeReadout.foregroundColor = NSColor.white.cgColor
        sizeReadout.backgroundColor = NSColor(white: 0.08, alpha: 0.85).cgColor
        sizeReadout.cornerRadius = 6
        sizeReadout.alignmentMode = .center
        sizeReadout.contentsScale = 2
        sizeReadout.isHidden = true
        sizeReadout.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(sizeReadout)

        registerForDraggedTypes(Importer.acceptedTypes)
        // The store and Pigment's library publish before they change; redraw on the next turn of the run loop.
        store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.sync() } }.store(in: &subscriptions)
        palettes.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.sync(forcePalettes: true) } }.store(in: &subscriptions)
        ui.$tool.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateCursorAtMouse() }
        }.store(in: &subscriptions)
        DispatchQueue.main.async { self.sync() }
    }

    // MARK: Cursors

    /// The tool's cursor on the board, but the normal arrow over buttons (toolbar, pin, ✓ / ✕).
    private func updateCursor(at p: CGPoint) {
        if case .pan = drag { return }
        let overButtons = (ui.toolbarVisible && p.y < 64)
            || (p.x > bounds.width - 60 && p.y < 60)
            || (editBar?.frame.insetBy(dx: -2, dy: -2).contains(p) ?? false)
        if overButtons { NSCursor.arrow.set() } else if spaceDown { NSCursor.openHand.set() } else { Self.cursor(for: ui.tool).set() }
    }

    private func updateCursorAtMouse() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) { updateCursor(at: p) }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: point(event)) }

    private static func cursor(for tool: Tool) -> NSCursor {
        switch tool {
        case .move: .arrow
        case .hand: .openHand
        case .section: .crosshair
        case .text: .iBeam
        case .zoom: symbolCursor("plus.magnifyingglass", hotSpot: CGPoint(x: 7, y: 7))
        case .eyedropper: symbolCursor("eyedropper", hotSpot: CGPoint(x: 2, y: 17))
        }
    }

    private static var cursorCache: [String: NSCursor] = [:]

    private static func symbolCursor(_ name: String, hotSpot: CGPoint) -> NSCursor {
        if let hit = cursorCache[name] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium).applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return .crosshair }
        // White symbol with a dark outline so it shows on any image.
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let inner = NSRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height)
            let dark = symbol.copy() as! NSImage
            dark.lockFocus()
            NSColor.black.set()
            NSRect(origin: .zero, size: dark.size).fill(using: .sourceAtop)
            dark.unlockFocus()
            for dx in [-1.0, 1.0] { for dy in [-1.0, 1.0] { dark.draw(in: inner.offsetBy(dx: dx, dy: dy)) } }
            symbol.draw(in: inner)
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: hotSpot)
        cursorCache[name] = cursor
        return cursor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        applyCamera()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: Coordinates

    private func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - bounds.midX) / camera.zoom + camera.center.x, y: (p.y - bounds.midY) / camera.zoom + camera.center.y)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - camera.center.x) * camera.zoom + bounds.midX, y: (p.y - camera.center.y) * camera.zoom + bounds.midY)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * camera.zoom, height: r.height * camera.zoom)
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func applyCamera() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.setAffineTransform(CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .scaledBy(x: camera.zoom, y: camera.zoom)
            .translatedBy(x: -camera.center.x, y: -camera.center.y))
        CATransaction.commit()
        drawSelection()
        moveEditorWithCamera()
        if sectionTitleSize != renderedTitleSize {
            renderedTitleSize = sectionTitleSize
            DispatchQueue.main.async { self.sync() }
        }
    }

    private func cameraChanged() {
        applyCamera()
        cameraSaveTask?.cancel()
        let camera = camera
        cameraSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { self?.store.setCamera(camera) }
        }
    }

    private func zoom(by factor: CGFloat, around viewPoint: CGPoint) {
        let before = toWorld(viewPoint)
        camera.zoom = min(max(camera.zoom * factor, 0.03), 16)
        let after = toWorld(viewPoint)
        camera.center.x += before.x - after.x
        camera.center.y += before.y - after.y
        cameraChanged()
    }

    func fitAll() {
        guard let board = store.currentBoard else { return }
        let rects = board.items.map(\.frame) + board.sections.map(\.frame)
        guard var union = rects.first else { camera = Camera(center: .zero, zoom: 1); cameraChanged(); return }
        rects.dropFirst().forEach { union = union.union($0) }
        let margin: CGFloat = 60
        camera.zoom = min((bounds.width - margin * 2) / max(union.width, 1), (bounds.height - margin * 2) / max(union.height, 1), 2)
        camera.center = CGPoint(x: union.midX, y: union.midY)
        cameraChanged()
    }

    var centerWorld: CGPoint { camera.center }
    /// Window coordinates of a board point (used by the self-test to click things).
    func windowPoint(forWorld w: CGPoint) -> CGPoint { convert(toView(w), to: nil) }
    var editingText: NSTextView? { editor }
    var zoomLevel: CGFloat { camera.zoom }

    func zoomStep(_ factor: CGFloat) { zoom(by: factor, around: CGPoint(x: bounds.midX, y: bounds.midY)) }

    // MARK: Drawing the board

    private func sync(forcePalettes: Bool = false) {
        guard let board = store.currentBoard, let project = store.currentProject else { return }
        if board.id != shownBoardID {
            shownBoardID = board.id
            camera = board.camera
            selection = []
            endEditing()
            applyCamera()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let sectionIDs = Set(board.sections.map(\.id))
        for (id, l) in sectionLayers where !sectionIDs.contains(id) { l.removeFromSuperlayer(); sectionLayers[id] = nil; renderedKeys[id] = nil }
        for section in board.sections {
            let l = sectionLayers[section.id] ?? { let l = CALayer(); world.addSublayer(l); sectionLayers[section.id] = l; return l }()
            l.zPosition = -1000
            l.isHidden = section.hidden == true
            let key = "\(section.name)|\(section.colorIndex)|\(section.frame.size)|\(sectionTitleSize)"
            if renderedKeys[section.id] != key { renderSection(l, section); renderedKeys[section.id] = key }
            l.frame = section.frame
        }

        let itemIDs = Set(board.items.map(\.id))
        for (id, l) in itemLayers where !itemIDs.contains(id) { l.removeFromSuperlayer(); itemLayers[id] = nil; renderedKeys[id] = nil }
        for (index, item) in board.items.enumerated() {
            let l = itemLayers[item.id] ?? { let l = CALayer(); world.addSublayer(l); itemLayers[item.id] = l; return l }()
            l.zPosition = CGFloat(index)
            l.frame = item.frame
            l.isHidden = LayerTree.isHidden(item, in: board)
            let key = renderKey(item)
            if renderedKeys[item.id] != key || (forcePalettes && isPalette(item)) {
                render(l, item, project: project)
                renderedKeys[item.id] = key
            }
        }
        CATransaction.commit()
        let kept = selection.filter { itemIDs.contains($0) || sectionIDs.contains($0) }
        if kept != selection { selection = kept }
        drawSelection()
    }

    private func isPalette(_ item: BoardItem) -> Bool {
        if case .palette = item.kind { return true }
        return false
    }

    private func renderKey(_ item: BoardItem) -> String {
        switch item.kind {
        case .image(let id): "img|\(id)|\(item.caption ?? "")|\(item.frame.size)"
        case .note(let text): "note|\(text)|\(item.frame.size)"
        case .text(let text): "text|\(text)|\(item.frame.size)|\(item.fontSize ?? Self.textSize)"
        case .palette(let id): "pal|\(id)|\(item.frame.size)|\(palettes.palette(id).map { "\($0.name)\($0.colors.map(\.hex))" } ?? "-")"
        }
    }

    private func render(_ l: CALayer, _ item: BoardItem, project: Project) {
        l.sublayers?.forEach { $0.removeFromSuperlayer() }
        l.contents = nil
        switch item.kind {
        case .image(let assetID):
            l.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
            l.contentsGravity = .resize
            l.minificationFilter = .trilinear
            l.cornerRadius = 0
            l.borderWidth = 0
            if let caption = item.caption, !caption.isEmpty {
                let t = textLayer(caption, size: Self.captionSize, weight: .regular, color: .secondaryLabelColor, wraps: true)
                t.frame = CGRect(x: 0, y: item.frame.height + Self.captionGap, width: item.frame.width,
                                 height: Self.captionHeight(caption, width: item.frame.width))
                l.addSublayer(t)
            }
            if let asset = project.asset(assetID) {
                ImageCache.image(store.imageURL(asset, in: project)) { [weak l] image in
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    l?.contents = image
                    l?.backgroundColor = nil
                    CATransaction.commit()
                }
            }
        case .note(let text):
            card(l)
            let t = textLayer(text.isEmpty ? "Note" : text, size: 15, weight: .regular, color: text.isEmpty ? .tertiaryLabelColor : .white, wraps: true)
            t.frame = CGRect(x: 12, y: 10, width: item.frame.width - 24, height: item.frame.height - 20)
            l.addSublayer(t)
        case .palette(let id):
            card(l)
            renderPalette(l, palette: palettes.palette(id), size: item.frame.size)
        case .text(let text):
            l.backgroundColor = nil
            l.borderWidth = 0
            l.cornerRadius = 0
            let t = textLayer(text.isEmpty ? "Text" : text, size: item.fontSize ?? Self.textSize, weight: .semibold,
                              color: text.isEmpty ? .tertiaryLabelColor : .white, wraps: true)
            t.frame = CGRect(x: 0, y: 0, width: item.frame.width, height: item.frame.height)
            l.addSublayer(t)
        }
    }

    private func card(_ l: CALayer) {
        l.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        l.cornerRadius = 12
        l.cornerCurve = .continuous
        l.borderWidth = 1
        l.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
    }

    static let paletteHeader: CGFloat = 34

    private func renderPalette(_ l: CALayer, palette: PigmentPalette?, size: CGSize) {
        guard let palette else {
            let t = textLayer(PaletteLibrary.pigmentInstalled ? "Waiting for Pigment…" : "Palettes need Pigment", size: 13, weight: .medium, color: .secondaryLabelColor)
            t.frame = CGRect(x: 12, y: 12, width: size.width - 24, height: 20)
            l.addSublayer(t)
            return
        }
        let title = textLayer(palette.name, size: 13, weight: .semibold, color: .white)
        title.frame = CGRect(x: 12, y: 10, width: size.width - 24, height: 18)
        l.addSublayer(title)
        let colors = palette.colors
        guard !colors.isEmpty else { return }
        let inset: CGFloat = 10, labels: CGFloat = size.height > 96 ? 16 : 0
        let strip = CGRect(x: inset, y: Self.paletteHeader, width: size.width - inset * 2, height: size.height - Self.paletteHeader - inset - labels)
        let container = CALayer()
        container.frame = strip
        container.cornerRadius = 7
        container.cornerCurve = .continuous
        container.masksToBounds = true
        let w = strip.width / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            let s = CALayer()
            s.backgroundColor = c.nsColor.cgColor
            s.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: strip.height)
            container.addSublayer(s)
            if labels > 0 && w >= 46 {
                let t = textLayer(c.hex, size: 9.5, weight: .medium, color: .secondaryLabelColor, mono: true, centered: true)
                t.frame = CGRect(x: strip.minX + CGFloat(i) * w, y: strip.maxY + 3, width: w, height: 13)
                l.addSublayer(t)
            }
        }
        l.addSublayer(container)
    }

    /// Section names are 28 pt on the board, but never smaller than 14 pt on screen when zoomed out.
    private var sectionTitleSize: CGFloat {
        let raw = max(28, 14 / camera.zoom)
        return raw <= 28 ? 28 : pow(2, (log2(raw) * 4).rounded() / 4) // steps, so zooming doesn't re-render every frame
    }
    private var renderedTitleSize: CGFloat = 28

    private func renderSection(_ l: CALayer, _ section: Section) {
        l.sublayers?.forEach { $0.removeFromSuperlayer() }
        let color = SectionColors.all[section.colorIndex % SectionColors.all.count]
        l.backgroundColor = color.withAlphaComponent(0.07).cgColor
        l.borderColor = color.withAlphaComponent(0.55).cgColor
        l.borderWidth = 1.5
        l.cornerRadius = 14
        l.cornerCurve = .continuous
        let size = sectionTitleSize
        let title = textLayer(section.name, size: size, weight: .bold, color: color)
        title.frame = CGRect(x: size * 0.6, y: size * 0.35, width: section.frame.width - size * 1.2, height: size * 1.3)
        l.addSublayer(title)
    }

    private func textLayer(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, wraps: Bool = false,
                           mono: Bool = false, centered: Bool = false) -> CATextLayer {
        let t = CATextLayer()
        t.string = string
        t.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        t.fontSize = size
        t.foregroundColor = color.cgColor
        t.isWrapped = wraps
        t.truncationMode = wraps ? .none : .end
        t.alignmentMode = centered ? .center : .left
        t.contentsScale = 4 // stays sharp when zoomed in
        return t
    }

    // MARK: Selection

    /// Selection from outside the board (the Layers panel).
    func select(_ ids: Set<UUID>) { selection = ids }

    private func selectionChanged() {
        drawSelection()
        if ui.selectedIDs != selection { ui.selectedIDs = selection }
        guard let board = store.currentBoard else { return }
        let images = board.items.filter { selection.contains($0.id) }.compactMap { item -> UUID? in
            if case .image(let id) = item.kind { return id }
            return nil
        }
        ui.selectedAssetID = selection.count == 1 ? images.first : nil
    }

    private func selectedFrames() -> [UUID: CGRect] {
        guard let board = store.currentBoard else { return [:] }
        var frames: [UUID: CGRect] = [:]
        for item in board.items where selection.contains(item.id) { frames[item.id] = item.frame }
        for section in board.sections where selection.contains(section.id) { frames[section.id] = section.frame }
        return frames
    }

    private func selectionBounds(_ frames: [UUID: CGRect]) -> CGRect? {
        guard var union = frames.values.first else { return nil }
        frames.values.dropFirst().forEach { union = union.union($0) }
        return union
    }

    private func drawSelection(frames override: [UUID: CGRect]? = nil) {
        let frames = override ?? selectedFrames()
        let outlines = CGMutablePath()
        for r in frames.values { outlines.addRect(toView(r).insetBy(dx: -1, dy: -1)) }
        let handles = CGMutablePath()
        if let b = selectionBounds(frames) {
            if frames.count > 1 { outlines.addRect(toView(b).insetBy(dx: -4, dy: -4)) }
            for h in handlePoints(b, count: frames.count) {
                handles.addRect(CGRect(x: h.view.x - 4.5, y: h.view.y - 4.5, width: 9, height: 9))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.path = outlines
        handlesLayer.path = handles
        CATransaction.commit()
    }

    private struct HandlePoint {
        let view: CGPoint
        /// The opposite corner or edge middle, which stays put while dragging.
        let anchor: CGPoint
        let x: Bool, y: Bool
    }

    /// Four corners and four edge middles of the selection box.
    private func handlePoints(_ b: CGRect, count: Int) -> [HandlePoint] {
        let pad: CGFloat = count > 1 ? -4 : -1
        let v = toView(b).insetBy(dx: pad, dy: pad)
        return [
            HandlePoint(view: CGPoint(x: v.minX, y: v.minY), anchor: CGPoint(x: b.maxX, y: b.maxY), x: true, y: true),
            HandlePoint(view: CGPoint(x: v.maxX, y: v.minY), anchor: CGPoint(x: b.minX, y: b.maxY), x: true, y: true),
            HandlePoint(view: CGPoint(x: v.minX, y: v.maxY), anchor: CGPoint(x: b.maxX, y: b.minY), x: true, y: true),
            HandlePoint(view: CGPoint(x: v.maxX, y: v.maxY), anchor: CGPoint(x: b.minX, y: b.minY), x: true, y: true),
            HandlePoint(view: CGPoint(x: v.midX, y: v.minY), anchor: CGPoint(x: b.midX, y: b.maxY), x: false, y: true),
            HandlePoint(view: CGPoint(x: v.midX, y: v.maxY), anchor: CGPoint(x: b.midX, y: b.minY), x: false, y: true),
            HandlePoint(view: CGPoint(x: v.minX, y: v.midY), anchor: CGPoint(x: b.maxX, y: b.midY), x: true, y: false),
            HandlePoint(view: CGPoint(x: v.maxX, y: v.midY), anchor: CGPoint(x: b.minX, y: b.midY), x: true, y: false),
        ]
    }

    // MARK: Hit testing

    private enum Hit {
        case handle(anchor: CGPoint, x: Bool, y: Bool)
        case item(UUID)
        case section(UUID)
        case nothing
    }

    private func hit(_ viewPoint: CGPoint) -> Hit {
        guard let board = store.currentBoard else { return .nothing }
        let frames = selectedFrames()
        if let b = selectionBounds(frames),
           let h = handlePoints(b, count: frames.count).first(where: { hypot($0.view.x - viewPoint.x, $0.view.y - viewPoint.y) <= 9 }) {
            return .handle(anchor: h.anchor, x: h.x, y: h.y)
        }
        let w = toWorld(viewPoint)
        if let item = board.items.reversed().first(where: {
            !LayerTree.isHidden($0, in: board) && ($0.frame.contains(w) || captionRect($0)?.contains(w) == true)
        }) {
            return .item(item.id)
        }
        // Anywhere on a section's empty area grabs the section; nested sections pick the smallest.
        if let section = board.sections.filter({ $0.hidden != true && $0.frame.contains(w) }).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return .section(section.id)
        }
        return .nothing
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        let near = p.y < 64
        if ui.toolbarVisible != near { ui.toolbarVisible = near }
        updateCursor(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        if ui.toolbarVisible { ui.toolbarVisible = false }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let wasEditing = editor != nil
        window?.makeFirstResponder(self)
        endEditing()
        // With the Type tool, a click while typing just confirms the text instead of starting a new one.
        if wasEditing && ui.tool == .text { return }
        let p = point(event)
        if spaceDown || ui.tool == .hand {
            drag = .pan(startPoint: p, startCenter: camera.center)
            NSCursor.closedHand.set()
            return
        }
        switch ui.tool {
        case .zoom: drag = .scrubZoom(startPoint: p, startZoom: camera.zoom, anchor: toWorld(p), moved: false); return
        case .section: drag = .drawSection(startWorld: toWorld(p)); return
        case .text:
            if !editExistingText(at: p) { drag = .drawText(startWorld: toWorld(p)) }
            return
        case .eyedropper: sample(at: p); return
        case .move, .hand: break
        }
        if event.clickCount == 2 { doubleClick(at: p); return }
        let shift = event.modifierFlags.contains(.shift)
        switch hit(p) {
        case .handle(let anchor, let ax, let ay):
            let frames = selectedFrames()
            guard let b = selectionBounds(frames) else { return }
            let onlySections = selection.allSatisfy { id in store.currentBoard?.sections.contains { $0.id == id } == true }
            drag = .resize(anchor: anchor, startBounds: b, frames: frames, onlySections: onlySections, x: ax, y: ay)
        case .section where event.modifierFlags.contains(.command):
            // ⌘-drag inside a section box-selects instead of grabbing the section.
            drag = .marquee(startWorld: toWorld(p), base: shift ? selection : [])
            if !shift { selection = [] }
        case .item(let id), .section(let id):
            if shift {
                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            } else if !selection.contains(id) {
                selection = [id]
            }
            drag = .move(startWorld: toWorld(p), frames: framesForMove(), moved: false)
        case .nothing:
            if !shift { selection = [] }
            drag = .marquee(startWorld: toWorld(p), base: selection)
        }
    }

    /// The selection plus everything sitting inside any selected section.
    private func framesForMove() -> [UUID: CGRect] {
        var frames = selectedFrames()
        guard let board = store.currentBoard else { return frames }
        for section in board.sections where selection.contains(section.id) {
            for item in board.items where section.frame.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) {
                frames[item.id] = item.frame
            }
        }
        return frames
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .pan(let start, let center):
            camera.center = CGPoint(x: center.x - (p.x - start.x) / camera.zoom, y: center.y - (p.y - start.y) / camera.zoom)
            cameraChanged()
        case .move(let start, let frames, _):
            let w = toWorld(p)
            let dx = w.x - start.x, dy = w.y - start.y
            let moved = frames.mapValues { $0.offsetBy(dx: dx, dy: dy) }
            showLive(moved)
            drag = .move(startWorld: start, frames: frames, moved: true)
        case .marquee(let start, let base):
            let w = toWorld(p)
            let rect = CGRect(x: min(start.x, w.x), y: min(start.y, w.y), width: abs(w.x - start.x), height: abs(w.y - start.y))
            marqueeLayer.path = CGPath(rect: toView(rect), transform: nil)
            guard let board = store.currentBoard else { return }
            let inside = board.items.filter { $0.frame.intersects(rect) }.map(\.id)
                + board.sections.filter { rect.contains($0.frame) }.map(\.id)
            selection = base.union(inside)
        case .resize(let handleAnchor, let b, let frames, let onlySections, let ax, let ay):
            // Like Photoshop: images and text scale in proportion unless Shift is held; sections are the other way
            // round. ⌥ scales from the center.
            let shift = event.modifierFlags.contains(.shift)
            let fromCenter = event.modifierFlags.contains(.option)
            let proportional = onlySections ? shift : !shift
            resizeProportional = proportional
            let anchor = fromCenter ? CGPoint(x: b.midX, y: b.midY) : handleAnchor
            let spanX = fromCenter ? b.width / 2 : b.width, spanY = fromCenter ? b.height / 2 : b.height
            let w = toWorld(p)
            var sx = ax ? abs(w.x - anchor.x) / max(spanX, 1) : 1
            var sy = ay ? abs(w.y - anchor.y) / max(spanY, 1) : 1
            if proportional {
                let s = ax && ay ? max(sx, sy) : (ax ? sx : sy)
                sx = s; sy = s
            }
            sx = max(sx, 0.02); sy = max(sy, 0.02)
            let resized = frames.mapValues { r -> CGRect in
                let x = anchor.x + (r.minX - anchor.x) * sx, y = anchor.y + (r.minY - anchor.y) * sy
                let x2 = anchor.x + (r.maxX - anchor.x) * sx, y2 = anchor.y + (r.maxY - anchor.y) * sy
                return CGRect(x: min(x, x2), y: min(y, y2), width: abs(x2 - x), height: abs(y2 - y))
            }
            showLive(resized)
            showSizeReadout(resized, at: p)
        case .scrubZoom(let start, let startZoom, let anchor, let moved):
            let dx = p.x - start.x
            guard moved || abs(dx) > 3 else { return }
            camera.zoom = min(max(startZoom * exp(dx * 0.009), 0.03), 16)
            // Keep the point under the cursor at the start fixed while zooming.
            camera.center = CGPoint(x: anchor.x - (start.x - bounds.midX) / camera.zoom, y: anchor.y - (start.y - bounds.midY) / camera.zoom)
            cameraChanged()
            drag = .scrubZoom(startPoint: start, startZoom: startZoom, anchor: anchor, moved: true)
        case .drawSection(let start), .drawText(let start):
            let w = toWorld(p)
            let rect = CGRect(x: min(start.x, w.x), y: min(start.y, w.y), width: abs(w.x - start.x), height: abs(w.y - start.y))
            marqueeLayer.path = CGPath(rect: toView(rect), transform: nil)
        case .none:
            break
        }
    }

    /// Moves layers without touching the store; the change is saved once, on mouse up.
    private func showLive(_ frames: [UUID: CGRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, r) in frames { (itemLayers[id] ?? sectionLayers[id])?.frame = r }
        // Text grows and shrinks with its box while dragging (or just re-wraps when reshaped with Shift).
        if case .resize = drag, let board = store.currentBoard {
            for item in board.items where frames[item.id] != nil {
                guard case .text = item.kind, let layer = itemLayers[item.id], let t = layer.sublayers?.first as? CATextLayer else { continue }
                let scale = frames[item.id]!.height / max(item.frame.height, 1)
                t.fontSize = (item.fontSize ?? Self.textSize) * (resizeProportional ? scale : 1)
                t.frame = layer.bounds
            }
        }
        CATransaction.commit()
        drawSelection(frames: frames.filter { selection.contains($0.key) })
        pendingFrames = frames
    }

    private var pendingFrames: [UUID: CGRect] = [:]

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .pan:
            drag = .none
            updateCursor(at: point(event))
        case .move(let start, _, let moved):
            if moved { commit(pendingFrames, action: "Move") } else { clickedWithoutMoving(at: start) }
        case .resize:
            sizeReadout.isHidden = true
            commit(pendingFrames, action: "Resize")
        case .marquee:
            marqueeLayer.path = nil
        case .scrubZoom(let start, _, _, let moved):
            // A plain click steps the zoom, like Photoshop: in, or out with ⌥.
            if !moved { zoom(by: event.modifierFlags.contains(.option) ? 0.5 : 2, around: start) }
        case .drawText(let start):
            marqueeLayer.path = nil
            let w = toWorld(point(event))
            let width = abs(w.x - start.x)
            if width * camera.zoom >= 24 {
                addText(at: CGPoint(x: min(start.x, w.x), y: min(start.y, w.y)), width: width)
            } else {
                addText(at: start)
            }
        case .drawSection(let start):
            marqueeLayer.path = nil
            let w = toWorld(point(event))
            let rect = CGRect(x: min(start.x, w.x), y: min(start.y, w.y), width: abs(w.x - start.x), height: abs(w.y - start.y))
            if rect.width * camera.zoom >= 24 && rect.height * camera.zoom >= 24 { addSection(frame: rect) }
        case .none:
            break
        }
        drag = .none
        pendingFrames = [:]
    }

    /// A plain click on a palette swatch copies its HEX.
    private func clickedWithoutMoving(at w: CGPoint) {
        guard let board = store.currentBoard,
              let item = board.items.reversed().first(where: { $0.frame.contains(w) }),
              case .palette(let id) = item.kind, let palette = palettes.palette(id),
              let color = paletteColor(at: w, item: item, palette: palette) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.hex, forType: .string)
        ui.show("Copied \(color.name.map { "\($0) " } ?? "")\(color.hex)")
    }

    private var resizeProportional = true

    static func textHeight(_ text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let h = (text as NSString).boundingRect(with: CGSize(width: max(width - size * 0.5, 10), height: 100_000),
                                                options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        return ceil(h) + size * 0.3
    }

    /// Photoshop-style readout next to the cursor while resizing: W × H, or the point size for a text item.
    private func showSizeReadout(_ frames: [UUID: CGRect], at p: CGPoint) {
        guard let b = selectionBounds(frames.filter { selection.contains($0.key) }) else { return }
        var label = "W \(Int(b.width.rounded()))   H \(Int(b.height.rounded()))"
        if frames.count == 1, let id = frames.keys.first, let item = store.currentBoard?.items.first(where: { $0.id == id }),
           case .text = item.kind {
            let size = (item.fontSize ?? Self.textSize) * (resizeProportional ? frames[id]!.height / max(item.frame.height, 1) : 1)
            label = "\(Int(size.rounded())) pt" + (resizeProportional ? "" : "   W \(Int(b.width.rounded()))")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sizeReadout.string = label
        let width = CGFloat(label.count) * 7.2 + 20
        sizeReadout.frame = CGRect(x: min(p.x + 16, bounds.width - width - 6), y: min(p.y + 18, bounds.height - 30), width: width, height: 22)
        sizeReadout.isHidden = false
        CATransaction.commit()
    }

    private func commit(_ frames: [UUID: CGRect], action: String) {
        guard !frames.isEmpty else { return }
        store.updateBoard(action) { board in
            for i in board.items.indices {
                guard let r = frames[board.items[i].id] else { continue }
                if action == "Resize", case .text(let text) = board.items[i].kind {
                    if resizeProportional {
                        let scale = r.height / max(board.items[i].frame.height, 1)
                        board.items[i].fontSize = ((board.items[i].fontSize ?? Self.textSize) * scale).rounded()
                        board.items[i].frame = r
                    } else {
                        // Reshaped with Shift: same font, new width; the height follows the wrapped text.
                        let size = board.items[i].fontSize ?? Self.textSize
                        board.items[i].paragraph = true
                        board.items[i].frame = CGRect(origin: r.origin, size: CGSize(width: r.width,
                                                       height: Self.textHeight(text, size: size, width: r.width)))
                    }
                    continue
                }
                board.items[i].frame = r
            }
            for i in board.sections.indices { if let r = frames[board.sections[i].id] { board.sections[i].frame = r } }
        }
        // Notes and sections re-render text at their new size.
        sync()
    }

    override func otherMouseDown(with event: NSEvent) {
        drag = .pan(startPoint: point(event), startCenter: camera.center)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && event.modifierFlags.intersection([.command, .option]).isEmpty {
            camera.center.x -= event.scrollingDeltaX / camera.zoom
            camera.center.y -= event.scrollingDeltaY / camera.zoom
            cameraChanged()
        } else {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            zoom(by: exp(delta), around: point(event))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: point(event))
    }

    private func doubleClick(at p: CGPoint) {
        guard let board = store.currentBoard else { return }
        switch hit(p) {
        case .item(let id):
            guard let item = board.items.first(where: { $0.id == id }) else { return }
            switch item.kind {
            case .note(let text): editNote(item, text: text)
            case .text(let text): editText(item, text: text)
            case .image:
                if captionRect(item)?.contains(toWorld(p)) == true { editCaption(item) } else { zoom(to: item.frame) }
            case .palette: break
            }
        case .section(let id):
            if let section = board.sections.first(where: { $0.id == id }) { renameSection(section) }
        default:
            break
        }
    }

    private func zoom(to rect: CGRect) {
        camera.zoom = min((bounds.width - 80) / rect.width, (bounds.height - 80) / rect.height, 8)
        camera.center = CGPoint(x: rect.midX, y: rect.midY)
        cameraChanged()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // space
            if !event.isARepeat { spaceDown = true; NSCursor.openHand.set() }
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let plain = flags.isEmpty
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: removeSelection(); return
        case 53: selection = []; ui.tool = .move; return
        case 48 where plain: ui.togglePanels(); return                // Tab
        case 123: nudge(dx: -step, dy: 0); return                       // arrows, ⇧ for 10
        case 124: nudge(dx: step, dy: 0); return
        case 125: nudge(dx: 0, dy: step); return
        case 126: nudge(dx: 0, dy: -step); return
        default: break
        }
        guard plain else { super.keyDown(with: event); return }
        if let tool = Tool.forKey(key) {
            ui.tool = tool
            ui.show("\(tool.name) tool (\(tool.key))")
            return
        }
        switch key {
        case "f": window?.toggleFullScreen(nil)
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            updateCursorAtMouse()
        } else {
            super.keyUp(with: event)
        }
    }

    private func mouseWorld() -> CGPoint {
        guard let window else { return camera.center }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? toWorld(p) : camera.center
    }

    // MARK: Editing commands

    @objc override func selectAll(_ sender: Any?) {
        guard let board = store.currentBoard else { return }
        selection = Set(board.items.map(\.id) + board.sections.map(\.id))
    }

    @objc func delete(_ sender: Any?) { removeSelection() }

    func removeSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        store.updateBoard("Remove") { board in
            board.items.removeAll { ids.contains($0.id) }
            board.sections.removeAll { ids.contains($0.id) }
        }
        selection = []
    }

    @objc func paste(_ sender: Any?) {
        importFrom(NSPasteboard.general, at: mouseWorld())
    }

    func bringToFront(_ front: Bool) {
        let ids = selection
        store.updateBoard(front ? "Bring to Front" : "Send to Back") { board in
            let moving = board.items.filter { ids.contains($0.id) }
            board.items.removeAll { ids.contains($0.id) }
            board.items = front ? board.items + moving : moving + board.items
        }
    }

    func addNote(at w: CGPoint) {
        let item = BoardItem(id: UUID(), kind: .note(""), frame: CGRect(x: w.x - 110, y: w.y - 40, width: 220, height: 80))
        store.updateBoard("Add Note") { $0.items.append(item) }
        selection = [item.id]
        sync()
        editNote(item, text: "")
    }

    /// Wraps the selection in a section (⌘G), or drops an empty one in the middle of the view.
    func addSection(frame drawn: CGRect? = nil) {
        let frames = selectedFrames()
        let rect: CGRect
        if let drawn {
            rect = drawn
        } else if let b = selectionBounds(frames) {
            // Room around the items, plus space at the top for the name.
            rect = CGRect(x: b.minX - 30, y: b.minY - 64, width: b.width + 60, height: b.height + 94)
        } else {
            let c = mouseWorld()
            rect = CGRect(x: c.x - 300, y: c.y - 200, width: 600, height: 400)
        }
        let count = store.currentBoard?.sections.count ?? 0
        let section = Section(id: UUID(), name: "Section \(count + 1)", frame: rect, colorIndex: count % SectionColors.all.count)
        store.updateBoard("Add Section") { $0.sections.append(section) }
        selection = [section.id]
        sync()
        renameSection(section)
    }

    func addPalettes(_ ids: [UUID], at w: CGPoint) {
        var y = w.y
        var added: [UUID] = []
        store.updateBoard("Add Palette") { board in
            for id in ids {
                let count = max(palettes.palette(id)?.colors.count ?? 5, 1)
                let width = min(max(CGFloat(count) * 58 + 20, 260), 560)
                let item = BoardItem(id: UUID(), kind: .palette(id), frame: CGRect(x: w.x - width / 2, y: y, width: width, height: 116))
                board.items.append(item)
                added.append(item.id)
                y += 128
            }
        }
        selection = Set(added)
    }

    /// Eyedropper first, then a new project palette with that color, placed at `w`.
    func newPalette(at w: CGPoint) {
        guard let project = store.currentProject else { return }
        NSColorSampler().show { [weak self] color in
            guard let self, let color else { return }
            MainActor.assumeIsolated {
                let id = UUID()
                let existing = self.palettes.palettes.filter { $0.projectID == project.id }.count
                self.palettes.upsert(id: id, name: "\(project.name) \(existing + 1)", colors: [Self.hex(color)], project: project)
                self.addPalettes([id], at: w)
                self.ui.show("New palette — right-click it to add more colors")
            }
        }
    }

    func addColor(toPalette id: UUID) {
        NSColorSampler().show { [weak self] color in
            guard let self, let color else { return }
            MainActor.assumeIsolated {
                let colors = (self.palettes.palette(id)?.colors.map(\.hex) ?? []) + [Self.hex(color)]
                self.palettes.upsert(id: id, colors: colors)
            }
        }
    }

    func makePalette(fromImageItem item: BoardItem) {
        guard case .image(let assetID) = item.kind, let project = store.currentProject, let asset = project.asset(assetID) else { return }
        let id = UUID()
        palettes.createFromImage(id: id, path: store.imageURL(asset, in: project).path, project: project)
        addPalettes([id], at: CGPoint(x: item.frame.midX, y: item.frame.maxY + 16))
        ui.show("Making a palette in Pigment…")
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    // MARK: Photoshop-style commands

    @objc func deselectAll(_ sender: Any?) { selection = [] }

    func nudge(dx: CGFloat, dy: CGFloat) {
        let frames = framesForMove()
        guard !frames.isEmpty else { return }
        commit(frames.mapValues { $0.offsetBy(dx: dx, dy: dy) }, action: "Nudge")
    }

    /// ⌘J: copies of the selected items, slightly offset, become the selection.
    func duplicateSelection() {
        let ids = selection
        var copies: [BoardItem] = []
        store.updateBoard("Duplicate") { board in
            for item in board.items where ids.contains(item.id) {
                var copy = item
                copy.id = UUID()
                copy.frame = copy.frame.offsetBy(dx: 24, dy: 24)
                copies.append(copy)
            }
            board.items.append(contentsOf: copies)
        }
        if !copies.isEmpty { selection = Set(copies.map(\.id)) }
    }

    /// ⇧⌘G: removes the selected sections but keeps everything that was in them.
    func ungroupSections() {
        let ids = selection
        store.updateBoard("Remove Section") { $0.sections.removeAll { ids.contains($0.id) } }
        selection = selection.filter { id in store.currentBoard?.items.contains { $0.id == id } == true }
    }

    /// ⌘] / ⌘[: one step forward or back among overlapping order.
    func arrangeStep(_ forward: Bool) {
        let ids = selection
        store.updateBoard(forward ? "Bring Forward" : "Send Backward") { board in
            var items = board.items
            let indices = items.indices.filter { ids.contains(items[$0].id) }
            for i in (forward ? indices.reversed() : indices) {
                let j = forward ? i + 1 : i - 1
                guard items.indices.contains(j), !ids.contains(items[j].id) else { continue }
                items.swapAt(i, j)
            }
            board.items = items
        }
    }

    /// ⌘1: 100%.
    func actualSize() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        zoom(by: 1 / camera.zoom, around: center)
    }

    // MARK: Type tool

    static let textSize: CGFloat = 26

    /// Type tool on existing text (or a note, or a caption) edits it.
    private func editExistingText(at p: CGPoint) -> Bool {
        guard let board = store.currentBoard, case .item(let id) = hit(p), let item = board.items.first(where: { $0.id == id }) else { return false }
        switch item.kind {
        case .text(let text): selection = [id]; editText(item, text: text); return true
        case .note(let text): selection = [id]; editNote(item, text: text); return true
        case .image where captionRect(item)?.contains(toWorld(p)) == true: selection = [id]; editCaption(item); return true
        default: return false
        }
    }

    /// A line of text at `w`, or a paragraph box of `width` that wraps.
    func addText(at w: CGPoint, width: CGFloat? = nil) {
        let item = BoardItem(id: UUID(), kind: .text(""),
                             frame: CGRect(x: w.x, y: width == nil ? w.y - Self.textSize * 0.6 : w.y,
                                           width: width ?? 320, height: Self.textSize * 1.4),
                             fontSize: Self.textSize, paragraph: width == nil ? nil : true)
        store.updateBoard("Add Text") { $0.items.append(item) }
        selection = [item.id]
        sync()
        editText(item, text: "")
    }

    private func editText(_ item: BoardItem, text: String) {
        let size = item.fontSize ?? Self.textSize
        let editWidth = item.paragraph == true ? item.frame.width : max(item.frame.width, size * 12)
        beginEditing(text: text, world: CGRect(x: item.frame.minX, y: item.frame.minY, width: editWidth, height: max(item.frame.height, size * 1.4)),
                     fontSize: size, multiline: true, weight: .semibold, cancel: { [weak self] in
            // Cancelling brand-new text removes it; cancelling an edit keeps the old words.
            if text.isEmpty { self?.store.updateBoard("Remove Text") { $0.items.removeAll { $0.id == item.id } } }
        }) { [weak self] newText in
            guard let self else { return }
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Empty text disappears, like an empty type layer.
                self.store.updateBoard("Remove Text") { $0.items.removeAll { $0.id == item.id } }
                return
            }
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let measured = (trimmed as NSString).boundingRect(with: CGSize(width: size * 25, height: 10_000), options: [.usesLineFragmentOrigin],
                                                              attributes: [.font: font])
            self.store.updateBoard("Edit Text") { board in
                guard let i = board.items.firstIndex(where: { $0.id == item.id }) else { return }
                board.items[i].kind = .text(trimmed)
                if board.items[i].paragraph == true {
                    // Paragraph boxes keep their width; the height follows the text.
                    board.items[i].frame.size.height = Self.textHeight(trimmed, size: size, width: board.items[i].frame.width)
                } else {
                    board.items[i].frame.size = CGSize(width: ceil(measured.width) + size * 0.5, height: ceil(measured.height) + size * 0.3)
                }
                board.items[i].fontSize = size
            }
        }
    }

    // MARK: Captions

    static let captionSize: CGFloat = 15
    static let captionGap: CGFloat = 8

    static func captionHeight(_ text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: captionSize)
        return ceil((text as NSString).boundingRect(with: CGSize(width: max(width, 10), height: 100_000), options: [.usesLineFragmentOrigin],
                                                     attributes: [.font: font]).height) + 4
    }

    /// Where an image's caption sits on the board, if it has one.
    private func captionRect(_ item: BoardItem) -> CGRect? {
        guard case .image = item.kind, let caption = item.caption, !caption.isEmpty else { return nil }
        return CGRect(x: item.frame.minX, y: item.frame.maxY + Self.captionGap, width: item.frame.width,
                      height: Self.captionHeight(caption, width: item.frame.width))
    }

    func editCaption(_ item: BoardItem) {
        let caption = item.caption ?? ""
        let height = max(Self.captionHeight(caption.isEmpty ? "Caption" : caption, width: item.frame.width), Self.captionSize * 1.6)
        let rect = CGRect(x: item.frame.minX, y: item.frame.maxY + Self.captionGap, width: max(item.frame.width, 160), height: height)
        beginEditing(text: caption, world: rect, fontSize: Self.captionSize, multiline: true, weight: .regular) { [weak self] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.store.updateBoard(trimmed.isEmpty ? "Remove Caption" : "Edit Caption") { board in
                if let i = board.items.firstIndex(where: { $0.id == item.id }) { board.items[i].caption = trimmed.isEmpty ? nil : trimmed }
            }
        }
    }

    // MARK: Eyedropper tool

    /// Colors waiting for Pigment to apply, so quick clicks keep adding instead of overwriting each other.
    private var pendingColors: [UUID: [String]] = [:]

    private func sample(at p: CGPoint) {
        let w = toWorld(p)
        guard let board = store.currentBoard, let item = board.items.reversed().first(where: { $0.frame.contains(w) }) else {
            ui.show("Click an image to sample a color")
            return
        }
        var hex: String?
        switch item.kind {
        case .image:
            if let image = itemLayers[item.id]?.contents.map({ $0 as! CGImage }) {
                let x = Int((w.x - item.frame.minX) / item.frame.width * CGFloat(image.width))
                let y = Int((w.y - item.frame.minY) / item.frame.height * CGFloat(image.height))
                hex = Self.pixelHex(image, x: x, y: y)
            }
        case .palette(let id):
            if let palette = palettes.palette(id) { hex = paletteColor(at: w, item: item, palette: palette)?.hex }
        default:
            break
        }
        guard let hex else { return }
        addSampled(hex, near: item)
    }

    private func addSampled(_ hex: String, near item: BoardItem) {
        guard let project = store.currentProject, let board = store.currentBoard else { return }
        // Target: the selected palette card, else the one the eyedropper has been filling, else a new one.
        let selectedPalette = board.items.first { selection.contains($0.id) && isPalette($0) }.flatMap { item -> UUID? in
            if case .palette(let id) = item.kind { return id }
            return nil
        }
        let onBoard = Set(board.items.compactMap { item -> UUID? in
            if case .palette(let id) = item.kind { return id }
            return nil
        })
        if let target = selectedPalette ?? ui.activePaletteID.flatMap({ onBoard.contains($0) ? $0 : nil }) {
            var colors = pendingColors[target] ?? palettes.palette(target)?.colors.map(\.hex) ?? []
            guard !colors.contains(hex) else { ui.show("\(hex) is already in that palette"); return }
            colors.append(hex)
            pendingColors[target] = colors
            palettes.upsert(id: target, colors: colors)
            ui.activePaletteID = target
            ui.show("Added \(hex) to \(palettes.palette(target)?.name ?? "palette")")
        } else {
            let id = UUID()
            let count = palettes.palettes.filter { $0.projectID == project.id }.count
            palettes.upsert(id: id, name: "\(project.name) \(count + 1)", colors: [hex], project: project)
            pendingColors[id] = [hex]
            ui.activePaletteID = id
            let card = BoardItem(id: UUID(), kind: .palette(id), frame: CGRect(x: item.frame.maxX + 24, y: item.frame.minY, width: 300, height: 116))
            store.updateBoard("New Palette") { $0.items.append(card) }
            ui.show("New palette with \(hex) — keep clicking to add colors")
        }
    }

    private static func pixelHex(_ image: CGImage, x: Int, y: Int) -> String? {
        guard (0..<image.width).contains(x), (0..<image.height).contains(y),
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }

    // MARK: Inline text editing (notes, section names)

    private var editorWorldFrame: CGRect = .zero
    private var editorFontSize: CGFloat = 15
    private var editorWeight: NSFont.Weight = .regular

    private func editNote(_ item: BoardItem, text: String) {
        beginEditing(text: text, world: item.frame.insetBy(dx: 8, dy: 6), fontSize: 15, multiline: true, cancel: { [weak self] in
            // Cancelling a brand-new note removes it.
            if text.isEmpty { self?.store.updateBoard("Remove Note") { $0.items.removeAll { $0.id == item.id } } }
        }) { [weak self] newText in
            guard let self else { return }
            let font = NSFont.systemFont(ofSize: 15)
            let height = (newText as NSString).boundingRect(with: CGSize(width: item.frame.width - 24, height: 10_000),
                                                           options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
            self.store.updateBoard("Edit Note") { board in
                guard let i = board.items.firstIndex(where: { $0.id == item.id }) else { return }
                board.items[i].kind = .note(newText)
                board.items[i].frame.size.height = max(60, ceil(height) + 26)
            }
        }
    }

    private func renameSection(_ section: Section) {
        let size = sectionTitleSize
        let header = CGRect(x: section.frame.minX + size * 0.4, y: section.frame.minY + size * 0.2,
                            width: min(section.frame.width - size * 0.8, size * 18), height: size * 1.5)
        beginEditing(text: section.name, world: header, fontSize: size, multiline: false, weight: .bold) { [weak self] name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.store.updateBoard("Rename Section") { board in
                if let i = board.sections.firstIndex(where: { $0.id == section.id }) { board.sections[i].name = trimmed }
            }
        }
    }

    private func beginEditing(text: String, world: CGRect, fontSize: CGFloat, multiline: Bool,
                              weight: NSFont.Weight? = nil, cancel: (() -> Void)? = nil, commit: @escaping (String) -> Void) {
        endEditing()
        let tv = EditorTextView(frame: toView(world))
        tv.string = text
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(white: 0.1, alpha: 0.95)
        tv.textColor = .white
        tv.insertionPointColor = .white
        let fontWeight = weight ?? (multiline ? .regular : .semibold)
        tv.font = .systemFont(ofSize: fontSize * camera.zoom, weight: fontWeight)
        tv.textContainerInset = NSSize(width: 2, height: 2)
        tv.delegate = self
        tv.singleLine = !multiline
        tv.onCommit = { [weak self] in self?.endEditing(commit: true, backToMove: true) }
        tv.onCancel = { [weak self] in self?.endEditing(commit: false, backToMove: true) }
        tv.wantsLayer = true
        tv.layer?.cornerRadius = 6
        addSubview(tv)
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        let bar = EditBar(commit: { [weak self] in self?.endEditing(commit: true, backToMove: true) },
                          cancel: { [weak self] in self?.endEditing(commit: false, backToMove: true) })
        addSubview(bar)
        editBar = bar
        editor = tv
        editorCommit = commit
        editorCancel = cancel
        editorWorldFrame = world
        editorFontSize = fontSize
        editorWeight = fontWeight
        placeEditBar()
    }

    private var editBar: EditBar?
    private var editorCancel: (() -> Void)?

    private func moveEditorWithCamera() {
        guard let editor else { return }
        editor.frame = toView(editorWorldFrame)
        editor.font = .systemFont(ofSize: editorFontSize * camera.zoom, weight: editorWeight)
        placeEditBar()
    }

    /// Just above the text being edited (below it if there's no room), like Photoshop's ✓ / ⊘.
    private func placeEditBar() {
        guard let editor, let editBar else { return }
        let size = editBar.frame.size
        var y = editor.frame.minY - size.height - 6
        if y < 6 { y = editor.frame.maxY + 6 }
        let x = min(max(editor.frame.minX, 6), bounds.width - size.width - 6)
        editBar.setFrameOrigin(CGPoint(x: x, y: y))
    }

    /// Commits (✓, ⌘Return, clicking elsewhere) or cancels (✕, Esc) the edit in progress.
    func endEditing(commit shouldCommit: Bool = true, backToMove: Bool = false) {
        guard let editor else { return }
        let text = editor.string
        let commit = editorCommit, cancel = editorCancel
        self.editor = nil
        editorCommit = nil
        editorCancel = nil
        editor.removeFromSuperview()
        editBar?.removeFromSuperview()
        editBar = nil
        window?.makeFirstResponder(self)
        if shouldCommit { commit?(text) } else { cancel?() }
        if backToMove { ui.tool = .move }
    }

    func textDidEndEditing(_ notification: Notification) { endEditing() }

    // MARK: Context menus

    override func menu(for event: NSEvent) -> NSMenu? {
        endEditing()
        let p = point(event)
        let w = toWorld(p)
        let menu = NSMenu()
        guard let board = store.currentBoard else { return nil }
        switch hit(p) {
        case .item(let id):
            if !selection.contains(id) { selection = [id] }
            guard let item = board.items.first(where: { $0.id == id }) else { return nil }
            switch item.kind {
            case .image(let assetID):
                if PaletteLibrary.pigmentInstalled {
                    menu.addItem(MenuAction("Make Palette from Image") { [weak self] in self?.makePalette(fromImageItem: item) })
                }
                let hasCaption = !(item.caption ?? "").isEmpty
                menu.addItem(MenuAction(hasCaption ? "Edit Caption" : "Add Caption") { [weak self] in self?.editCaption(item) })
                if hasCaption {
                    menu.addItem(MenuAction("Remove Caption") { [weak self] in
                        self?.store.updateBoard("Remove Caption") { b in
                            if let i = b.items.firstIndex(where: { $0.id == item.id }) { b.items[i].caption = nil }
                        }
                    })
                }
                menu.addItem(.separator())
                if let project = store.currentProject, let asset = project.asset(assetID) {
                    let url = store.imageURL(asset, in: project)
                    menu.addItem(MenuAction("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                    if let source = asset.sourceURL, let link = URL(string: source) {
                        menu.addItem(MenuAction("Open Source Page") { NSWorkspace.shared.open(link) })
                    }
                    menu.addItem(MenuAction("Copy Image") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL])
                        if let image = NSImage(contentsOf: url) { NSPasteboard.general.writeObjects([image]) }
                    })
                }
                menu.addItem(MenuAction("Show Info") { [weak self] in self?.ui.rightPanel = .inspector })
            case .palette(let paletteID):
                let palette = palettes.palette(paletteID)
                if let palette {
                    menu.addItem(MenuAction("Copy HEX Codes") { [weak self] in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(palette.colors.map(\.hex).joined(separator: " "), forType: .string)
                        self?.ui.show("Copied \(palette.colors.count) colors")
                    })
                    menu.addItem(MenuAction("Add Color with Eyedropper") { [weak self] in self?.addColor(toPalette: paletteID) })
                    if let hitColor = paletteColor(at: w, item: item, palette: palette), palette.colors.count > 1 {
                        menu.addItem(MenuAction("Remove \(hitColor.hex)") { [weak self] in
                            self?.palettes.upsert(id: paletteID, colors: palette.colors.map(\.hex).filter { $0 != hitColor.hex })
                        })
                    }
                    menu.addItem(MenuAction("Rename Palette…") { [weak self] in self?.promptRename(palette) })
                }
            case .note(let text):
                menu.addItem(MenuAction("Edit Note") { [weak self] in self?.editNote(item, text: text) })
            case .text(let text):
                menu.addItem(MenuAction("Edit Text") { [weak self] in self?.editText(item, text: text) })
            }
            menu.addItem(.separator())
            menu.addItem(MenuAction("Bring to Front  ⇧⌘]") { [weak self] in self?.bringToFront(true) })
            menu.addItem(MenuAction("Send to Back  ⇧⌘[") { [weak self] in self?.bringToFront(false) })
            menu.addItem(MenuAction("Duplicate  ⌘J") { [weak self] in self?.duplicateSelection() })
            menu.addItem(MenuAction("Group into Section  ⌘G") { [weak self] in self?.addSection() })
            menu.addItem(.separator())
            menu.addItem(MenuAction("Remove from Board") { [weak self] in self?.removeSelection() })
        case .section(let id):
            selection = [id]
            guard let section = board.sections.first(where: { $0.id == id }) else { return nil }
            menu.addItem(MenuAction("Rename Section") { [weak self] in self?.renameSection(section) })
            let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, name) in ["Slate", "Coral", "Amber", "Green", "Blue", "Violet"].enumerated() {
                let item = MenuAction(name) { [weak self] in
                    self?.store.updateBoard("Section Color") { b in
                        if let s = b.sections.firstIndex(where: { $0.id == id }) { b.sections[s].colorIndex = i }
                    }
                }
                item.state = section.colorIndex == i ? .on : .off
                sub.addItem(item)
            }
            colors.submenu = sub
            menu.addItem(colors)
            menu.addItem(.separator())
            menu.addItem(MenuAction("Remove Section (keeps its items)") { [weak self] in self?.removeSelection() })
        default:
            menu.addItem(MenuAction("Paste") { [weak self] in self?.importFrom(NSPasteboard.general, at: w) })
            menu.addItem(MenuAction("Add Images…") { [weak self] in self?.chooseImages(at: w) })
            menu.addItem(.separator())
            menu.addItem(MenuAction("New Text  (T)") { [weak self] in self?.addText(at: w) })
            menu.addItem(MenuAction("New Section  (M, or ⌘G around a selection)") { [weak self] in self?.addSection() })
            menu.addItem(.separator())
            menu.addItem(MenuAction("Fit on Screen  ⌘0") { [weak self] in self?.fitAll() })
        }
        return menu
    }

    private func paletteColor(at w: CGPoint, item: BoardItem, palette: PigmentPalette) -> PigmentPalette.Color? {
        let local = CGPoint(x: w.x - item.frame.minX, y: w.y - item.frame.minY)
        let stripWidth = item.frame.width - 20
        guard local.y >= Self.paletteHeader, local.x >= 10, local.x < 10 + stripWidth, !palette.colors.isEmpty else { return nil }
        let index = Int((local.x - 10) / (stripWidth / CGFloat(palette.colors.count)))
        return palette.colors.indices.contains(index) ? palette.colors[index] : nil
    }

    private func promptRename(_ palette: PigmentPalette) {
        let alert = NSAlert()
        alert.messageText = "Rename Palette"
        let field = NSTextField(string: palette.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.palettes.rename(palette.id, to: field.stringValue) }
        }
    }

    // MARK: Importing

    func chooseImages(at w: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .folder]
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                let pb = NSPasteboard(name: NSPasteboard.Name("muse.open"))
                pb.clearContents()
                pb.writeObjects(panel.urls as [NSURL])
                self?.importFrom(pb, at: w)
            }
        }
    }

    func importFrom(_ pasteboard: NSPasteboard, at w: CGPoint) {
        let paletteIDs = Importer.paletteIDs(in: pasteboard)
        if !paletteIDs.isEmpty { addPalettes(paletteIDs, at: w); return }
        ui.show("Adding…")
        Importer.collect(from: pasteboard) { [weak self] incoming in
            self?.place(incoming, at: w)
        }
    }

    func importFile(_ url: URL, sourceURL: String? = nil) {
        place([IncomingImage(file: url, sourceURL: sourceURL)], at: camera.center)
    }

    /// Copies images into the project and lays them out in rows starting at `w`.
    private func place(_ incoming: [IncomingImage], at w: CGPoint) {
        guard !incoming.isEmpty else { ui.show("Nothing to add there"); return }
        var assets: [ImageAsset] = []
        for image in incoming {
            if let asset = store.addImage(copying: image.file, sourceURL: image.sourceURL) { assets.append(asset) }
        }
        guard !assets.isEmpty else { ui.show("Couldn't read those images"); return }
        placeAssets(assets, at: w)
    }

    /// Lays images that are already in the project out in rows starting at `w` (the middle of the view if nil).
    func placeAssets(_ assets: [ImageAsset], at point: CGPoint? = nil) {
        guard !assets.isEmpty else { return }
        let w = point ?? camera.center
        let gap: CGFloat = 14
        var x = w.x, y = w.y, rowHeight: CGFloat = 0, column = 0
        var items: [BoardItem] = []
        for asset in assets {
            // Retina pixels shown at their natural size, but nothing bigger than 560 on its long side.
            let natural = CGSize(width: CGFloat(asset.pixelWidth) / 2, height: CGFloat(asset.pixelHeight) / 2)
            let scale = min(1, 560 / max(natural.width, natural.height))
            let size = CGSize(width: max(natural.width * scale, 40), height: max(natural.height * scale, 40))
            if column == 5 { x = w.x; y += rowHeight + gap; rowHeight = 0; column = 0 }
            items.append(BoardItem(id: UUID(), kind: .image(asset.id), frame: CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
            column += 1
        }
        if items.count == 1 { items[0].frame.origin = CGPoint(x: w.x - items[0].frame.width / 2, y: w.y - items[0].frame.height / 2) }
        store.updateBoard(items.count == 1 ? "Add Image" : "Add Images") { $0.items.append(contentsOf: items) }
        selection = Set(items.map(\.id))
        ui.show(items.count == 1 ? "Added image" : "Added \(items.count) images")
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let types = (pb.types ?? []).prefix(20).map(\.rawValue)
        Log.write("drag entered from \(sender.draggingSource == nil ? "another app" : "Muse"): " + types.joined(separator: ", "))
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if ui.showingLibrary {
            // Dropped on the Library: keep the images in the project without placing them on a board.
            Importer.collect(from: sender.draggingPasteboard) { [weak self] incoming in
                guard let self else { return }
                let added = incoming.compactMap { self.store.addImage(copying: $0.file, sourceURL: $0.sourceURL) }
                self.ui.libraryAllProjects = false
                self.ui.show(added.count == 1 ? "Added 1 image to the library" : "Added \(added.count) images to the library")
            }
            return true
        }
        let w = toWorld(convert(sender.draggingLocation, from: nil))
        importFrom(sender.draggingPasteboard, at: w)
        return true
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Text editing on the canvas: Return finishes single-line edits, Escape always finishes.
/// Text editing on the canvas: Esc cancels; ⌘Return (or Return for single-line names) commits.
final class EditorTextView: NSTextView {
    var singleLine = false
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53 {
            onCancel?()
        } else if isReturn && (singleLine || event.modifierFlags.contains(.command)) {
            onCommit?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The ✓ / ✕ pill shown while editing text.
final class EditBar: NSVisualEffectView {
    private let commitAction: () -> Void
    private let cancelAction: () -> Void

    init(commit: @escaping () -> Void, cancel: @escaping () -> Void) {
        commitAction = commit
        cancelAction = cancel
        super.init(frame: NSRect(x: 0, y: 0, width: 66, height: 30))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        let check = button("checkmark", tint: .labelColor, help: "Commit (⌘↩)", action: #selector(commitTapped))
        check.frame = NSRect(x: 4, y: 3, width: 28, height: 24)
        let cross = button("xmark", tint: .secondaryLabelColor, help: "Cancel (Esc)", action: #selector(cancelTapped))
        cross.frame = NSRect(x: 34, y: 3, width: 28, height: 24)
        addSubview(check)
        addSubview(cross)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, tint: NSColor, help: String, action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!.withSymbolConfiguration(config)!,
                         target: self, action: action)
        b.isBordered = false
        b.contentTintColor = tint
        b.toolTip = help
        b.refusesFirstResponder = true // clicking it mustn't end the edit before the button decides how
        return b
    }

    @objc private func commitTapped() { commitAction() }
    @objc private func cancelTapped() { cancelAction() }
}

// MARK: - Quick Look (Library)

/// Space in the Library opens the selected images in Quick Look, like Finder.
extension CanvasView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var quickLookURLs: [URL] {
        ui.librarySelection.compactMap { ref in
            guard let project = store.projects.first(where: { $0.id == ref.projectID }), let asset = project.asset(ref.assetID) else { return nil }
            return store.imageURL(asset, in: project)
        }
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !quickLookURLs.isEmpty {
            window?.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { quickLookURLs[index] as NSURL }
    }

    /// Arrow keys inside the Quick Look window move through the Library too.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        return MainActor.assumeIsolated {
            guard [123, 124, 125, 126].contains(event.keyCode) else { return false }
            return LibraryView.handleKey(event, store: store, ui: ui, canvas: self)
        }
    }
}
