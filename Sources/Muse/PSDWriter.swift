import Foundation

/// One record in a PSD's layer list. Groups are written the way Photoshop stores them: an end marker below the
/// group's layers and a folder layer above them.
struct PSDLayer {
    enum Kind {
        case pixels
        case groupStart(open: Bool) // the folder (sits above its layers)
        case groupEnd               // the hidden "</Layer group>" marker (sits below them)
    }

    var name: String
    var kind: Kind
    var hidden = false
    /// Position in the document, in pixels.
    var left = 0, top = 0, width = 0, height = 0
    /// Straight (not premultiplied) RGBA, width × height × 4.
    var rgba: [UInt8] = []
}

/// Writes 8-bit RGB Photoshop documents with layers and groups (PackBits-compressed channels).
enum PSDWriter {
    /// `layers` go bottom to top. `composite` is the flattened RGB image Photoshop shows as a preview.
    static func write(width: Int, height: Int, layers: [PSDLayer], composite: [UInt8], to url: URL) throws {
        var out = ByteWriter()

        // Header
        out.ascii("8BPS")
        out.u16(1)
        out.zeros(6)
        out.u16(3)            // channels in the composite
        out.u32(UInt32(height))
        out.u32(UInt32(width))
        out.u16(8)            // bits per channel
        out.u16(3)            // RGB

        out.u32(0)            // color mode data
        out.u32(0)            // image resources

        // Layer and mask information
        var info = ByteWriter()
        info.i16(Int16(layers.count))
        var channelData = ByteWriter()
        for layer in layers {
            let channels = encodeChannels(layer)
            writeRecord(layer, channelLengths: channels.map { UInt32($0.count) }, into: &info)
            channels.forEach { channelData.append($0) }
        }
        info.append(channelData.data)
        if info.data.count % 2 == 1 { info.zeros(1) }

        out.u32(UInt32(4 + info.data.count + 4))
        out.u32(UInt32(info.data.count))
        out.append(info.data)
        out.u32(0)            // global layer mask

        // Composite image, planar R, G, B, RLE: all row byte counts first, then all rows.
        out.u16(1)
        var rows: [[UInt8]] = []
        for c in 0..<3 {
            for y in 0..<height {
                var row = [UInt8](repeating: 0, count: width)
                let base = y * width * 3
                for x in 0..<width { row[x] = composite[base + x * 3 + c] }
                rows.append(packBits(row))
            }
        }
        rows.forEach { out.u16(UInt16($0.count)) }
        rows.forEach { out.bytes($0) }

        try out.data.write(to: url, options: .atomic)
    }

    // MARK: Layer records

    private static func writeRecord(_ layer: PSDLayer, channelLengths: [UInt32], into w: inout ByteWriter) {
        w.i32(Int32(layer.top))
        w.i32(Int32(layer.left))
        w.i32(Int32(layer.top + layer.height))
        w.i32(Int32(layer.left + layer.width))
        let ids: [Int16] = [-1, 0, 1, 2]
        w.u16(UInt16(ids.count))
        for (id, length) in zip(ids, channelLengths) {
            w.i16(id)
            w.u32(length)
        }
        w.ascii("8BIM")
        if case .groupStart = layer.kind { w.ascii("pass") } else { w.ascii("norm") }
        w.u8(255)             // opacity
        w.u8(0)               // clipping
        var flags: UInt8 = layer.hidden ? 0x02 : 0
        if case .pixels = layer.kind {} else { flags |= 0x18 } // group records carry no pixels
        w.u8(flags)
        w.u8(0)

        var extra = ByteWriter()
        extra.u32(0)          // layer mask
        extra.u32(0)          // blending ranges
        extra.pascal(layer.name, padTo: 4)
        // Unicode name, so any characters survive.
        let units = Array(layer.name.utf16)
        var luni = ByteWriter()
        luni.u32(UInt32(units.count))
        units.forEach { luni.u16($0) }
        while luni.data.count % 4 != 0 { luni.zeros(1) }
        extra.block("luni", luni.data)
        switch layer.kind {
        case .groupStart(let open):
            var lsct = ByteWriter()
            lsct.u32(open ? 1 : 2)
            lsct.ascii("8BIM")
            lsct.ascii("pass")
            extra.block("lsct", lsct.data)
        case .groupEnd:
            var lsct = ByteWriter()
            lsct.u32(3)
            extra.block("lsct", lsct.data)
        case .pixels:
            break
        }
        w.u32(UInt32(extra.data.count))
        w.append(extra.data)
    }

    /// Alpha, red, green, blue — each compression flag + row byte counts + PackBits rows.
    private static func encodeChannels(_ layer: PSDLayer) -> [Data] {
        guard case .pixels = layer.kind, layer.width > 0, layer.height > 0 else {
            return Array(repeating: Data([0, 0]), count: 4) // raw, no data
        }
        let order = [3, 0, 1, 2]
        return order.map { c in
            var counts = ByteWriter()
            var body = ByteWriter()
            counts.u16(1)
            var row = [UInt8](repeating: 0, count: layer.width)
            for y in 0..<layer.height {
                let base = y * layer.width * 4
                for x in 0..<layer.width { row[x] = layer.rgba[base + x * 4 + c] }
                let packed = packBits(row)
                counts.u16(UInt16(packed.count))
                body.bytes(packed)
            }
            counts.append(body.data)
            return counts.data
        }
    }

    /// Apple PackBits: runs of a repeated byte, or literal stretches, at most 128 bytes each.
    static func packBits(_ src: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(src.count + src.count / 128 + 2)
        var i = 0
        let n = src.count
        while i < n {
            var run = 1
            while i + run < n && run < 128 && src[i + run] == src[i] { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(src[i])
                i += run
                continue
            }
            // Literal: until a run of 2+ starts or 128 bytes.
            let start = i
            while i < n && i - start < 128 {
                if i + 1 < n && src[i] == src[i + 1] { break }
                i += 1
            }
            if i == start { i += 1 } // a lone byte before a run
            out.append(UInt8(i - start - 1))
            out.append(contentsOf: src[start..<i])
        }
        return out
    }
}

/// Big-endian byte building.
struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { for shift in [24, 16, 8, 0] { data.append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func append(_ d: Data) { data.append(d) }

    /// Length-prefixed MacRoman-ish name, padded so the whole field is a multiple of `padTo`.
    mutating func pascal(_ s: String, padTo: Int) {
        let ascii = Array(s.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(255))
        u8(UInt8(ascii.count))
        bytes(ascii)
        let total = 1 + ascii.count
        let padded = (total + padTo - 1) / padTo * padTo
        zeros(padded - total)
    }

    /// An "additional layer information" block: signature, key, length, data.
    mutating func block(_ key: String, _ body: Data) {
        ascii("8BIM")
        ascii(key)
        u32(UInt32(body.count))
        append(body)
    }
}
