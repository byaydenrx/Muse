import AppKit
import CoreText

/// Turns a board into a layered PSD, structured like the Layers panel: a "Board" background, one group per
/// section (frame, title, then its items), then loose items on top. Palettes become groups with one filled
/// layer per color.
enum PSDExport {
    /// What one layer draws. Everything is in board coordinates; rendering scales it.
    private enum Paint {
        case image(URL)
        case fill(NSColor, radius: CGFloat, stroke: NSColor? = nil, strokeWidth: CGFloat = 0)
        case text(String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false, centered: Bool = false)
        case stack([(CGRect, Paint)]) // several paints in one layer, rects relative to the layer
    }

    private indirect enum Node {
        case layer(name: String, hidden: Bool, rect: CGRect, paint: Paint)
        case group(name: String, hidden: Bool, children: [Node]) // children bottom to top
    }

    static let boardColor = NSColor(white: 0.115, alpha: 1)

    struct Result { let layers: Int; let width: Int; let height: Int }

    /// Reads the board on the main thread, then renders and writes in the background.
    @MainActor
    static func export(board: Board, project: Project, store: Store, palettes: PaletteLibrary, to url: URL) async throws -> Result {
        let plan = makePlan(board: board, project: project, store: store, palettes: palettes)
        return try await Task.detached(priority: .userInitiated) {
            try render(plan.nodes, bounds: plan.bounds, to: url)
        }.value
    }

    // MARK: Plan (main thread)

    @MainActor
    private static func makePlan(board: Board, project: Project, store: Store, palettes: PaletteLibrary) -> (nodes: [Node], bounds: CGRect) {
        let tree = LayerTree(board)
        var rects = board.items.map(\.frame) + board.sections.map(\.frame)
        for item in board.items {
            if let caption = item.caption, !caption.isEmpty {
                rects.append(CGRect(x: item.frame.minX, y: item.frame.maxY, width: item.frame.width,
                                    height: CanvasView.captionGap + CanvasView.captionHeight(caption, width: item.frame.width)))
            }
        }
        var bounds = rects.first ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        rects.dropFirst().forEach { bounds = bounds.union($0) }
        bounds = bounds.insetBy(dx: -40, dy: -40)

        var nodes: [Node] = [.layer(name: "Board", hidden: false, rect: bounds, paint: .fill(boardColor, radius: 0))]
        for (section, items) in tree.groups {
            let color = SectionColors.all[section.colorIndex % SectionColors.all.count]
            var children: [Node] = [
                .layer(name: "Frame", hidden: false, rect: section.frame,
                       paint: .fill(color.withAlphaComponent(0.07), radius: 14, stroke: color.withAlphaComponent(0.55), strokeWidth: 1.5)),
                .layer(name: "Title", hidden: false,
                       rect: CGRect(x: section.frame.minX + 16.8, y: section.frame.minY + 9.8, width: section.frame.width - 33.6, height: 40),
                       paint: .text(section.name, size: 28, weight: .bold, color: color)),
            ]
            children += items.flatMap { nodesFor($0, project: project, store: store, palettes: palettes) }
            nodes.append(.group(name: section.name, hidden: section.hidden == true, children: children))
        }
        nodes += tree.loose.flatMap { nodesFor($0, project: project, store: store, palettes: palettes) }
        return (nodes, bounds)
    }

