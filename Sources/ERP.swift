import Foundation

/// Reader/writer for the EGO engine's .erp archives (version 3, as used by F1 25).
///
/// Layout: a 48-byte header ("ERPK", version, info offset/size, data offset), a table of named
/// resources — each with a type (e.g. GfxSurfaceRes) and a list of data pieces ("fragments") — and
/// then the fragment data. Fragments are stored raw (compression 0x00 / 0x91) or as zstd (0x11).
struct ERPArchive {
    struct Fragment {
        var name: [UInt8]
        var offset: Int
        var size: Int
        var flags: UInt32
        var compression: UInt8
        var packedSize: Int
    }

    struct Resource {
        var name: String
        var type: String
        var unknown: UInt32
        var fragments: [Fragment]
        /// Bytes after the fragment list (a 16-byte id in F1 25). Kept as-is.
        var tail: [UInt8]
    }

    /// A new piece of data for a resource; written as a zstd frame of raw blocks.
    struct NewFragment {
        var name: [UInt8] = Array("temp".utf8)
        var flags: UInt32
        var payload: Data
    }

    enum Failure: Error, LocalizedError {
        case notERP(String)
        case damaged(String)
        case unknownCompression(UInt8)

        var errorDescription: String? {
            switch self {
            case let .notERP(name): return "\(name) isn't an F1 25 .erp file."
            case let .damaged(detail): return "The .erp file looks damaged (\(detail))."
            case let .unknownCompression(code): return "Unknown .erp compression 0x\(String(code, radix: 16))."
            }
        }
    }

