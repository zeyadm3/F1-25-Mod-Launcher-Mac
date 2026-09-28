import Foundation

// MARK: - Pixel formats

/// Texture formats, and the numbers F1 25 uses for them in its surface headers.
enum TextureFormat: Equatable {
    case bc1, bc2, bc3, bc4, bc5, bc6h, bc7, rgba8

    /// Bytes per 4×4 block (or per pixel for rgba8).
    var blockBytes: Int {
        switch self {
        case .bc1, .bc4: return 8
        case .bc2, .bc3, .bc5, .bc6h, .bc7: return 16
        case .rgba8: return 4
        }
    }

    var isBlockCompressed: Bool { self != .rgba8 }

    func levelSize(width: Int, height: Int) -> Int {
        if isBlockCompressed {
            return max(1, (width + 3) / 4) * max(1, (height + 3) / 4) * blockBytes
        }
        return width * height * blockBytes
    }

    func chainSize(width: Int, height: Int, mips: Int) -> Int {
        (0..<mips).reduce(0) { $0 + levelSize(width: max(1, width >> $1), height: max(1, height >> $1)) }
    }

    /// The game's format number. Colour textures that the game stores as sRGB must stay sRGB.
    func gameCode(sRGB: Bool) -> UInt32? {
        switch self {
        case .bc1: return sRGB ? 54 : 52
        case .bc3: return sRGB ? 57 : 55
        case .bc7: return sRGB ? 70 : 69
        case .bc4: return 63
        case .bc5: return 65
        case .bc6h: return 67
        case .rgba8: return sRGB ? nil : 15
        case .bc2: return nil
        }
    }

    /// Reads a game format number: (format, isSRGB).
    static func fromGame(_ code: UInt32) -> (TextureFormat, Bool)? {
        switch code {
        case 52: return (.bc1, false)
        case 54: return (.bc1, true)
        case 55: return (.bc3, false)
        case 57: return (.bc3, true)
        case 69: return (.bc7, false)
        case 70: return (.bc7, true)
        case 63: return (.bc4, false)
        case 65: return (.bc5, false)
        case 67: return (.bc6h, false)
        case 15: return (.rgba8, false)
        default: return nil
        }
    }
}

// MARK: - DDS files

struct DDSImage {
    let format: TextureFormat
    /// nil when the file doesn't say (legacy DDS headers).
    let sRGB: Bool?
    let width: Int
    let height: Int
    let mips: Int
    /// Mip chain, largest first. For rgba8 the bytes are always R, G, B, A.
    let pixels: Data

    enum Failure: Error, LocalizedError {
        case notDDS
        case unsupported(String)
        case truncated

        var errorDescription: String? {
            switch self {
            case .notDDS: return "This isn't a DDS texture."
            case let .unsupported(detail): return "This DDS texture format isn't supported (\(detail)). Save it as BC1, BC3, BC7 or uncompressed RGBA."
            case .truncated: return "The DDS texture is shorter than its header says."
            }
        }
    }

