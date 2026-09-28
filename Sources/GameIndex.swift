import Foundation

/// What's in the F1 25 folder: where each file lives, and which .erp files hold which textures.
/// Built once and cached until the game changes (F1_25.exe gets a new size or date).
final class GameIndex: @unchecked Sendable {
    struct Place: Codable, Hashable, Sendable {
        /// Game-relative path of the .erp file.
        let erp: String
        /// Texture (surface) name inside it.
        let surface: String
    }

    let gameDir: URL
    /// Lower-cased file name → game-relative paths.
    private(set) var files: [String: [String]] = [:]
    /// Lower-cased texture name ("haas_paint_d.tif") → where it is.
    private(set) var textures: [String: [Place]] = [:]

    private struct Saved: Codable {
        var stamp: String
        var files: [String: [String]]
        var textures: [String: [Place]]
    }

    private init(gameDir: URL) { self.gameDir = gameDir }

    static func stamp(for gameDir: URL) -> String {
        let exe = gameDir.appendingPathComponent(ModRules.gameExecutable)
        let attributes = try? FileManager.default.attributesOfItem(atPath: exe.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "v2|\(gameDir.path)|\(size)|\(date)"
    }

    static func load(gameDir: URL, cacheFile: URL?) -> GameIndex {
        let index = GameIndex(gameDir: gameDir)
        let stamp = stamp(for: gameDir)
        if let cacheFile, let data = try? Data(contentsOf: cacheFile),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.stamp == stamp {
            index.files = saved.files
            index.textures = saved.textures
            return index
        }
        index.build()
        if let cacheFile, let data = try? JSONEncoder().encode(Saved(stamp: stamp, files: index.files, textures: index.textures)) {
            try? data.write(to: cacheFile, options: .atomic)
        }
        return index
    }

    /// Packages whose .erp files hold car, livery, helmet and suit textures.
    static func holdsLiveryTextures(_ relativePath: String) -> Bool {
        let parts = relativePath.lowercased().split(separator: "/")
        guard parts.count > 2, parts[0] == "2025_asset_groups" else { return false }
        let package = parts[1]
        return package.contains("vehicle_package") || package == "livery_package" || package == "character_package"
            || package == "f1_safetycar_package"
    }

    private func build() {
        let start = Date()
        var files: [String: [String]] = [:]
        var erps: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: gameDir.path)
        while let relative = enumerator?.nextObject() as? String {
            guard (enumerator?.fileAttributes?[.type] as? FileAttributeType) == .typeRegular else { continue }
            let name = (relative as NSString).lastPathComponent.lowercased()
            let ext = (name as NSString).pathExtension
            guard ModRules.installableExtensions.contains(ext) else { continue }
            files[name, default: []].append(relative)
            if ext == "erp" && Self.holdsLiveryTextures(relative) { erps.append(relative) }
        }

        var textures: [String: [Place]] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: erps.count) { index in
            let relative = erps[index]
            guard let names = try? ERPArchive.surfaceNames(at: gameDir.appendingPathComponent(relative)) else { return }
            var local: [String: [Place]] = [:]
            for surface in names {
                local[Self.textureKey(ofSurface: surface), default: []].append(Place(erp: relative, surface: surface))
            }
            lock.lock()
            textures.merge(local) { $0 + $1 }
            lock.unlock()
        }
        self.files = files
        self.textures = textures
        ActivityLog.write("Indexed the game: \(files.values.reduce(0) { $0 + $1.count }) files, \(erps.count) texture archives, "
            + "\(textures.count) textures (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
    }

    /// "eaid://f1_2025_vehicle_package/teams/haas/textures/haas_paint_d.tif.image" → "haas_paint_d.tif"
    static func textureKey(ofSurface surface: String) -> String {
        var name = (surface.split(separator: "/").last.map(String.init) ?? surface).lowercased()
        if name.hasSuffix(".image") { name.removeLast(6) }
        return name
    }

    /// True if the game has this exact file (case-insensitive).
    func hasFile(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        return files[name]?.contains { $0.caseInsensitiveCompare(relativePath) == .orderedSame } ?? false
    }

    func places(forTexture key: String) -> [Place] {
        if let found = textures[key] { return found }
        if !key.hasSuffix(".tif"), let found = textures[key + ".tif"] { return found }
        return []
    }

    /// Season of a texture place: from the texture's package, e.g. "2026" or "F2 2025".
    static func season(of place: Place) -> String? {
        let body = place.surface.hasPrefix("eaid://") ? String(place.surface.dropFirst(7)) : place.surface
        guard let package = body.split(separator: "/").first else { return nil }
        return ModParser.season(fromPackage: String(package))
    }

    /// Finds the game file a loose mod file replaces: same file name; ties broken by the most matching
    /// folder names. Returns nil when there's no match or it's ambiguous.
    func gamePath(forLoose lookup: [String]) -> String? {
        guard let name = lookup.last, let candidates = files[name], !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        func score(_ candidate: String) -> Int {
            let parts = candidate.lowercased().split(separator: "/").map(String.init)
            var matched = 0
            for (a, b) in zip(parts.reversed(), lookup.reversed()) where a == b { matched += 1 }
            // Folder names anywhere in the mod path count too (e.g. "haas", "shader_package_2025").
            let folders = Set(lookup.dropLast())
            // Loose car files almost always mean the car itself, not a track's AI copy of it.
            let carFile = candidate.lowercased().contains("_vehicle_package/teams/") ? 5 : 0
            return matched * 10 + parts.dropLast().filter { folders.contains($0) }.count + carFile
        }
        let scored = candidates.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }
        guard scored[0].1 > scored[1].1 else { return nil }
        return scored[0].0
    }
}

extension ERPArchive {
    /// Fast table scan: just the names of the textures (GfxSurfaceRes) in an .erp file.
    static func surfaceNames(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [String] in
            guard buffer.count >= 0x38, buffer[0] == 0x45, buffer[1] == 0x52, buffer[2] == 0x50, buffer[3] == 0x4B else {
                throw Failure.notERP(url.lastPathComponent)
            }
            func u32(_ at: Int) -> Int { Int(buffer.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) }
            func u16(_ at: Int) -> Int { Int(buffer.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian) }
            let infoOffset = Int(buffer.loadUnaligned(fromByteOffset: 16, as: UInt64.self).littleEndian)
            guard infoOffset + 8 <= buffer.count else { throw Failure.damaged("table") }
            let count = u32(infoOffset)
            var position = infoOffset + 8
            var names: [String] = []
            let surfaceType = Array("GfxSurfaceRes".utf8)
            for _ in 0..<count {
                guard position + 6 <= buffer.count else { throw Failure.damaged("table") }
                let length = u32(position)
                let nameLength = u16(position + 4)
                let nameStart = position + 6
                let typeStart = nameStart + nameLength
                guard typeStart + 16 <= buffer.count else { throw Failure.damaged("table") }
                var isSurface = true
                for (offset, byte) in surfaceType.enumerated() where buffer[typeStart + offset] != byte { isSurface = false; break }
                if isSurface && buffer[typeStart + surfaceType.count] == 0 {
                    let nameBytes = UnsafeRawBufferPointer(rebasing: buffer[nameStart..<(nameStart + max(0, nameLength - 1))])
                    names.append(String(decoding: nameBytes, as: UTF8.self))
                }
                position += 4 + length
            }
            return names
        }
    }
}