    @MainActor
    private static func nodesFor(_ item: BoardItem, project: Project, store: Store, palettes: PaletteLibrary) -> [Node] {
        let name = item.layerName(project: project, palettes: palettes)
        let hidden = item.hidden == true
        let f = item.frame
        switch item.kind {
        case .image(let id):
            guard let asset = project.asset(id) else { return [] }
            var nodes: [Node] = [.layer(name: name, hidden: hidden, rect: f, paint: .image(store.imageURL(asset, in: project)))]
            if let caption = item.caption, !caption.isEmpty {
                let rect = CGRect(x: f.minX, y: f.maxY + CanvasView.captionGap, width: f.width,
                                  height: CanvasView.captionHeight(caption, width: f.width) + 4)
                nodes.append(.layer(name: "\(name) caption", hidden: hidden, rect: rect,
                                    paint: .text(caption, size: CanvasView.captionSize, weight: .regular, color: NSColor(white: 0.62, alpha: 1))))
            }
            return nodes
        case .text(let text):
            let size = item.fontSize ?? CanvasView.textSize
            return [.layer(name: name, hidden: hidden, rect: f.insetBy(dx: 0, dy: -size * 0.2),
                           paint: .text(text, size: size, weight: .semibold, color: .white))]
        case .note(let text):
            let card = Paint.fill(NSColor(white: 0.17, alpha: 1), radius: 12, stroke: NSColor(white: 1, alpha: 0.1), strokeWidth: 1)
            let words = Paint.text(text, size: 15, weight: .regular, color: .white)
            return [.layer(name: name, hidden: hidden, rect: f,
                           paint: .stack([(CGRect(origin: .zero, size: f.size), card),
                                          (CGRect(x: 12, y: 10, width: f.width - 24, height: f.height - 20), words)]))]
        case .palette(let id):
            guard let palette = palettes.palette(id) else { return [] }
            var children: [Node] = [
                .layer(name: "Card", hidden: false, rect: f,
                       paint: .fill(NSColor(white: 0.17, alpha: 1), radius: 12, stroke: NSColor(white: 1, alpha: 0.1), strokeWidth: 1)),
                .layer(name: "Title", hidden: false, rect: CGRect(x: f.minX + 12, y: f.minY + 9, width: f.width - 24, height: 22),
                       paint: .text(palette.name, size: 13, weight: .semibold, color: .white)),
            ]
            // Same geometry as the card on the board.
            let labels: CGFloat = f.height > 96 ? 16 : 0
            let strip = CGRect(x: f.minX + 10, y: f.minY + CanvasView.paletteHeader, width: f.width - 20,
                               height: f.height - CanvasView.paletteHeader - 10 - labels)
            let w = strip.width / CGFloat(max(palette.colors.count, 1))
            var labelPaints: [(CGRect, Paint)] = []
            for (i, c) in palette.colors.enumerated() {
                let r = CGRect(x: strip.minX + CGFloat(i) * w, y: strip.minY, width: w, height: strip.height)
                children.append(.layer(name: [c.name, c.hex].compactMap { $0 }.joined(separator: " "), hidden: false, rect: r,
                                       paint: .fill(c.nsColor, radius: 0)))
                if labels > 0 && w >= 46 {
                    labelPaints.append((CGRect(x: CGFloat(i) * w, y: 0, width: w, height: 14),
                                        .text(c.hex, size: 9.5, weight: .medium, color: NSColor(white: 0.62, alpha: 1), mono: true, centered: true)))
                }
            }
            if !labelPaints.isEmpty {
                children.append(.layer(name: "HEX labels", hidden: false, rect: CGRect(x: strip.minX, y: strip.maxY + 3, width: strip.width, height: 14),
                                       paint: .stack(labelPaints)))
            }
            return [.group(name: name, hidden: hidden, children: children)]
        }
    }

    // MARK: Rendering (background)

    private static func render(_ nodes: [Node], bounds: CGRect, to url: URL) throws -> Result {
        // 2 pixels per board point (images placed at their natural size keep full resolution), at most 12000 px.
        let scale = min(2, 12_000 / max(bounds.width, bounds.height))
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let composite = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError("Not enough memory for the canvas") }
        composite.interpolationQuality = .high

