import AppKit
import ImageIO

/// Downsampled board images, decoded off the main thread.
@MainActor
enum ImageCache {
    private static var images: [URL: CGImage] = [:]
    private static var waiting: [URL: [(CGImage) -> Void]] = [:]
    private static let queue = DispatchQueue(label: "muse.images", qos: .userInitiated, attributes: .concurrent)

    static func image(_ url: URL, ready: @escaping (CGImage) -> Void) {
        if let hit = images[url] { ready(hit); return }
        if waiting[url] != nil { waiting[url]!.append(ready); return }
        waiting[url] = [ready]
        queue.async {
            let image = decode(url, maxPixels: 2400)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let callbacks = waiting.removeValue(forKey: url) ?? []
                    guard let image else { return }
                    images[url] = image
                    callbacks.forEach { $0(image) }
                }
            }
        }
    }

    nonisolated static func decode(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Muse.log")
    private static let queue = DispatchQueue(label: "muse.log")
    private static var writes = 0

    /// Past 1 MB the log is cut down to its newest 256 KB, so it never keeps growing.
    private static func trim() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(256_000)
        if let newline = tail.firstIndex(of: 10) { tail = tail[(newline + 1)...] }
        try? tail.write(to: url, options: .atomic)
    }

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            writes += 1
            if writes % 200 == 1 { trim() }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