    let data: Data
    let version: UInt32
    let dataOffset: Int
    var resources: [Resource]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), name: url.lastPathComponent)
    }

    init(data: Data, name: String = "file") throws {
        self.data = data
        var reader = ByteReader(data: data)
        guard data.count >= 0x38, try reader.bytes(4) == Array("ERPK".utf8) else { throw Failure.notERP(name) }
        version = try reader.u32()
        guard version == 3 else { throw Failure.damaged("version \(version)") }
        _ = try reader.u64()
        let infoOffset = Int(try reader.u64())
        let infoSize = Int(try reader.u64())
        dataOffset = Int(try reader.u64())
        guard infoOffset + infoSize <= data.count, dataOffset <= data.count else { throw Failure.damaged("header") }

        reader.position = infoOffset
        let count = Int(try reader.u32())
        _ = try reader.u32() // total fragment count
        var resources: [Resource] = []
        resources.reserveCapacity(count)
        for _ in 0..<count {
            let length = Int(try reader.u32())
            let entryEnd = reader.position + length
            let nameLength = Int(try reader.u16())
            let nameBytes = try reader.bytes(nameLength)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            let type = String(decoding: try reader.bytes(16).prefix { $0 != 0 }, as: UTF8.self)
            let unknown = try reader.u32()
            let fragmentCount = Int(try reader.u8())
            var fragments: [Fragment] = []
            for _ in 0..<fragmentCount {
                let fragmentName = try reader.bytes(4)
                let offset = Int(try reader.u64())
                let size = Int(try reader.u64())
                let flags = try reader.u32()
                let compression = try reader.u8()
                let packed = Int(try reader.u64())
                guard dataOffset + offset + packed <= data.count else { throw Failure.damaged("fragment outside the file") }
                fragments.append(Fragment(name: fragmentName, offset: offset, size: size, flags: flags,
                                          compression: compression, packedSize: packed))
            }
            guard reader.position <= entryEnd, entryEnd <= data.count else { throw Failure.damaged("resource entry") }
            let tail = try reader.bytes(entryEnd - reader.position)
            resources.append(Resource(name: name, type: type, unknown: unknown, fragments: fragments, tail: tail))
        }
        self.resources = resources
    }

    func packed(_ fragment: Fragment) -> Data {
        let start = data.startIndex + dataOffset + fragment.offset
        return data[start..<(start + fragment.packedSize)]
    }

    func unpacked(_ fragment: Fragment) throws -> Data {
        let raw = packed(fragment)
        switch fragment.compression {
        case 0x00, 0x91:
            return Data(raw)
        case 0x11:
            let result = try Zstd.decompress(Data(raw))
            guard result.count == fragment.size else { throw Failure.damaged("unpacked size") }
            return result
        default:
            throw Failure.unknownCompression(fragment.compression)
        }
    }

    func resource(named name: String) -> Resource? {
        resources.first { $0.name == name }
    }

    /// Writes a copy of this archive in which the given resources get new fragments. Everything else
    /// is copied byte for byte.
    func write(to url: URL, replacing replacements: [String: [NewFragment]]) throws {
        struct Piece { let packed: Data?; let source: Fragment?; let fragment: Fragment }
        var entries: [(Resource, [Piece])] = []
        var dataSize = 0
        for resource in resources {
            var pieces: [Piece] = []
            if let new = replacements[resource.name] {
                for fragment in new {
                    let frame = Zstd.rawFrame(fragment.payload)
                    let record = Fragment(name: fragment.name, offset: dataSize, size: fragment.payload.count,
                                          flags: fragment.flags, compression: 0x11, packedSize: frame.count)
                    pieces.append(Piece(packed: frame, source: nil, fragment: record))
                    dataSize += frame.count
                }
            } else {
                for fragment in resource.fragments {
                    var record = fragment
                    record.offset = dataSize
                    pieces.append(Piece(packed: nil, source: fragment, fragment: record))
                    dataSize += fragment.packedSize
                }
            }
            entries.append((resource, pieces))
        }

        var info = ByteWriter()
        info.u32(UInt32(entries.count))
        info.u32(UInt32(entries.reduce(0) { $0 + $1.1.count }))
        for (resource, pieces) in entries {
            var entry = ByteWriter()
            let nameBytes = Array(resource.name.utf8) + [0]
            entry.u16(UInt16(nameBytes.count))
            entry.bytes(nameBytes)
            var typeBytes = Array(resource.type.utf8.prefix(16))
            typeBytes += [UInt8](repeating: 0, count: 16 - typeBytes.count)
            entry.bytes(typeBytes)
            entry.u32(resource.unknown)
            entry.u8(UInt8(pieces.count))
            for piece in pieces {
                let fragment = piece.fragment
                entry.bytes(fragment.name)
                entry.u64(UInt64(fragment.offset))
                entry.u64(UInt64(fragment.size))
                entry.u32(fragment.flags)
                entry.u8(fragment.compression)
                entry.u64(UInt64(fragment.packedSize))
            }
            entry.bytes(resource.tail)
            info.u32(UInt32(entry.data.count))
            info.bytes(entry.data)
        }

        var header = ByteWriter()
        header.bytes(Array("ERPK".utf8))
        header.u32(version)
        header.u64(0)
        header.u64(0x30)
        header.u64(UInt64(info.data.count))
        header.u64(UInt64(0x30 + info.data.count))
        header.u64(0)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header.data)
        try handle.write(contentsOf: info.data)
        var buffer = Data()
        buffer.reserveCapacity(8 << 20)
        for (_, pieces) in entries {
            for piece in pieces {
                if let packed = piece.packed { buffer.append(packed) } else if let source = piece.source { buffer.append(self.packed(source)) }
                if buffer.count >= 8 << 20 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        try handle.write(contentsOf: buffer)
    }
}

// MARK: - Little-endian helpers

struct ByteReader {
    let data: Data
    var position = 0

    init(data: Data) { self.data = data }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= data.count else { throw ERPArchive.Failure.damaged("unexpected end") }
        let start = data.startIndex + position
        position += count
        return Array(data[start..<(start + count)])
    }

    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u16() throws -> UInt16 { try bytes(2).reversed().reduce(0) { $0 << 8 | UInt16($1) } }
    mutating func u32() throws -> UInt32 { try bytes(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try bytes(8).reversed().reduce(0) { $0 << 8 | UInt64($1) } }
}

struct ByteWriter {
    var data = Data()

    mutating func bytes(_ values: [UInt8]) { data.append(contentsOf: values) }
    mutating func bytes(_ values: Data) { data.append(values) }
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
}

extension Data {
    func u32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(self[startIndex + offset + index]) << (8 * index) }
        return value
    }

    mutating func setU32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[startIndex + offset + index] = UInt8((value >> (8 * index)) & 0xFF) }
    }
}