    init(data: Data) throws {
        guard data.count >= 128, data.prefix(4) == Data("DDS ".utf8) else { throw Failure.notDDS }
        let flags = data.u32(at: 8)
        height = Int(data.u32(at: 12))
        width = Int(data.u32(at: 16))
        let mipCount = Int(data.u32(at: 28))
        mips = (flags & 0x20000) != 0 ? max(1, mipCount) : max(1, mipCount == 0 ? 1 : mipCount)
        let pixelFlags = data.u32(at: 80)
        let fourCC = String(decoding: data[(data.startIndex + 84)..<(data.startIndex + 88)], as: UTF8.self)
        let bitCount = data.u32(at: 88)
        let masks = (data.u32(at: 92), data.u32(at: 96), data.u32(at: 100), data.u32(at: 104))
        guard width > 0, height > 0 else { throw Failure.unsupported("empty image") }

        var offset = 128
        var format: TextureFormat
        var sRGB: Bool?
        var swapRedBlue = false
        var dropAlpha = false
        if pixelFlags & 0x4 != 0 && fourCC == "DX10" {
            guard data.count >= 148 else { throw Failure.truncated }
            let dxgi = data.u32(at: 128)
            let arraySize = data.u32(at: 140)
            offset = 148
            guard arraySize <= 1 else { throw Failure.unsupported("texture array") }
            switch dxgi {
            case 70, 71: format = .bc1; sRGB = false
            case 72: format = .bc1; sRGB = true
            case 73, 74: format = .bc2; sRGB = false
            case 75: format = .bc2; sRGB = true
            case 76, 77: format = .bc3; sRGB = false
            case 78: format = .bc3; sRGB = true
            case 79, 80: format = .bc4; sRGB = false
            case 82, 83: format = .bc5; sRGB = false
            case 94, 95: format = .bc6h; sRGB = false
            case 97, 98: format = .bc7; sRGB = false
            case 99: format = .bc7; sRGB = true
            case 27, 28: format = .rgba8; sRGB = false
            case 29: format = .rgba8; sRGB = true
            case 87, 90: format = .rgba8; sRGB = false; swapRedBlue = true
            case 91: format = .rgba8; sRGB = true; swapRedBlue = true
            case 88: format = .rgba8; sRGB = false; swapRedBlue = true; dropAlpha = true
            default: throw Failure.unsupported("DXGI format \(dxgi)")
            }
        } else if pixelFlags & 0x4 != 0 {
            switch fourCC {
            case "DXT1": format = .bc1
            case "DXT2", "DXT3": format = .bc2
            case "DXT4", "DXT5": format = .bc3
            case "ATI1", "BC4U": format = .bc4
            case "ATI2", "BC5U": format = .bc5
            default: throw Failure.unsupported("\(fourCC)")
            }
        } else if pixelFlags & 0x40 != 0 && bitCount == 32 {
            format = .rgba8
            if masks.0 == 0x00FF_0000 && masks.2 == 0x0000_00FF { swapRedBlue = true }
            else if !(masks.0 == 0x0000_00FF && masks.2 == 0x00FF_0000) { throw Failure.unsupported("32-bit channel order") }
            dropAlpha = pixelFlags & 0x1 == 0
        } else if pixelFlags & 0x40 != 0 && bitCount == 24 {
            // 24-bit RGB: expand to RGBA below.
            let (w, h, m) = (width, height, mips)
            let size = (0..<m).reduce(0) { $0 + max(1, w >> $1) * max(1, h >> $1) * 3 }
            guard data.count >= offset + size else { throw Failure.truncated }
            var rgba = Data(count: size / 3 * 4)
            let blueFirst = masks.0 == 0x00FF_0000
            data.withUnsafeBytes { source in
                rgba.withUnsafeMutableBytes { target in
                    for pixel in 0..<(size / 3) {
                        let s = offset + pixel * 3
                        target[pixel * 4] = source[s + (blueFirst ? 2 : 0)]
                        target[pixel * 4 + 1] = source[s + 1]
                        target[pixel * 4 + 2] = source[s + (blueFirst ? 0 : 2)]
                        target[pixel * 4 + 3] = 255
                    }
                }
            }
            self.format = .rgba8
            self.sRGB = nil
            self.pixels = rgba
            return
        } else {
            throw Failure.unsupported("pixel format")
        }

        let size = format.chainSize(width: width, height: height, mips: mips)
        guard data.count >= offset + size else { throw Failure.truncated }
        var pixels = Data(data[(data.startIndex + offset)..<(data.startIndex + offset + size)])
        if format == .rgba8 && (swapRedBlue || dropAlpha) {
            pixels.withUnsafeMutableBytes { buffer in
                for index in stride(from: 0, to: buffer.count, by: 4) {
                    if swapRedBlue { buffer.swapAt(index, index + 2) }
                    if dropAlpha { buffer[index + 3] = 255 }
                }
            }
        }
        self.format = format
        self.sRGB = sRGB
        self.pixels = pixels
    }

    /// Bytes of one mip level.
    func level(_ index: Int) -> (width: Int, height: Int, data: Data) {
        let w = max(1, width >> index), h = max(1, height >> index)
        let start = format.chainSize(width: width, height: height, mips: index)
        let size = format.levelSize(width: w, height: h)
        return (w, h, pixels[(pixels.startIndex + start)..<(pixels.startIndex + start + size)])
    }
}