        var layers: [PSDLayer] = []
        func walk(_ nodes: [Node], visible: Bool) {
            for node in nodes {
                switch node {
                case .layer(let name, let hidden, let rect, let paint):
                    var layer = PSDLayer(name: name, kind: .pixels, hidden: hidden)
                    let left = Int(((rect.minX - bounds.minX) * scale).rounded(.down)), top = Int(((rect.minY - bounds.minY) * scale).rounded(.down))
                    let right = Int(((rect.maxX - bounds.minX) * scale).rounded(.up)), bottom = Int(((rect.maxY - bounds.minY) * scale).rounded(.up))
                    layer.left = max(left, 0); layer.top = max(top, 0)
                    layer.width = min(right, width) - layer.left; layer.height = min(bottom, height) - layer.top
                    if layer.width > 0, layer.height > 0, let image = draw(paint, rect: rect, layer: layer, bounds: bounds, scale: scale) {
                        layer.rgba = unpremultiplied(image, width: layer.width, height: layer.height)
                        if visible && !hidden {
                            composite.draw(image, in: CGRect(x: layer.left, y: height - layer.top - layer.height, width: layer.width, height: layer.height))
                        }
                    } else {
                        layer.width = 0; layer.height = 0
                    }
                    layers.append(layer)
                case .group(let name, let hidden, let children):
                    layers.append(PSDLayer(name: "</Layer group>", kind: .groupEnd))
                    walk(children, visible: visible && !hidden)
                    layers.append(PSDLayer(name: name, kind: .groupStart(open: true), hidden: hidden))
                }
            }
        }
        walk(nodes, visible: true)

        guard let flat = composite.makeImage() else { throw ExportError("Couldn't flatten the board") }
        let rgba = unpremultiplied(flat, width: width, height: height)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        try PSDWriter.write(width: width, height: height, layers: layers, composite: rgb, to: url)
        return Result(layers: layers.filter { if case .pixels = $0.kind { return true }; return false }.count, width: width, height: height)
    }

    /// Draws one layer into its own bitmap (the size of its pixel rect).
    private static func draw(_ paint: Paint, rect: CGRect, layer: PSDLayer, bounds: CGRect, scale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: layer.width, height: layer.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Board rect → this bitmap's pixels (CG has y going up).
        let origin = CGPoint(x: (rect.minX - bounds.minX) * scale - CGFloat(layer.left), y: (rect.minY - bounds.minY) * scale - CGFloat(layer.top))
        let local = CGRect(x: origin.x, y: CGFloat(layer.height) - origin.y - rect.height * scale, width: rect.width * scale, height: rect.height * scale)
        paintInto(ctx, paint, local, scale: scale)
        return ctx.makeImage()
    }

    private static func paintInto(_ ctx: CGContext, _ paint: Paint, _ r: CGRect, scale: CGFloat) {
        switch paint {
        case .image(let url):
            if let image = ImageCache.decode(url, maxPixels: Int(max(r.width, r.height).rounded(.up))) { ctx.draw(image, in: r) }
        case .fill(let color, let radius, let stroke, let strokeWidth):
            let path = CGPath(roundedRect: r, cornerWidth: radius * scale, cornerHeight: radius * scale, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            if let stroke, strokeWidth > 0 {
                let inset = strokeWidth * scale / 2
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: inset, dy: inset), cornerWidth: max(radius * scale - inset, 0),
                                   cornerHeight: max(radius * scale - inset, 0), transform: nil))
                ctx.setStrokeColor(stroke.cgColor)
                ctx.setLineWidth(strokeWidth * scale)
                ctx.strokePath()
            }
        case .text(let string, let size, let weight, let color, let mono, let centered):
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size * scale, weight: weight) : NSFont.systemFont(ofSize: size * scale, weight: weight)
            let style = NSMutableParagraphStyle()
            style.alignment = centered ? .center : .left
            style.lineBreakMode = .byWordWrapping
            let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            let setter = CTFramesetterCreateWithAttributedString(text)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: r, transform: nil), nil)
            CTFrameDraw(frame, ctx)
        case .stack(let parts):
            for (part, paint) in parts {
                let sub = CGRect(x: r.minX + part.minX * scale, y: r.maxY - part.maxY * scale, width: part.width * scale, height: part.height * scale)
                paintInto(ctx, paint, sub, scale: scale)
            }
        }
    }

    private static func unpremultiplied(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return buffer }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let a = Int(buffer[i + 3])
            guard a > 0, a < 255 else { continue }
            buffer[i] = UInt8(min(255, Int(buffer[i]) * 255 / a))
            buffer[i + 1] = UInt8(min(255, Int(buffer[i + 1]) * 255 / a))
            buffer[i + 2] = UInt8(min(255, Int(buffer[i + 2]) * 255 / a))
        }
        return buffer
    }

    struct ExportError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
