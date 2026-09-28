import Foundation

/// A small, dependency-free Zstandard (RFC 8878) decoder, plus an encoder that writes valid frames made
/// of uncompressed ("raw") blocks. F1 25's .erp files store their pieces as zstd frames; macOS has no
/// zstd library, and the launcher only ever needs to decode small pieces (headers, texture views, small
/// mip levels) and to write new pieces the game can read.
enum Zstd {
    enum Failure: Error, LocalizedError {
        case corrupt(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case let .corrupt(detail): return "Damaged compressed data (\(detail))."
            case let .unsupported(detail): return "Unsupported compressed data (\(detail))."
            }
        }
    }

    // MARK: Encoding (raw blocks)

    /// A zstd frame holding `data` as uncompressed blocks. Every zstd decoder reads this.
    static func rawFrame(_ data: Data) -> Data {
        var out = Data([0x28, 0xB5, 0x2F, 0xFD])
        out.append(0x00) // frame header: no content size, no checksum, no dictionary, window follows
        out.append(0x58) // window descriptor: 2 MB (larger than any raw block)
        let blockSize = 128 * 1024
        var start = data.startIndex
        repeat {
            let end = min(start + blockSize, data.endIndex)
            let size = end - start
            let last: UInt32 = end == data.endIndex ? 1 : 0
            let header = last | (UInt32(size) << 3) // block type 0 = raw
            out.append(UInt8(header & 0xFF))
            out.append(UInt8((header >> 8) & 0xFF))
            out.append(UInt8((header >> 16) & 0xFF))
            out.append(data[start..<end])
            start = end
        } while start < data.endIndex
        return out
    }

    // MARK: Decoding

    static func decompress(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        var position = 0
        var output: [UInt8] = []
        while position < bytes.count {
            guard position + 4 <= bytes.count else { throw Failure.corrupt("truncated frame") }
            let magic = UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
                | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
            position += 4
            if magic & 0xFFFF_FFF0 == 0x184D_2A50 { // skippable frame
                guard position + 4 <= bytes.count else { throw Failure.corrupt("truncated skippable frame") }
                let size = Int(UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
                    | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24)
                position += 4 + size
                continue
            }
            guard magic == 0xFD2F_B528 else { throw Failure.corrupt("not a zstd frame") }
            var frame = FrameDecoder(bytes: bytes, position: position)
            try frame.decode(into: &output)
            position = frame.position
        }
        return Data(output)
    }

    // MARK: Frame

    private struct FrameDecoder {
        let bytes: [UInt8]
        var position: Int
        var repeats: [Int] = [1, 4, 8]
        var huffman: HuffmanTable?
        var literalLengthTable: FSETable?
        var offsetTable: FSETable?
        var matchLengthTable: FSETable?

        init(bytes: [UInt8], position: Int) {
            self.bytes = bytes
            self.position = position
        }

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw Failure.corrupt("unexpected end") }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func decode(into output: inout [UInt8]) throws {
            let descriptor = try byte()
            let contentSizeFlag = Int(descriptor >> 6)
            let singleSegment = (descriptor >> 5) & 1 == 1
            let hasChecksum = (descriptor >> 2) & 1 == 1
            let dictionaryFlag = Int(descriptor & 3)
            if !singleSegment { _ = try byte() } // window descriptor
            let dictionaryBytes = [0, 1, 2, 4][dictionaryFlag]
            var dictionaryID = 0
            for index in 0..<dictionaryBytes { dictionaryID |= Int(try byte()) << (8 * index) }
            guard dictionaryID == 0 else { throw Failure.unsupported("dictionary") }
            let contentSizeBytes = contentSizeFlag == 0 ? (singleSegment ? 1 : 0) : [0, 2, 4, 8][contentSizeFlag]
            position += contentSizeBytes
            let frameStart = output.count

            while true {
                guard position + 3 <= bytes.count else { throw Failure.corrupt("truncated block header") }
                let header = Int(bytes[position]) | Int(bytes[position + 1]) << 8 | Int(bytes[position + 2]) << 16
                position += 3
                let last = header & 1 == 1
                let type = (header >> 1) & 3
                let size = header >> 3
                switch type {
                case 0:
                    guard position + size <= bytes.count else { throw Failure.corrupt("truncated raw block") }
                    output.append(contentsOf: bytes[position..<(position + size)])
                    position += size
                case 1:
                    let value = try byte()
                    output.append(contentsOf: repeatElement(value, count: size))
                case 2:
                    guard position + size <= bytes.count else { throw Failure.corrupt("truncated block") }
                    try decodeCompressedBlock(position..<(position + size), frameStart: frameStart, output: &output)
                    position += size
                default:
                    throw Failure.corrupt("reserved block type")
                }
                if last { break }
            }
            if hasChecksum { position += 4 }
        }

        // MARK: Compressed block

        mutating func decodeCompressedBlock(_ range: Range<Int>, frameStart: Int, output: inout [UInt8]) throws {
            var cursor = range.lowerBound
            let literals = try decodeLiterals(&cursor, end: range.upperBound)

            // Sequences section header
            guard cursor < range.upperBound else { throw Failure.corrupt("missing sequences header") }
            var sequenceCount = Int(bytes[cursor]); cursor += 1
            if sequenceCount == 0 {
                output.append(contentsOf: literals)
                return
            }
            if sequenceCount == 255 {
                guard cursor + 2 <= range.upperBound else { throw Failure.corrupt("sequence count") }
                sequenceCount = Int(bytes[cursor]) + (Int(bytes[cursor + 1]) << 8) + 0x7F00
                cursor += 2
            } else if sequenceCount >= 128 {
                guard cursor < range.upperBound else { throw Failure.corrupt("sequence count") }
                sequenceCount = ((sequenceCount - 128) << 8) + Int(bytes[cursor])
                cursor += 1
            }
            guard cursor < range.upperBound else { throw Failure.corrupt("compression modes") }
            let modes = bytes[cursor]; cursor += 1
            literalLengthTable = try table(mode: Int(modes >> 6), cursor: &cursor, end: range.upperBound,
                                           previous: literalLengthTable, predefined: .literalLengths, maxSymbol: 35, maxLog: 9)
            offsetTable = try table(mode: Int((modes >> 4) & 3), cursor: &cursor, end: range.upperBound,
                                    previous: offsetTable, predefined: .offsets, maxSymbol: 31, maxLog: 8)
            matchLengthTable = try table(mode: Int((modes >> 2) & 3), cursor: &cursor, end: range.upperBound,
                                         previous: matchLengthTable, predefined: .matchLengths, maxSymbol: 52, maxLog: 9)
            guard let llTable = literalLengthTable, let ofTable = offsetTable, let mlTable = matchLengthTable else {
                throw Failure.corrupt("missing sequence tables")
            }

            var stream = try BackwardBits(bytes: bytes, range: cursor..<range.upperBound)
            var llState = stream.read(llTable.log)
            var ofState = stream.read(ofTable.log)
            var mlState = stream.read(mlTable.log)
            var literalPosition = 0

            for index in 0..<sequenceCount {
                let ofCode = Int(ofTable.symbols[ofState])
                let mlCode = Int(mlTable.symbols[mlState])
                let llCode = Int(llTable.symbols[llState])
                guard ofCode <= 31, mlCode < Tables.matchLengthBase.count, llCode < Tables.literalLengthBase.count else {
                    throw Failure.corrupt("sequence code")
                }
                let offsetValue = (1 << ofCode) + stream.read(ofCode)
                let matchLength = Tables.matchLengthBase[mlCode] + stream.read(Tables.matchLengthBits[mlCode])
                let literalLength = Tables.literalLengthBase[llCode] + stream.read(Tables.literalLengthBits[llCode])

                if index != sequenceCount - 1 {
                    llState = llTable.next(llState, &stream)
                    mlState = mlTable.next(mlState, &stream)
                    ofState = ofTable.next(ofState, &stream)
                }

                var offset: Int
                if offsetValue > 3 {
                    offset = offsetValue - 3
                    repeats = [offset, repeats[0], repeats[1]]
                } else {
                    var slot = offsetValue - 1
                    if literalLength == 0 { slot += 1 }
                    switch slot {
                    case 0: offset = repeats[0]
                    case 1: offset = repeats[1]; repeats = [repeats[1], repeats[0], repeats[2]]
                    case 2: offset = repeats[2]; repeats = [repeats[2], repeats[0], repeats[1]]
                    default: offset = repeats[0] - 1; repeats = [offset, repeats[0], repeats[1]]
                    }
                }

                guard literalPosition + literalLength <= literals.count else { throw Failure.corrupt("literal length") }
                output.append(contentsOf: literals[literalPosition..<(literalPosition + literalLength)])
                literalPosition += literalLength
                guard offset > 0, offset <= output.count - frameStart else { throw Failure.corrupt("match offset") }
                var from = output.count - offset
                output.reserveCapacity(output.count + matchLength)
                for _ in 0..<matchLength {
                    output.append(output[from])
                    from += 1
                }
            }
            output.append(contentsOf: literals[literalPosition...])
        }

        mutating func table(mode: Int, cursor: inout Int, end: Int, previous: FSETable?,
                            predefined: Tables.Predefined, maxSymbol: Int, maxLog: Int) throws -> FSETable {
            switch mode {
            case 0:
                return predefined.table
            case 1:
                guard cursor < end else { throw Failure.corrupt("RLE table") }
                defer { cursor += 1 }
                return FSETable(rle: bytes[cursor])
            case 2:
                var reader = ForwardBits(bytes: bytes, position: cursor, end: end)
                let counts = try FSETable.readCounts(&reader, maxSymbol: maxSymbol, maxLog: maxLog)
                cursor = reader.byteAlignedPosition
                return try FSETable(counts: counts.counts, log: counts.log)
            default:
                guard let previous else { throw Failure.corrupt("repeat table without a previous one") }
                return previous
            }
        }

        // MARK: Literals

        mutating func decodeLiterals(_ cursor: inout Int, end: Int) throws -> [UInt8] {
            guard cursor < end else { throw Failure.corrupt("missing literals") }
            let first = Int(bytes[cursor])
            let type = first & 3
            let sizeFormat = (first >> 2) & 3

            if type == 0 || type == 1 {
                var size: Int
                switch sizeFormat {
                case 0, 2:
                    size = first >> 3; cursor += 1
                case 1:
                    guard cursor + 2 <= end else { throw Failure.corrupt("literals header") }
                    size = (first >> 4) + (Int(bytes[cursor + 1]) << 4); cursor += 2
                default:
                    guard cursor + 3 <= end else { throw Failure.corrupt("literals header") }
                    size = (first >> 4) + (Int(bytes[cursor + 1]) << 4) + (Int(bytes[cursor + 2]) << 12); cursor += 3
                }
                if type == 0 {
                    guard cursor + size <= end else { throw Failure.corrupt("raw literals") }
                    defer { cursor += size }
                    return Array(bytes[cursor..<(cursor + size)])
                }
                guard cursor < end else { throw Failure.corrupt("RLE literals") }
                defer { cursor += 1 }
                return [UInt8](repeating: bytes[cursor], count: size)
            }

            var regenerated: Int, compressed: Int, streams: Int
            switch sizeFormat {
            case 0, 1:
                guard cursor + 3 <= end else { throw Failure.corrupt("literals header") }
                let value = Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2]) << 16
                regenerated = (value >> 4) & 0x3FF
                compressed = (value >> 14) & 0x3FF
                streams = sizeFormat == 0 ? 1 : 4
                cursor += 3
            case 2:
                guard cursor + 4 <= end else { throw Failure.corrupt("literals header") }
                let value = Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2]) << 16 | Int(bytes[cursor + 3]) << 24
                regenerated = (value >> 4) & 0x3FFF
                compressed = (value >> 18) & 0x3FFF
                streams = 4
                cursor += 4
            default:
                guard cursor + 5 <= end else { throw Failure.corrupt("literals header") }
                var value = 0
                for index in 0..<5 { value |= Int(bytes[cursor + index]) << (8 * index) }
                regenerated = (value >> 4) & 0x3FFFF
                compressed = (value >> 22) & 0x3FFFF
                streams = 4
                cursor += 5
            }
            guard cursor + compressed <= end else { throw Failure.corrupt("compressed literals") }
            var streamStart = cursor
            let streamEnd = cursor + compressed
            if type == 2 {
                huffman = try HuffmanTable.read(bytes: bytes, position: &streamStart, end: streamEnd)
            }
            guard let huffman else { throw Failure.corrupt("treeless literals without a table") }
            cursor = streamEnd

            var literals = [UInt8](repeating: 0, count: regenerated)
            if streams == 1 {
                try huffman.decode(bytes: bytes, range: streamStart..<streamEnd, into: &literals, range: 0..<regenerated)
            } else {
                guard streamStart + 6 <= streamEnd else { throw Failure.corrupt("jump table") }
                let size1 = Int(bytes[streamStart]) | Int(bytes[streamStart + 1]) << 8
                let size2 = Int(bytes[streamStart + 2]) | Int(bytes[streamStart + 3]) << 8
                let size3 = Int(bytes[streamStart + 4]) | Int(bytes[streamStart + 5]) << 8
                let start1 = streamStart + 6, start2 = start1 + size1, start3 = start2 + size2, start4 = start3 + size3
                guard start4 <= streamEnd else { throw Failure.corrupt("jump table sizes") }
                let segment = (regenerated + 3) / 4
                guard 3 * segment <= regenerated else { throw Failure.corrupt("literal segments") }
                try huffman.decode(bytes: bytes, range: start1..<start2, into: &literals, range: 0..<segment)
                try huffman.decode(bytes: bytes, range: start2..<start3, into: &literals, range: segment..<(2 * segment))
                try huffman.decode(bytes: bytes, range: start3..<start4, into: &literals, range: (2 * segment)..<(3 * segment))
                try huffman.decode(bytes: bytes, range: start4..<streamEnd, into: &literals, range: (3 * segment)..<regenerated)
            }
            return literals
        }
    }

    // MARK: Bit readers

    /// Reads a zstd "backward" bitstream: from the end towards the start, past a 1-bit end marker.
    struct BackwardBits {
        let bytes: [UInt8]
        let start: Int
        /// Number of unread bits, counted from `start`. May go negative (reads past the start give zeros).
        var remaining: Int

        init(bytes: [UInt8], range: Range<Int>) throws {
            guard !range.isEmpty, bytes[range.upperBound - 1] != 0 else { throw Failure.corrupt("bitstream end marker") }
            self.bytes = bytes
            self.start = range.lowerBound
            let last = bytes[range.upperBound - 1]
            remaining = range.count * 8 - (last.leadingZeroBitCount + 1)
        }

        mutating func read(_ count: Int) -> Int {
            guard count > 0 else { return 0 }
            let high = remaining
            remaining -= count
            guard high > 0 else { return 0 }
            var low = high - count
            var missing = 0
            if low < 0 { missing = -low; low = 0 }
            let wanted = high - low
            let shift = low & 7
            let first = start + (low >> 3)
            var word: UInt64 = 0
            for index in 0..<((shift + wanted + 7) >> 3) { word |= UInt64(bytes[first + index]) << UInt64(8 * index) }
            let value = (word >> UInt64(shift)) & ((1 << UInt64(wanted)) - 1)
            return Int(value) << missing
        }
    }

    /// Little-endian forward bit reader (used for FSE table descriptions).
    struct ForwardBits {
        let bytes: [UInt8]
        let startPosition: Int
        let end: Int
        var bitPosition = 0

        init(bytes: [UInt8], position: Int, end: Int) {
            self.bytes = bytes
            self.startPosition = position
            self.end = end
        }

        func peek(_ count: Int) -> Int {
            var value = 0
            for index in 0..<count {
                let bit = bitPosition + index
                let byteIndex = startPosition + (bit >> 3)
                if byteIndex < end {
                    value |= Int((bytes[byteIndex] >> UInt8(bit & 7)) & 1) << index
                }
            }
            return value
        }

        mutating func skip(_ count: Int) { bitPosition += count }

        var byteAlignedPosition: Int { startPosition + (bitPosition + 7) / 8 }
    }

    // MARK: FSE

    struct FSETable {
        var log: Int
        var symbols: [UInt8]
        var bits: [UInt8]
        var baselines: [Int]

        init(rle symbol: UInt8) {
            log = 0
            symbols = [symbol]
            bits = [0]
            baselines = [0]
        }

        init(counts: [Int], log: Int) throws {
            self.log = log
            let size = 1 << log
            symbols = [UInt8](repeating: 0, count: size)
            bits = [UInt8](repeating: 0, count: size)
            baselines = [Int](repeating: 0, count: size)
            var next = [Int](repeating: 0, count: counts.count)
            var high = size - 1
            for (symbol, count) in counts.enumerated() {
                if count == -1 {
                    symbols[high] = UInt8(symbol)
                    high -= 1
                    next[symbol] = 1
                } else {
                    next[symbol] = max(count, 0)
                }
            }
            let step = (size >> 1) + (size >> 3) + 3
            let mask = size - 1
            var position = 0
            for (symbol, count) in counts.enumerated() where count > 0 {
                for _ in 0..<count {
                    symbols[position] = UInt8(symbol)
                    repeat { position = (position + step) & mask } while position > high
                }
            }
            guard position == 0 else { throw Failure.corrupt("FSE table spread") }
            for state in 0..<size {
                let symbol = Int(symbols[state])
                let nextState = next[symbol]
                next[symbol] += 1
                let highBit = Int.bitWidth - 1 - nextState.leadingZeroBitCount
                let numberOfBits = log - highBit
                bits[state] = UInt8(numberOfBits)
                baselines[state] = (nextState << numberOfBits) - size
            }
        }

        func next(_ state: Int, _ stream: inout BackwardBits) -> Int {
            baselines[state] + stream.read(Int(bits[state]))
        }

        /// Reads an FSE "normalized counts" table description.
        static func readCounts(_ reader: inout ForwardBits, maxSymbol: Int, maxLog: Int) throws -> (counts: [Int], log: Int) {
            let log = reader.peek(4) + 5
            reader.skip(4)
            guard log <= maxLog else { throw Failure.corrupt("FSE accuracy log") }
            var remaining = (1 << log) + 1
            var threshold = 1 << log
            var numberOfBits = log + 1
            var counts: [Int] = []
            var previousZero = false
            while remaining > 1 && counts.count <= maxSymbol {
                if previousZero {
                    var zeros = 0
                    while reader.peek(16) == 0xFFFF { zeros += 24; reader.skip(16) }
                    while reader.peek(2) == 3 { zeros += 3; reader.skip(2) }
                    zeros += reader.peek(2)
                    reader.skip(2)
                    counts.append(contentsOf: repeatElement(0, count: zeros))
                    guard counts.count <= maxSymbol + 1 else { throw Failure.corrupt("FSE zero run") }
                    if counts.count > maxSymbol { break }
                }
                let maxValue = (2 * threshold - 1) - remaining
                var count: Int
                let low = reader.peek(numberOfBits - 1)
                if low < maxValue {
                    count = low
                    reader.skip(numberOfBits - 1)
                } else {
                    count = reader.peek(numberOfBits)
                    if count >= threshold { count -= maxValue }
                    reader.skip(numberOfBits)
                }
                count -= 1
                remaining -= abs(count)
                counts.append(count)
                previousZero = count == 0
                while remaining < threshold && numberOfBits > 1 {
                    numberOfBits -= 1
                    threshold >>= 1
                }
            }
            guard remaining == 1 else { throw Failure.corrupt("FSE counts") }
            return (counts, log)
        }
    }

    // MARK: Huffman

    struct HuffmanTable {
        let maxBits: Int
        let symbols: [UInt8]
        let lengths: [UInt8]

        static func read(bytes: [UInt8], position: inout Int, end: Int) throws -> HuffmanTable {
            guard position < end else { throw Failure.corrupt("Huffman header") }
            let header = Int(bytes[position]); position += 1
            var weights: [Int] = []
            if header >= 128 {
                let count = header - 127
                let byteCount = (count + 1) / 2
                guard position + byteCount <= end else { throw Failure.corrupt("Huffman weights") }
                for index in 0..<count {
                    let byte = Int(bytes[position + index / 2])
                    weights.append(index % 2 == 0 ? byte >> 4 : byte & 0xF)
                }
                position += byteCount
            } else {
                guard position + header <= end else { throw Failure.corrupt("Huffman weights") }
                var reader = ForwardBits(bytes: bytes, position: position, end: position + header)
                let described = try FSETable.readCounts(&reader, maxSymbol: 255, maxLog: 6)
                let table = try FSETable(counts: described.counts, log: described.log)
                var stream = try BackwardBits(bytes: bytes, range: reader.byteAlignedPosition..<(position + header))
                var state1 = stream.read(table.log)
                var state2 = stream.read(table.log)
                while weights.count < 255 {
                    weights.append(Int(table.symbols[state1]))
                    state1 = table.next(state1, &stream)
                    if stream.remaining < 0 { weights.append(Int(table.symbols[state2])); break }
                    weights.append(Int(table.symbols[state2]))
                    state2 = table.next(state2, &stream)
                    if stream.remaining < 0 { weights.append(Int(table.symbols[state1])); break }
                }
                position += header
            }

            var total = 0
            for weight in weights where weight > 0 {
                guard weight <= 11 else { throw Failure.corrupt("Huffman weight") }
                total += 1 << (weight - 1)
            }
            guard total > 0 else { throw Failure.corrupt("Huffman weights sum") }
            let maxBits = Int.bitWidth - total.leadingZeroBitCount // highest bit + 1
            let leftOver = (1 << maxBits) - total
            guard leftOver > 0, leftOver & (leftOver - 1) == 0 else { throw Failure.corrupt("Huffman tree") }
            weights.append(Int.bitWidth - leftOver.leadingZeroBitCount) // log2(leftOver) + 1
            guard maxBits <= 11 else { throw Failure.corrupt("Huffman depth") }

            let size = 1 << maxBits
            var symbols = [UInt8](repeating: 0, count: size)
            var lengths = [UInt8](repeating: 0, count: size)
            var position = 0
            for weight in 1...maxBits {
                for (symbol, symbolWeight) in weights.enumerated() where symbolWeight == weight {
                    let span = 1 << (weight - 1)
                    guard position + span <= size else { throw Failure.corrupt("Huffman table overflow") }
                    for index in position..<(position + span) {
                        symbols[index] = UInt8(symbol)
                        lengths[index] = UInt8(maxBits + 1 - weight)
                    }
                    position += span
                }
            }
            guard position == size else { throw Failure.corrupt("Huffman table size") }
            return HuffmanTable(maxBits: maxBits, symbols: symbols, lengths: lengths)
        }

        func decode(bytes: [UInt8], range: Range<Int>, into output: inout [UInt8], range outputRange: Range<Int>) throws {
            guard !outputRange.isEmpty else { return }
            var stream = try BackwardBits(bytes: bytes, range: range)
            let mask = (1 << maxBits) - 1
            var state = stream.read(maxBits)
            for index in outputRange {
                output[index] = symbols[state]
                let length = Int(lengths[state])
                state = ((state << length) | stream.read(length)) & mask
            }
            guard stream.remaining == -maxBits else { throw Failure.corrupt("Huffman stream length") }
        }
    }

    // MARK: Constant tables

    enum Tables {
        static let literalLengthBase = Array(0..<16) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512,
                                                         1024, 2048, 4096, 8192, 16384, 32768, 65536]
        static let literalLengthBits = [Int](repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9,
                                                                          10, 11, 12, 13, 14, 15, 16]
        static let matchLengthBase = Array(3..<35) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515,
                                                       1027, 2051, 4099, 8195, 16387, 32771, 65539]
        static let matchLengthBits = [Int](repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9,
                                                                        10, 11, 12, 13, 14, 15, 16]

        enum Predefined {
            case literalLengths, offsets, matchLengths

            var table: FSETable {
                switch self {
                case .literalLengths: return Tables.literalLengthTable
                case .offsets: return Tables.offsetTable
                case .matchLengths: return Tables.matchLengthTable
                }
            }
        }

        static let literalLengthTable = try! FSETable(counts: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
                                                               2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
                                                               -1, -1, -1, -1], log: 6)
        static let matchLengthTable = try! FSETable(counts: [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
                                                             1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                                             1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
                                                             -1, -1, -1, -1, -1], log: 6)
        static let offsetTable = try! FSETable(counts: [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
                                                        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1], log: 5)
    }
}