// MARK: - Block compression

/// Decoders and (simple, fast) encoders for BC1–BC5. Encoded quality is comparable to other
/// real-time DXT encoders; good enough for livery textures.
enum BlockCodec {
    // MARK: Decoding (to RGBA8)

    static func decode(_ data: Data, format: TextureFormat, width: Int, height: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        if format == .rgba8 {
            return [UInt8](data.prefix(width * height * 4))
        }
        guard [.bc1, .bc2, .bc3, .bc4, .bc5].contains(format) else { return nil }
        let blocksX = max(1, (width + 3) / 4), blocksY = max(1, (height + 3) / 4)
        let bytes = [UInt8](data)
        guard bytes.count >= blocksX * blocksY * format.blockBytes else { return nil }
        var block = [UInt8](repeating: 0, count: 64)
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let offset = (by * blocksX + bx) * format.blockBytes
                switch format {
                case .bc1:
                    decodeColor(bytes, offset, into: &block, allowTransparent: true)
                case .bc2:
                    decodeColor(bytes, offset + 8, into: &block, allowTransparent: false)
                    for pixel in 0..<16 {
                        let nibble = (bytes[offset + pixel / 2] >> (pixel % 2 == 0 ? 0 : 4)) & 0xF
                        block[pixel * 4 + 3] = nibble * 17
                    }
                case .bc3:
                    decodeColor(bytes, offset + 8, into: &block, allowTransparent: false)
                    decodeChannel(bytes, offset, into: &block, channel: 3)
                case .bc4:
                    decodeChannel(bytes, offset, into: &block, channel: 0)
                    for pixel in 0..<16 { block[pixel * 4 + 1] = block[pixel * 4]; block[pixel * 4 + 2] = block[pixel * 4]; block[pixel * 4 + 3] = 255 }
                case .bc5:
                    decodeChannel(bytes, offset, into: &block, channel: 0)
                    decodeChannel(bytes, offset + 8, into: &block, channel: 1)
                    for pixel in 0..<16 { block[pixel * 4 + 2] = 0; block[pixel * 4 + 3] = 255 }
                default:
                    return nil
                }
                for y in 0..<4 where by * 4 + y < height {
                    for x in 0..<4 where bx * 4 + x < width {
                        let target = ((by * 4 + y) * width + bx * 4 + x) * 4
                        let source = (y * 4 + x) * 4
                        out[target] = block[source]; out[target + 1] = block[source + 1]
                        out[target + 2] = block[source + 2]; out[target + 3] = block[source + 3]
                    }
                }
            }
        }
        return out
    }

    private static func expand565(_ value: Int) -> (Int, Int, Int) {
        let r = (value >> 11) & 31, g = (value >> 5) & 63, b = value & 31
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
    }

    private static func decodeColor(_ bytes: [UInt8], _ offset: Int, into block: inout [UInt8], allowTransparent: Bool) {
        let c0 = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        let c1 = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8
        let a = expand565(c0), b = expand565(c1)
        var palette = [(a.0, a.1, a.2, 255), (b.0, b.1, b.2, 255), (0, 0, 0, 255), (0, 0, 0, 255)]
        if c0 > c1 || !allowTransparent {
            palette[2] = ((2 * a.0 + b.0) / 3, (2 * a.1 + b.1) / 3, (2 * a.2 + b.2) / 3, 255)
            palette[3] = ((a.0 + 2 * b.0) / 3, (a.1 + 2 * b.1) / 3, (a.2 + 2 * b.2) / 3, 255)
        } else {
            palette[2] = ((a.0 + b.0) / 2, (a.1 + b.1) / 2, (a.2 + b.2) / 2, 255)
            palette[3] = (0, 0, 0, 0)
        }
        let indices = UInt32(bytes[offset + 4]) | UInt32(bytes[offset + 5]) << 8 | UInt32(bytes[offset + 6]) << 16 | UInt32(bytes[offset + 7]) << 24
        for pixel in 0..<16 {
            let color = palette[Int((indices >> (2 * UInt32(pixel))) & 3)]
            block[pixel * 4] = UInt8(color.0); block[pixel * 4 + 1] = UInt8(color.1)
            block[pixel * 4 + 2] = UInt8(color.2); block[pixel * 4 + 3] = UInt8(color.3)
        }
    }

    private static func decodeChannel(_ bytes: [UInt8], _ offset: Int, into block: inout [UInt8], channel: Int) {
        let a0 = Int(bytes[offset]), a1 = Int(bytes[offset + 1])
        var palette = [a0, a1, 0, 0, 0, 0, 0, 0]
        if a0 > a1 {
            for i in 1...6 { palette[i + 1] = ((7 - i) * a0 + i * a1) / 7 }
        } else {
            for i in 1...4 { palette[i + 1] = ((5 - i) * a0 + i * a1) / 5 }
            palette[6] = 0; palette[7] = 255
        }
        var bits: UInt64 = 0
        for i in 0..<6 { bits |= UInt64(bytes[offset + 2 + i]) << (8 * UInt64(i)) }
        for pixel in 0..<16 {
            block[pixel * 4 + channel] = UInt8(palette[Int((bits >> (3 * UInt64(pixel))) & 7)])
        }
    }

    // MARK: Encoding (from RGBA8)

    static func encode(_ rgba: [UInt8], width: Int, height: Int, format: TextureFormat) -> Data {
        let blocksX = max(1, (width + 3) / 4), blocksY = max(1, (height + 3) / 4)
        var out = [UInt8](repeating: 0, count: blocksX * blocksY * format.blockBytes)
        let rows = blocksY
        // Rows of blocks are independent: encode them in parallel.
        out.withUnsafeMutableBufferPointer { output in
            let base = output.baseAddress!
            DispatchQueue.concurrentPerform(iterations: rows) { by in
                var block = [UInt8](repeating: 0, count: 64)
                for bx in 0..<blocksX {
                    for y in 0..<4 {
                        for x in 0..<4 {
                            let sx = min(bx * 4 + x, width - 1), sy = min(by * 4 + y, height - 1)
                            let source = (sy * width + sx) * 4
                            let target = (y * 4 + x) * 4
                            block[target] = rgba[source]; block[target + 1] = rgba[source + 1]
                            block[target + 2] = rgba[source + 2]; block[target + 3] = rgba[source + 3]
                        }
                    }
                    let offset = (by * blocksX + bx) * format.blockBytes
                    switch format {
                    case .bc1:
                        encodeColor(block, into: base + offset)
                    case .bc3:
                        encodeChannel(block, channel: 3, into: base + offset)
                        encodeColor(block, into: base + offset + 8)
                    case .bc4:
                        encodeChannel(block, channel: 0, into: base + offset)
                    case .bc5:
                        encodeChannel(block, channel: 0, into: base + offset)
                        encodeChannel(block, channel: 1, into: base + offset + 8)
                    default:
                        break
                    }
                }
            }
        }
        return Data(out)
    }

    private static func to565(_ r: Int, _ g: Int, _ b: Int) -> Int {
        ((r * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | ((b * 31 + 127) / 255)
    }

    /// Colour block: endpoints from the inset bounding box, then refined once by least squares.
    private static func encodeColor(_ block: [UInt8], into out: UnsafeMutablePointer<UInt8>) {
        var minC = [255, 255, 255], maxC = [0, 0, 0]
        for pixel in 0..<16 {
            for c in 0..<3 {
                let v = Int(block[pixel * 4 + c])
                minC[c] = min(minC[c], v); maxC[c] = max(maxC[c], v)
            }
        }
        for c in 0..<3 {
            let inset = (maxC[c] - minC[c]) >> 4
            minC[c] = min(255, minC[c] + inset); maxC[c] = max(0, maxC[c] - inset)
        }
        // Pick the diagonal of the box that follows the colours best.
        var cov = [0, 0]
        let mid = [(minC[0] + maxC[0]) / 2, (minC[1] + maxC[1]) / 2, (minC[2] + maxC[2]) / 2]
        for pixel in 0..<16 {
            let r = Int(block[pixel * 4]) - mid[0], g = Int(block[pixel * 4 + 1]) - mid[1], b = Int(block[pixel * 4 + 2]) - mid[2]
            cov[0] += r * g; cov[1] += b * g
        }
        if cov[0] < 0 { swap(&minC[0], &maxC[0]) }
        if cov[1] < 0 { swap(&minC[2], &maxC[2]) }

        var endpoints = (maxC, minC)
        var indices = [Int](repeating: 0, count: 16)
        for pass in 0..<2 {
            var c0 = to565(endpoints.0[0], endpoints.0[1], endpoints.0[2])
            var c1 = to565(endpoints.1[0], endpoints.1[1], endpoints.1[2])
            if c0 < c1 { swap(&c0, &c1); swap(&endpoints.0, &endpoints.1) }
            let a = expand565(c0), b = expand565(c1)
            let palette = [a, b, ((2 * a.0 + b.0) / 3, (2 * a.1 + b.1) / 3, (2 * a.2 + b.2) / 3),
                           ((a.0 + 2 * b.0) / 3, (a.1 + 2 * b.1) / 3, (a.2 + 2 * b.2) / 3)]
            for pixel in 0..<16 {
                let r = Int(block[pixel * 4]), g = Int(block[pixel * 4 + 1]), bl = Int(block[pixel * 4 + 2])
                var best = 0, bestDistance = Int.max
                for (index, color) in palette.enumerated() {
                    let distance = (r - color.0) * (r - color.0) + (g - color.1) * (g - color.1) + (bl - color.2) * (bl - color.2)
                    if distance < bestDistance { bestDistance = distance; best = index }
                }
                indices[pixel] = best
            }
            if pass == 1 || c0 == c1 {
                write565(c0, c1, indices: indices, into: out)
                return
            }
            // Least-squares refit of both endpoints for the chosen indices.
            let weights: [(Double, Double)] = [(1, 0), (0, 1), (2.0 / 3, 1.0 / 3), (1.0 / 3, 2.0 / 3)]
            var aa = 0.0, bb = 0.0, ab = 0.0
            var ax = [0.0, 0.0, 0.0], bx = [0.0, 0.0, 0.0]
            for pixel in 0..<16 {
                let (wa, wb) = weights[indices[pixel]]
                aa += wa * wa; bb += wb * wb; ab += wa * wb
                for c in 0..<3 {
                    let v = Double(block[pixel * 4 + c])
                    ax[c] += wa * v; bx[c] += wb * v
                }
            }
            let det = aa * bb - ab * ab
            if abs(det) < 1e-6 {
                write565(c0, c1, indices: indices, into: out)
                return
            }
            var e0 = [0, 0, 0], e1 = [0, 0, 0]
            for c in 0..<3 {
                e0[c] = Int(((ax[c] * bb - bx[c] * ab) / det).rounded()).clamped(0, 255)
                e1[c] = Int(((bx[c] * aa - ax[c] * ab) / det).rounded()).clamped(0, 255)
            }
            endpoints = (e0, e1)
        }
    }

    private static func write565(_ c0: Int, _ c1: Int, indices: [Int], into out: UnsafeMutablePointer<UInt8>) {
        var c0 = c0, c1 = c1, indices = indices
        if c0 == c1 { indices = [Int](repeating: 0, count: 16) }
        if c0 < c1 {
            swap(&c0, &c1)
            indices = indices.map { [1, 0, 3, 2][$0] }
        }
        out[0] = UInt8(c0 & 0xFF); out[1] = UInt8(c0 >> 8)
        out[2] = UInt8(c1 & 0xFF); out[3] = UInt8(c1 >> 8)
        var bits: UInt32 = 0
        for pixel in 0..<16 { bits |= UInt32(indices[pixel]) << (2 * UInt32(pixel)) }
        for i in 0..<4 { out[4 + i] = UInt8((bits >> (8 * UInt32(i))) & 0xFF) }
    }

    /// Single-channel block (BC4, the alpha of BC3, each half of BC5), 8-value mode.
    private static func encodeChannel(_ block: [UInt8], channel: Int, into out: UnsafeMutablePointer<UInt8>) {
        var low = 255, high = 0
        for pixel in 0..<16 {
            let v = Int(block[pixel * 4 + channel])
            low = min(low, v); high = max(high, v)
        }
        out[0] = UInt8(high); out[1] = UInt8(low)
        var bits: UInt64 = 0
        if high > low {
            var palette = [high, low]
            for i in 1...6 { palette.append(((7 - i) * high + i * low) / 7) }
            for pixel in 0..<16 {
                let v = Int(block[pixel * 4 + channel])
                var best = 0, bestDistance = Int.max
                for (index, p) in palette.enumerated() where abs(v - p) < bestDistance {
                    bestDistance = abs(v - p); best = index
                }
                bits |= UInt64(best) << (3 * UInt64(pixel))
            }
        }
        for i in 0..<6 { out[2 + i] = UInt8((bits >> (8 * UInt64(i))) & 0xFF) }
    }

    // MARK: Mip generation

    static func downsample(_ rgba: [UInt8], width: Int, height: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let w = max(1, width / 2), h = max(1, height / 2)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<4 {
                    var sum = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let sx = min(x * 2 + dx, width - 1), sy = min(y * 2 + dy, height - 1)
                        sum += Int(rgba[(sy * width + sx) * 4 + c])
                    }
                    out[(y * w + x) * 4 + c] = UInt8((sum + 2) / 4)
                }
            }
        }
        return (out, w, h)
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

