import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image file ready to be copied into a project, and where it came from.
struct IncomingImage {
    var file: URL
    var sourceURL: String?
}

/// Turns drops and pastes (Finder files and folders, browser and Pinterest drags, raw image data) into image files.
enum Importer {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                                           NSPasteboard.PasteboardType("org.webmproject.webp"),
                                                           NSPasteboard.PasteboardType("public.heic")]

    /// Browsers put links, pages and images on a drag in many forms; accept all of them and sort it out on drop.
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        let extra = ["public.url", "public.url-name", "public.utf8-plain-text", "public.plain-text", "public.text",
                     "public.html", "public.rtf", "com.apple.flat-rtfd", "com.apple.webarchive", "public.image", "public.data",
                     "public.item", "public.content", "public.jpeg", "public.png", "public.tiff", "com.compuserve.gif",
                     "org.webmproject.webp", "public.avif", "WebURLsWithTitlesPboardType", "Apple URL pasteboard type",
                     "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type",
                     "com.apple.NSFilePromiseItemMetaData", "NSPromiseContentsPboardType", "org.chromium.web-custom-data",
                     "org.chromium.chromium-renderer-initiated-drag", "com.google.chrome.private.web-custom-data"]
        return [.fileURL, .URL, .string, .html, .rtf, .tiff, .png] + imageTypes
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + extra.map { NSPasteboard.PasteboardType($0) }
    }

    /// Pigment palette ids carried by a drag, if that's what it is.
    static func paletteIDs(in pasteboard: NSPasteboard) -> [UUID] {
        let strings = (pasteboard.readObjects(forClasses: [NSString.self]) as? [String]) ?? []
        return strings.compactMap { s in
            s.hasPrefix(PaletteLibrary.dragPrefix) ? UUID(uuidString: String(s.dropFirst(PaletteLibrary.dragPrefix.count))) : nil
        }
    }

    /// Reads everything the pasteboard offers. Must be called while a drop's pasteboard is still valid: it reads
    /// what it needs (and starts receiving promised files) right away, then tries each source in turn until one
    /// gives real images.
    static func collect(from pasteboard: NSPasteboard, completion: @escaping @MainActor ([IncomingImage]) -> Void) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Muse-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let webURLs = ((pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []).filter { !$0.isFileURL }
        let strings = (pasteboard.readObjects(forClasses: [NSString.self]) as? [String]) ?? []
        let pageURL = webURLs.first ?? strings.compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first { $0.scheme?.hasPrefix("http") == true }
        let html = pasteboard.string(forType: .html)
        let imgSrc = html.flatMap(firstImageSource).flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL }
        let rawImage = pasteboard.availableType(from: imageTypes).flatMap { type in pasteboard.data(forType: type).map { (type, $0) } }
        let promises = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        // Sites with their own drag code (Pinterest) leave only private data; keep all of it as text to search.
        let blob = (pasteboard.types ?? []).compactMap { pasteboard.data(forType: $0) }.map(lenientText).joined(separator: "\n")
        let hidden = hiddenPinterest(in: blob)

        Log.write("drop types: \(pasteboard.types?.map(\.rawValue).prefix(14) ?? []) | page: \(pageURL?.host ?? "-") | img: \(imgSrc?.host ?? "-") | files: \(files.count) | promises: \(promises.count) | raw: \(rawImage?.0.rawValue ?? "-")")

        // Finder: files, and whole folders of images. Images inside "files" that are really links (.webloc) are skipped.
        let finderImages = files.flatMap(expandFolder)
        if !finderImages.isEmpty {
            Task { @MainActor in completion(finderImages.map { IncomingImage(file: $0, sourceURL: nil) }) }
            return
        }
        let promised = promises.isEmpty ? nil : startReceiving(promises, into: temp)

        Task {
            let source = pageURL?.absoluteString ?? imgSrc?.absoluteString
            func done(_ urls: [URL]) async -> Bool {
                guard !urls.isEmpty else { return false }
                await MainActor.run { completion(urls.map { IncomingImage(file: $0, sourceURL: source) }) }
                return true
            }

            // 1. Pinterest image addresses: fetch the full-size original instead of the grid thumbnail.
            for candidate in [imgSrc, pageURL].compactMap({ $0 }) where candidate.host?.contains("pinimg.com") == true {
                if let file = await download(bestPinterestURLs(for: candidate), to: temp), await done([file]) { return }
            }
            // 2. Image data handed over directly (Safari, copied images).
            if let (type, data) = rawImage {
                let ext = type == .tiff ? "png" : (UTType(type.rawValue)?.preferredFilenameExtension ?? "png")
                let file = temp.appendingPathComponent("image").appendingPathExtension(ext)
                let written = type == .tiff ? writePNG(fromTIFF: data, to: file) : ((try? data.write(to: file)) != nil)
                if written, await done([file]) { return }
            }
            // 3. Promised files (Chrome); link files like .webloc don't count.
            if let promised, await done(await promised.value) { return }
            // 4. A direct image address.
            for candidate in [imgSrc, pageURL].compactMap({ $0 }) where candidate.scheme?.hasPrefix("http") == true {
                if let file = await download([candidate], to: temp), await done([file]) { return }
            }
            // 5. Pinterest's own drag: an image address or pin id buried in its private data.
            if let image = hidden.image, let file = await download(bestPinterestURLs(for: image), to: temp), await done([file]) { return }
            if let pin = hidden.pin, let image = await pageImage(pin) {
                let tries = image.host?.contains("pinimg.com") == true ? bestPinterestURLs(for: image) : [image]
                if let file = await download(tries, to: temp), await done([file]) { return }
            }
            // 6. A web page (a Pinterest pin, an article…): use the image it advertises for link previews.
            if let page = pageURL, page.scheme?.hasPrefix("http") == true, let image = await pageImage(page) {
                let tries = image.host?.contains("pinimg.com") == true ? bestPinterestURLs(for: image) : [image]
                if let file = await download(tries, to: temp), await done([file]) { return }
            }
            Log.write("drop gave no images")
            await MainActor.run { completion([]) }
        }
    }

    // MARK: Helpers

    static func expandFolder(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return isImage(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var found: [URL] = []
        while let next = walker?.nextObject() as? URL {
            if isImage(next) { found.append(next) }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func isImageAddress(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"].contains(url.pathExtension.lowercased())
    }

    private static func firstImageSource(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<img[^>]+src\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Pinterest serves sizes like /236x/ or /736x/; /originals/ is the full image when it exists.
    static func bestPinterestURLs(for url: URL) -> [URL] {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        // The first path segment is the size: "236x", "736x", "200x150", "originals"…
        guard let first = parts.first, first == "originals" || first.range(of: #"^\d+x\d*$"#, options: .regularExpression) != nil else { return [url] }
        let rest = parts.dropFirst().joined(separator: "/")
        return ["originals", "1200x", "736x"].compactMap { size in
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.path = "/\(size)/\(rest)"
            return c?.url
        } + [url]
    }

    /// Tries each address in order and keeps the first one that is a real image.
    static func download(_ urls: [URL], to dir: URL) async -> URL? {
        // Apps may only load https, so plain http addresses are tried over https.
        let secure = urls.compactMap { url -> URL? in
            guard url.scheme == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            c.scheme = "https"
            return c.url
        }
        for url in secure {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { continue }
            let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
            let base = Store.cleanBase(url.deletingPathExtension().lastPathComponent)
            let file = Store.unique(dir, base: base, ext: type?.preferredFilenameExtension ?? "jpg")
            if (try? data.write(to: file)) != nil { return file }
        }
        return nil
    }

    private static func writePNG(fromTIFF data: Data, to url: URL) -> Bool {
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Starts receiving now (while the drop is valid) and hands back a task that finishes with the image files.
    private static func startReceiving(_ promises: [NSFilePromiseReceiver], into dir: URL) -> Task<[URL], Never> {
        let group = DispatchGroup()
        let lock = NSLock()
        nonisolated(unsafe) var files: [URL] = []
        let queue = OperationQueue()
        for promise in promises {
            var remaining = max(1, promise.fileNames.count)
            for _ in 0..<remaining { group.enter() }
            promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                lock.lock()
                if error == nil, isImage(url) { files.append(url) }
                let leave = remaining > 0
                remaining -= 1
                lock.unlock()
                if leave { group.leave() }
            }
        }
        return Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
                group.notify(queue: .global()) {
                    lock.lock()
                    let result = files
                    lock.unlock()
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Text from pasteboard data in whatever encoding it happens to be (UTF-8, UTF-16, or bytes with binary framing).
    static func lenientText(_ data: Data) -> String {
        let utf8 = String(decoding: data, as: UTF8.self)
        if utf8.contains("http") || utf8.contains("pin") { return utf8 }
        let utf16 = String(decoding: data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }, as: UTF16.self)
        return utf16.contains("http") ? utf16 : utf8
    }

    /// A Pinterest image address (i.pinimg.com/…) or pin page found anywhere in some text.
    static func hiddenPinterest(in text: String) -> (image: URL?, pin: URL?) {
        let cleaned = text.replacingOccurrences(of: "\\/", with: "/")
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) else { return nil }
            let r = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            return Range(r, in: cleaned).map { String(cleaned[$0]) }
        }
        let image = first(#"https?://i\.pinimg\.com/[A-Za-z0-9_]+/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]+\.(?:jpg|jpeg|png|webp|gif)"#)
            .flatMap(URL.init(string:))
        let pinID = first(#"/pin/(\d{6,})"#) ?? first(#""(?:pinId|pin_id|pinID|entityId|id)"\s*:\s*"(\d{8,})""#)
        let pin = pinID.flatMap { URL(string: "https://www.pinterest.com/pin/\($0)/") }
        return (image, pin)
    }

    /// The image a page advertises for link previews (og:image / twitter:image).
    static func pageImage(_ page: URL) async -> URL? {
        var secure = URLComponents(url: page, resolvingAgainstBaseURL: false)
        if secure?.scheme == "http" { secure?.scheme = "https" }
        var request = URLRequest(url: secure?.url ?? page)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let patterns = [
            #"<meta[^>]+(?:property|name)\s*=\s*["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["'][^>]*content\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*(?:property|name)\s*=\s*["'](?:og:image|twitter:image)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let address = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: address, relativeTo: page)?.absoluteURL { return url }
        }
        return nil
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}