// MARK: - Putting textures into the game's .erp files

/// One texture the game stores in an .erp: the surface ("….tif.image") and its view ("….tif").
struct GameTexture {
    let surface: String
    var view: String { String(surface.dropLast(".image".count)) }

    struct Header {
        var raw: Data
        var format: UInt32 { raw.u32(at: 8) }
        var width: Int { Int(raw.u32(at: 12)) }
        var height: Int { Int(raw.u32(at: 16)) }
        var mips: Int { Int(raw.u32(at: 24)) }
    }
}

enum TextureInjector {
    enum Failure: Error, LocalizedError {
        case missingTexture(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case let .missingTexture(name): return "The game file doesn't contain the texture \(name)."
            case let .unsupported(detail): return detail
            }
        }
    }

    /// Converts a DDS into what the game expects in place of `original`: the texture header, the full
    /// mip chain, and the format number (kept in the same family and colour space as the game's own).
    static func prepare(_ dds: DDSImage, replacing header: GameTexture.Header) throws -> (header: Data, pixels: Data, format: UInt32, mips: Int) {
        guard let (originalFormat, originalSRGB) = TextureFormat.fromGame(header.format) else {
            throw Failure.unsupported("The game uses a texture format this launcher can't write (\(header.format)).")
        }
        var target = dds.format
        var pixels = dds.pixels
        var mips = dds.mips

        if dds.format == .rgba8 || dds.format == .bc2 {
            // Uncompressed textures are compressed to match the game's own texture.
            switch originalFormat {
            case .bc1: target = hasTransparency(dds) ? .bc3 : .bc1
            case .bc4: target = .bc4
            case .bc5: target = .bc5
            case .rgba8: target = .rgba8
            default: target = .bc3
            }
            if target != .rgba8 || dds.format != .rgba8 {
                var rgba = dds.format == .rgba8 ? [UInt8](dds.level(0).data)
                    : (BlockCodec.decode(dds.level(0).data, format: dds.format, width: dds.width, height: dds.height) ?? [])
                var width = dds.width, height = dds.height
                var chain = Data()
                var level = 0
                // Use the file's own mip levels when it has them; otherwise make them.
                while true {
                    chain.append(target == .rgba8 ? Data(rgba) : BlockCodec.encode(rgba, width: width, height: height, format: target))
                    level += 1
                    if width == 1 && height == 1 { break }
                    if level < dds.mips, dds.format == .rgba8 {
                        let next = dds.level(level)
                        rgba = [UInt8](next.data); width = next.width; height = next.height
                    } else {
                        (rgba, width, height) = BlockCodec.downsample(rgba, width: width, height: height)
                    }
                }
                pixels = chain
                mips = level
            }
        }
        guard let code = target.gameCode(sRGB: originalSRGB) ?? target.gameCode(sRGB: false) else {
            throw Failure.unsupported("Can't store this texture as \(target) for the game.")
        }
        var newHeader = header.raw
        newHeader.setU32(code, at: 8)
        newHeader.setU32(UInt32(dds.width), at: 12)
        newHeader.setU32(UInt32(dds.height), at: 16)
        newHeader.setU32(1, at: 20)
        newHeader.setU32(UInt32(mips), at: 24)
        newHeader.setU32(1, at: 28)
        return (newHeader, pixels, code, mips)
    }

    static func hasTransparency(_ dds: DDSImage) -> Bool {
        guard dds.format == .rgba8 else { return true }
        let top = dds.level(0).data
        return top.withUnsafeBytes { buffer in
            stride(from: 3, to: buffer.count, by: 4).contains { buffer[$0] < 250 }
        }
    }

    /// Replacement fragments for each texture: surface = [header, all mips] (no .mipmaps streaming,
    /// like SERPs liveries), view = the original view with the new format and mip count.
    static func replacements(in erp: ERPArchive, textures: [(surface: String, dds: DDSImage)]) throws -> [String: [ERPArchive.NewFragment]] {
        var result: [String: [ERPArchive.NewFragment]] = [:]
        for (surfaceName, dds) in textures {
            guard let surface = erp.resource(named: surfaceName), surface.type == "GfxSurfaceRes",
                  surface.fragments.count >= 2 else { throw Failure.missingTexture(surfaceName) }
            let header = GameTexture.Header(raw: try erp.unpacked(surface.fragments[0]))
            let prepared = try prepare(dds, replacing: header)
            let flags = surface.fragments[1].flags
            result[surfaceName] = [
                ERPArchive.NewFragment(flags: surface.fragments[0].flags, payload: prepared.header),
                ERPArchive.NewFragment(flags: flags, payload: prepared.pixels),
            ]
            let viewName = GameTexture(surface: surfaceName).view
            if let view = erp.resource(named: viewName), view.type == "GfxSRVResource", let fragment = view.fragments.first {
                var raw = try erp.unpacked(fragment)
                if raw.count >= 16 {
                    raw.setU32(prepared.format, at: 4)
                    raw.setU32(UInt32(prepared.mips), at: 12)
                }
                result[viewName] = [ERPArchive.NewFragment(flags: fragment.flags, payload: raw)] + view.fragments.dropFirst().map {
                    ERPArchive.NewFragment(name: $0.name, flags: $0.flags, payload: (try? erp.unpacked($0)) ?? Data())
                }
            }
        }
        return result
    }

    /// How closely a DDS matches the game's texture (average colour difference of the largest mip
    /// level both have; lower = more alike). Used to tell which season's car a texture was made for.
    static func difference(_ dds: DDSImage, from erp: ERPArchive, surface surfaceName: String) -> Double? {
        guard let surface = erp.resource(named: surfaceName), surface.fragments.count >= 2,
              let headerData = try? erp.unpacked(surface.fragments[0]) else { return nil }
        let header = GameTexture.Header(raw: headerData)
        guard let (format, _) = TextureFormat.fromGame(header.format), header.width > 0,
              let level = (0..<dds.mips).first(where: { max(1, dds.width >> $0) == header.width && max(1, dds.height >> $0) == header.height }),
              let chain = try? erp.unpacked(surface.fragments[1]) else { return nil }
        let size = format.levelSize(width: header.width, height: header.height)
        guard chain.count >= size,
              let game = BlockCodec.decode(chain.prefix(size), format: format, width: header.width, height: header.height),
              let mine = BlockCodec.decode(dds.level(level).data, format: dds.format, width: header.width, height: header.height) else { return nil }
        var total = 0
        for index in stride(from: 0, to: min(game.count, mine.count), by: 4) {
            total += abs(Int(game[index]) - Int(mine[index])) + abs(Int(game[index + 1]) - Int(mine[index + 1]))
                + abs(Int(game[index + 2]) - Int(mine[index + 2]))
        }
        return Double(total) / Double(max(1, game.count / 4) * 3)
    }
}
