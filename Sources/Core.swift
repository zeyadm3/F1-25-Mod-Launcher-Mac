import Foundation

// MARK: - Rules (carried over from SERPs Launcher for F1 25)

enum ModRules {
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z"]

    /// File types that may be copied into the game folder (same list as SERPs Launcher).
    static let installableExtensions: Set<String> = ["erp", "bk2", "bdl", "png", "mipmaps", "pdf", "lng"]

    /// A folder with one of these names marks where the game folder starts inside a mod archive.
    static let signatureFolders: Set<String> = ["2025_asset_groups", "shader_package_2025", "localisatioa", "audio", "videos"]

    /// Every copy of the SERPs Base Files ships this PDF; it is how the base files are recognised.
    static let baseFilesMarker = "serps base files for f1 25 - read me.pdf"

    static let baseFilesDownloadURL = URL(string: "https://www.overtake.gg/downloads/serps-base-files-for-f1-25-simplified-erps-serps-use-to-play-f1-25-with-serps-compatible-mods.77448/")!

    /// Mods that replace any of these (without shipping their own words.erp) need the SERPs Base Files.
    static let baseFilesDependencies: Set<String> = [
        "markdown_system.erp", "credits.erp", "achievements.erp", "common_flow_customisation.erp",
        "flow_f1_life_driver_tags.erp", "flow_fz_environment.erp", "flow_loading.erp", "flow_persistent.erp",
        "flow_playercard.erp", "flow_render_badges.erp", "fonts.erp", "fonts_efigs_r_p.erp",
        "fonts_standard_icons.erp", "vehicle_carbon.nefx2.sm51.erp", "vehicle_custom_paint.nefx2.sm51.erp",
        "vehicle_damage_mask.nefx2.sm51.erp", "vehicle_floating_decal.nefx2.sm51.erp",
        "vehicle_gloss_paint.nefx2.sm51.erp", "vehicle_hologram_paint.nefx2.sm51.erp",
        "vehicle_metallic_paint.nefx2.sm51.erp", "vehicle_multi_paint.nefx2.sm51.erp",
        "vehicle_paint_shadowcast.nefx2.sm51.erp", "vehicle_rain_beads.nefx2.sm51.erp",
        "vehicle_steering.nefx2.sm51.erp", "vehicle_wheels.nefx2.sm51.erp", "effects_myteam.nefx2.sm51.erp",
        "photo_mode.nefx2.sm51.erp", "sponsor_board.nefx2.sm51.erp", "track_info.nefx2.sm51.erp",
        "character_helmet.nefx2.sm51.erp", "ui_texture.nefx2.sm51.erp", "vehicle_generic.nefx2.sm51.erp",
        "tyre_sidewall.nefx2.sm51.erp",
    ]

    static let gameExecutable = "F1_25.exe"
    static let steamAppID = "3059520"
}

enum AppPaths {
    /// F1ML_SUPPORT_DIR points the app at a sandbox (used for testing against a fake game folder).
    static let support = ProcessInfo.processInfo.environment["F1ML_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/F1 25 Mod Launcher", isDirectory: true)
    static let mods = support.appendingPathComponent("Mods", isDirectory: true)
    static let backups = support.appendingPathComponent("Backups", isDirectory: true)
    static let temp = support.appendingPathComponent("Temp", isDirectory: true)
    static let settings = support.appendingPathComponent("settings.json")
    static let launchLog = support.appendingPathComponent("launch.log")
    static let carCache = support.appendingPathComponent("car-cache.json")
    static let seasonCache = support.appendingPathComponent("season-cache.json")
    static let gameIndex = support.appendingPathComponent("game-index.json")
}

enum LauncherError: LocalizedError {
    case unreadableArchive(String, String)
    case missingFromArchive(String, String)
    case sessionActive
    case toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .unreadableArchive(name, detail):
            return "Couldn't read \(name). \(detail)".trimmingCharacters(in: .whitespacesAndNewlines)
        case let .missingFromArchive(name, member):
            return "\(member) couldn't be unpacked from \(name)."
        case .sessionActive:
            return "Mods from a previous launch are still installed. Restore the original files first."
        case let .toolFailed(tool, detail):
            return "\(tool) failed. \(detail)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Activity log

/// Plain-text record of what the launcher did — installs, launches, the game starting and closing,
/// restores — so a run that went wrong can be diagnosed afterwards. Only the app turns it on.
enum ActivityLog {
    nonisolated(unsafe) static var isEnabled = false
    static var url: URL { AppPaths.support.appendingPathComponent("activity.log") }
    private static let queue = DispatchQueue(label: "f1ml.activity-log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 2_000_000 {
                let old = AppPaths.support.appendingPathComponent("activity.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Waits for pending writes (used before quitting).
    static func flush() { queue.sync {} }
}

// MARK: - Small helpers

func pathComponents(_ path: String) -> [String] {
    path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init).filter { $0 != "." }
}

struct ProcessResult {
    let status: Int32
    let output: String
    let errorText: String
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Runs a command line tool to completion and captures its output.
func runProcess(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "en_US.UTF-8"
    environment["LANG"] = "en_US.UTF-8"
    process.environment = environment
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    process.standardInput = FileHandle.nullDevice
    try process.run()

    // Drain stderr on another thread so a chatty tool can't fill the pipe and deadlock.
    let errBox = DataBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    return ProcessResult(
        status: process.terminationStatus,
        output: String(decoding: outData, as: UTF8.self),
        errorText: String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

private func isArchive(_ url: URL) -> Bool {
    ModRules.archiveExtensions.contains(url.pathExtension.lowercased())
}

// MARK: - Archives (macOS's built-in bsdtar reads zip, rar and 7z)

enum ArchiveTool {
    static let bsdtar = "/usr/bin/bsdtar"

    /// Paths of every file (not folder) inside the archive.
    static func list(_ archive: URL) throws -> [String] {
        let result = try runProcess(bsdtar, ["-tf", archive.path])
        guard result.status == 0 else {
            throw LauncherError.unreadableArchive(archive.lastPathComponent, result.errorText)
        }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasSuffix("/") && !$0.hasSuffix("\\") }
    }

    /// Extracts exactly `members` from the archive into `directory`, keeping their archive paths.
    static func extract(_ archive: URL, members: [String], to directory: URL) throws {
        let listFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("f1ml-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listFile) }
        let patterns = members.map(escapePattern).joined(separator: "\n") + "\n"
        try patterns.write(to: listFile, atomically: true, encoding: .utf8)
        let result = try runProcess(bsdtar, ["-x", "-f", archive.path, "-C", directory.path, "-T", listFile.path])
        guard result.status == 0 else {
            throw LauncherError.unreadableArchive(archive.lastPathComponent, result.errorText)
        }
    }

    /// bsdtar treats names as patterns, so wildcard characters in real file names must be escaped.
    static func escapePattern(_ name: String) -> String {
        var escaped = ""
        for character in name {
            if "\\*?[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}

// MARK: - Mod model

struct ModFile: Hashable, Sendable {
    /// Path inside the archive.
    let member: String
    /// Path inside the game folder, "/"-separated. Empty until found for loose files.
    var relativePath: String
    /// Loose files (not inside a 2025_asset_groups-style folder) are matched to the game file with the
    /// same name; these lower-cased archive path components break ties.
    var lookup: [String]? = nil
}

/// A .dds texture in a mod, to be packed into the game's .erp files at launch.
struct ModTexture: Hashable, Sendable {
    let member: String
    /// The texture's name in the game, lower-cased, e.g. "haas_paint_d.tif".
    let key: String
    /// Lower-cased archive path components (may name a season, e.g. "2026").
    let hints: [String]
}

/// Where a mod texture goes: which .erp file and which texture inside it.
struct TextureTarget: Hashable, Codable, Sendable {
    let member: String
    /// Game-relative path of the .erp file.
    let erp: String
    /// Texture (surface) name inside the .erp, e.g. eaid://f1_2026_vehicle_package/teams/haas/textures/haas_paint_d.tif.image
    let surface: String
    let season: String?
}

/// A car a mod changes, e.g. Haas / "2025" — F1 25 has separate 2025 and 2026 cars for every team.
struct CarTarget: Hashable, Codable, Sendable {
    let team: String
    /// "2025", "2026", "F2 2025", "2025 story"… nil if the mod's paths don't say.
    let season: String?

    var description: String { season.map { "\(team) (\($0) car)" } ?? team }
}

struct ModEntry: Identifiable, Hashable, Sendable {
    let id: String
    let archiveID: String
    let archiveURL: URL
    let archiveName: String
    /// Archive name for single mods, variant name for multi-variant archives.
    let title: String
    let isVariant: Bool
    var files: [ModFile]
    var textures: [ModTexture] = []
    /// Where the textures go, for the chosen season.
    var textureTargets: [TextureTarget] = []
    /// Seasons whose cars have these textures, newest first, and the one chosen.
    var textureSeasons: [String] = []
    var textureSeason: String?
    let needsBaseFiles: Bool
    let isBaseFiles: Bool
    /// Cars this mod changes, from its folder paths or the texture names inside its .erp files.
    var cars: [CarTarget]

    var displayName: String { isVariant ? "\(archiveName) › \(title)" : title }

    /// Lower-cased game paths (and textures), used to spot mods that change the same things.
    var fileKeys: Set<String> {
        Set(files.map { $0.relativePath.lowercased() } + textureTargets.map { "texture:\($0.erp.lowercased())#\($0.surface)" })
    }

    var teams: [String] {
        cars.map(\.team).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    var isTextureMod: Bool { !textures.isEmpty }

    /// e.g. "Haas — 2025 car · 3 files".
    var summary: String {
        var counts: [String] = []
        if !files.isEmpty { counts.append(files.count == 1 ? "1 file" : "\(files.count) files") }
        if !textures.isEmpty { counts.append(textures.count == 1 ? "1 texture" : "\(textures.count) textures") }
        let count = counts.isEmpty ? "nothing to install" : counts.joined(separator: ", ")
        guard !cars.isEmpty else { return count }
        let seasons = cars.map(\.season).reduce(into: [String?]()) { if !$0.contains($1) { $0.append($1) } }
        let what: String
        if seasons.count == 1, let season = seasons[0] {
            what = "\(teams.joined(separator: ", ")) — \(season) car\(teams.count > 1 ? "s" : "")"
        } else if seasons == [nil] {
            if teams == [title] { return count }
            what = teams.joined(separator: ", ")
        } else {
            what = cars.map { car in car.season.map { "\(car.team) \($0)" } ?? car.team }.joined(separator: ", ")
        }
        return "\(what) · \(count)"
    }
}

struct ModArchive: Identifiable, Hashable, Sendable {
    /// Path relative to the mods folder, e.g. "My Team/Livery.zip".
    let id: String
    let url: URL
    let name: String
    /// Sub-folder of the mods folder the archive lives in.
    let category: String?
    let entries: [ModEntry]
    let isBaseFiles: Bool

    var hasVariants: Bool { entries.count > 1 }
}

enum ModParser {
    /// Loose files with these types are matched to game files by name. (Loose .png/.pdf files are
    /// usually previews and read-mes, so they're left out.)
    static let looseExtensions: Set<String> = ["erp", "bk2", "bdl", "mipmaps", "lng"]

    static func isJunk(_ parts: [String]) -> Bool {
        guard let last = parts.last else { return true }
        return last.hasPrefix("._") || last.hasPrefix(".") || parts.contains { $0 == "__MACOSX" || $0 == ".." }
    }

    /// "haas_paint_d.tif.dds" → "haas_paint_d.tif"
    static func textureKey(forDDS fileName: String) -> String {
        var name = fileName.lowercased()
        if name.hasSuffix(".dds") { name.removeLast(4) }
        if name.hasSuffix(".image") { name.removeLast(6) }
        return name
    }

    /// Splits an archive into one entry per variant. Files inside a SERPs-style folder
    /// ("…/2025_asset_groups/…") keep their game path, the way SERPs Launcher does it. Everything else —
    /// .dds textures and loose game files — is grouped and matched to the game later.
    static func parse(members: [String], archiveID: String, url: URL, name: String) -> (entries: [ModEntry], isBaseFiles: Bool) {
        let isBaseFiles = members.contains { pathComponents($0).last?.lowercased() == ModRules.baseFilesMarker }
        let items = members.map { ($0, pathComponents($0)) }.filter { !isJunk($0.1) }

        var roots = Set<[String]>()
        for (_, parts) in items {
            if let index = parts.firstIndex(where: { ModRules.signatureFolders.contains($0.lowercased()) }) {
                roots.insert(Array(parts[..<index]))
            }
        }
        // Most specific root first, so nested variants don't swallow each other.
        let orderedRoots = roots.sorted { $0.count > $1.count }
        func root(of parts: [String]) -> [String]? {
            orderedRoots.first { parts.count > $0.count && Array(parts[..<$0.count]) == $0 }
        }

        struct Group { var files: [ModFile] = []; var textures: [ModTexture] = []; var seen = Set<String>() }
        var grouped: [[String]: Group] = [:]
        var loose: [(parts: [String], file: ModFile?, texture: ModTexture?)] = []
        for (member, parts) in items {
            guard let fileName = parts.last else { continue }
            let lower = fileName.lowercased()
            let ext = (lower as NSString).pathExtension
            // Leave EA anti-cheat files alone (some packs ship a replacement splash image).
            guard !lower.hasPrefix("eaanticheat") else { continue }
            let hints = parts.dropLast().map { $0.lowercased() }
            if ext == "dds" {
                let texture = ModTexture(member: member, key: textureKey(forDDS: fileName), hints: hints)
                if let root = root(of: parts) {
                    if grouped[root, default: Group()].seen.insert("tex:" + texture.key).inserted { grouped[root]!.textures.append(texture) }
                } else {
                    loose.append((Array(parts.dropLast()), nil, texture))
                }
            } else if ModRules.installableExtensions.contains(ext) {
                if let root = root(of: parts) {
                    let relative = parts[root.count...].joined(separator: "/")
                    if grouped[root, default: Group()].seen.insert(relative.lowercased()).inserted {
                        grouped[root]!.files.append(ModFile(member: member, relativePath: relative))
                    }
                } else if looseExtensions.contains(ext) {
                    loose.append((Array(parts.dropLast()), ModFile(member: member, relativePath: "", lookup: parts.map { $0.lowercased() }), nil))
                }
            }
        }

        // Loose files form one group — unless the same name shows up twice, in which case each folder is
        // its own version. With a single SERPs-style version, loose files simply belong to it.
        if !loose.isEmpty {
            let looseNames = loose.map { item in item.texture.map { "tex:" + $0.key } ?? (item.file?.lookup?.last ?? "") }
            let byFolder = Set(looseNames).count != looseNames.count
            let common = loose.map(\.parts).reduce(loose[0].parts) { prefix, parts in
                Array(zip(prefix, parts).prefix { $0 == $1 }.map(\.0))
            }
            for item in loose {
                let key = byFolder ? item.parts : (grouped.count == 1 ? grouped.keys.first! : common)
                var group = grouped[key] ?? Group()
                if let file = item.file, group.seen.insert("loose:" + (file.lookup?.joined(separator: "/") ?? file.member)).inserted {
                    group.files.append(file)
                }
                if let texture = item.texture, group.seen.insert("tex:" + texture.key).inserted {
                    group.textures.append(texture)
                }
                grouped[key] = group
            }
        }
        grouped = grouped.filter { !$0.value.files.isEmpty || !$0.value.textures.isEmpty }
        guard !grouped.isEmpty else { return ([], isBaseFiles) }

        let isMulti = grouped.count > 1
        let titles = variantTitles(for: Array(grouped.keys))
        var entries: [ModEntry] = grouped.map { root, group in
            let files = group.files
            let basenames = Set(files.map { (pathComponents($0.relativePath.isEmpty ? $0.member : $0.relativePath).last ?? "").lowercased() })
            let needsBase = !isBaseFiles
                && !basenames.isDisjoint(with: ModRules.baseFilesDependencies)
                && !basenames.contains("words.erp")
            return ModEntry(
                id: isMulti ? "\(archiveID)::\(root.joined(separator: "/"))" : archiveID,
                archiveID: archiveID,
                archiveURL: url,
                archiveName: name,
                title: isMulti ? (titles[root] ?? name) : name,
                isVariant: isMulti,
                files: files,
                textures: group.textures,
                needsBaseFiles: needsBase,
                isBaseFiles: isBaseFiles,
                cars: cars(in: files.filter { !$0.relativePath.isEmpty })
            )
        }
        entries.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (entries, isBaseFiles)
    }

    /// Names variants by what differs between their roots, e.g. "Pack/Ferrari/F1 25" → "Ferrari".
    static func variantTitles(for roots: [[String]]) -> [[String]: String] {
        guard roots.count > 1 else { return [:] }
        let shortest = roots.map(\.count).min() ?? 0
        var prefix = 0
        while prefix < shortest, Set(roots.map { $0[prefix] }).count == 1 { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, Set(roots.map { $0[$0.count - 1 - suffix] }).count == 1 { suffix += 1 }
        var titles: [[String]: String] = [:]
        for root in roots {
            let middle = Array(root[prefix..<(root.count - suffix)])
            titles[root] = middle.isEmpty ? "Main Files" : middle.joined(separator: " › ")
        }
        return titles
    }

    /// Cars named by the mod's folder paths, e.g. …/f1_2025_vehicle_package/teams/ferrari/….
    static func cars(in files: [ModFile]) -> [CarTarget] {
        var found: [CarTarget] = []
        for file in files {
            if let car = car(fromPath: pathComponents(file.relativePath).dropLast()), !found.contains(car) {
                found.append(car)
            }
        }
        return found
    }

    /// Reads "<package>/teams/<team>/…" out of a path (folder names or an eaid:// texture name).
    static func car<C: Collection>(fromPath parts: C) -> CarTarget? where C.Element == String {
        let parts = Array(parts)
        guard let index = parts.firstIndex(where: { $0.lowercased() == "teams" }), index + 1 < parts.count else { return nil }
        let folder = parts[index + 1].lowercased()
        guard !folder.isEmpty, !folder.contains("."), folder != "common", folder != "shared" else { return nil }
        let season = parts[..<index].reversed().lazy.compactMap(season(fromPackage:)).first
        return CarTarget(team: prettyTeamName(folder), season: season)
    }

    /// "f1_2025_vehicle_package" → "2025", "f2_2026_vehicle_package" → "F2 2026",
    /// "f1_2025_story_vehicle_package" → "2025 story".
    static func season(fromPackage name: String) -> String? {
        let parts = name.lowercased().split(separator: "_")
        guard parts.count >= 4, parts.last == "package", parts[parts.count - 2] == "vehicle",
              parts[1].count == 4, parts[1].allSatisfy(\.isNumber) else { return nil }
        let year = String(parts[1])
        let series = parts[0] == "f1" ? year : "\(parts[0].uppercased()) \(year)"
        return parts.count > 4 && parts[2] == "story" ? "\(series) story" : series
    }

    /// Cars whose textures are inside an .erp file. Many SERPs liveries ship as shader packages
    /// (e.g. shader_package_2025/vehicle_metallic_paint…erp) whose folder names say nothing about
    /// the car; the texture names inside do: eaid://f1_2025_vehicle_package/teams/haas/textures/….
    static func cars(inERP data: Data) -> [CarTarget] {
        let needle = Data("eaid://".utf8)
        var found: [CarTarget] = []
        var searchStart = data.startIndex
        while let match = data.range(of: needle, in: searchStart..<data.endIndex) {
            var end = match.upperBound
            while end < data.endIndex, end - match.upperBound < 200, data[end] > 0x20, data[end] < 0x7F { end += 1 }
            let path = String(decoding: data[match.upperBound..<end], as: UTF8.self)
            let parts = path.split(separator: "/").map(String.init)
            // Only texture/material names count — not the paths of the shaders themselves.
            if parts.count > 3, let car = car(fromPath: parts.dropLast()), car.season != nil, !found.contains(car) {
                found.append(car)
            }
            searchStart = end
        }
        return found
    }

    static func prettyTeamName(_ folder: String) -> String {
        let known = ["mclaren": "McLaren", "gm_cadillac": "Cadillac", "fom_car": "FOM Car", "red_bull": "Red Bull",
                     "redbull": "Red Bull", "toro_rosso": "Racing Bulls", "sauber": "Sauber", "force_india": "Aston Martin",
                     "lotus": "Alpine", "alphatauri": "AlphaTauri", "rb": "RB", "vcarb": "VCARB",
                     "my_team": "My Team", "myteam": "My Team"]
        let lower = folder.lowercased()
        if let name = known[lower] { return name }
        if lower.hasPrefix("myteam_") { return "My Team (\(prettyTeamName(String(lower.dropFirst(7)))))" }
        return folder.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Mod library (the Mods folder; each sub-folder is a category)

final class ModLibrary: @unchecked Sendable {
    let root: URL
    private let tempRoot: URL
    private let carCacheFile: URL?
    private var cache: [String: (size: Int, modified: Date, members: [String])] = [:]
    /// "archive path|size|date|member" → cars found inside that .erp. Saved, so each file is read once.
    private var carCache: [String: [CarTarget]] = [:]
    /// "archive stamp|entry id" → the season whose car the mod's textures look most like.
    private var seasonCache: [String: String] = [:]
    private let seasonCacheFile: URL?
    private let lock = NSLock()

    init(root: URL, tempRoot: URL, carCacheFile: URL? = nil, seasonCacheFile: URL? = nil) {
        self.root = root
        self.tempRoot = tempRoot
        self.carCacheFile = carCacheFile
        self.seasonCacheFile = seasonCacheFile
        if let carCacheFile, let data = try? Data(contentsOf: carCacheFile),
           let saved = try? JSONDecoder().decode([String: [CarTarget]].self, from: data) {
            carCache = saved
        }
        if let seasonCacheFile, let data = try? Data(contentsOf: seasonCacheFile),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            seasonCache = saved
        }
    }

    struct ScanResult: Sendable {
        var archives: [ModArchive] = []
        var categories: [String] = []
        var problems: [String] = []
    }

    /// Reads the mods folder. With the game's index, loose files and .dds textures are matched to the
    /// game; `seasons` holds the player's choice of car per texture mod ("2025", "2026", "all").
    func scan(game: GameIndex? = nil, seasons: [String: String] = [:]) -> ScanResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var result = ScanResult()
        var found: [(URL, String?)] = []
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in top {
            if isDirectory(url) {
                result.categories.append(url.lastPathComponent)
                let inner = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for file in inner where isArchive(file) { found.append((file, url.lastPathComponent)) }
            } else if isArchive(url) {
                found.append((url, nil))
            }
        }
        for (url, category) in found {
            let id = category.map { "\($0)/\(url.lastPathComponent)" } ?? url.lastPathComponent
            do {
                let parsed = ModParser.parse(members: try members(of: url), archiveID: id, url: url,
                                             name: url.deletingPathExtension().lastPathComponent)
                let archiveMembers = try members(of: url)
                if let reason = Self.notAnF125Mod(archiveMembers) {
                    result.problems.append("\(id): \(reason)")
                    continue
                }
                let resolved = resolve(parsed.entries, archive: url, game: game, seasons: seasons)
                result.problems += resolved.problems.map { "\(id): \($0)" }
                if resolved.entries.isEmpty {
                    if resolved.problems.isEmpty {
                        result.problems.append("\(id) has nothing the launcher recognises — no game files, no .dds textures.")
                    }
                    continue
                }
                let entries = parsed.isBaseFiles ? resolved.entries : addCarsFromERPs(resolved.entries, archive: url)
                result.archives.append(ModArchive(id: id, url: url, name: url.deletingPathExtension().lastPathComponent,
                                                  category: category, entries: entries, isBaseFiles: parsed.isBaseFiles))
            } catch {
                result.problems.append(error.localizedDescription)
            }
        }
        result.archives.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.categories.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return result
    }

    /// Matches loose files and .dds textures to the game. Entries left with nothing to install are dropped.
    func resolve(_ entries: [ModEntry], archive: URL, game: GameIndex?, seasons: [String: String]) -> (entries: [ModEntry], problems: [String]) {
        var problems: [String] = []
        var result: [ModEntry] = []
        for var entry in entries {
            // Loose files: the game file with the same name.
            var files: [ModFile] = []
            var unmatched: [String] = []
            for file in entry.files {
                if !file.relativePath.isEmpty {
                    // Pictures and PDFs are usually previews and read-mes: only install ones the game has.
                    let ext = (file.relativePath as NSString).pathExtension.lowercased()
                    if ["png", "pdf"].contains(ext), let game, !game.hasFile(file.relativePath) { continue }
                    files.append(file)
                    continue
                }
                if let lookup = file.lookup, let path = game?.gamePath(forLoose: lookup) {
                    var matched = file
                    matched.relativePath = path
                    if !files.contains(where: { $0.relativePath.lowercased() == path.lowercased() }) { files.append(matched) }
                } else {
                    unmatched.append(pathComponents(file.member).last ?? file.member)
                }
            }
            if !unmatched.isEmpty {
                problems.append(game == nil ? "waiting for the game folder to match \(unmatched.count) loose file(s)."
                    : "couldn't tell where \(ListFormatter.localizedString(byJoining: unmatched)) go\(unmatched.count == 1 ? "es" : "") in the game.")
            }
            entry.files = files
            entry.cars += ModParser.cars(in: files).filter { !entry.cars.contains($0) }

            // Textures: which .erp holds each one, for the chosen season's car.
            if !entry.textures.isEmpty, let game {
                var places: [ModTexture: [GameIndex.Place]] = [:]
                var unknown: [String] = []
                for texture in entry.textures {
                    let found = game.places(forTexture: texture.key)
                    if found.isEmpty { unknown.append(texture.key) } else { places[texture] = found }
                }
                if !unknown.isEmpty {
                    problems.append("ignored \(unknown.count) .dds file(s) that don't match any F1 25 texture: \(ListFormatter.localizedString(byJoining: unknown)).")
                }
                entry.textures = entry.textures.filter { places[$0] != nil }
                let options = Self.orderedSeasons(Set(places.values.flatMap { $0.map { GameIndex.season(of: $0) ?? "other" } }))
                entry.textureSeasons = options
                if let chosen = chooseSeason(for: entry, options: options, places: places, archive: archive, game: game, override: seasons[entry.id]) {
                    entry.textureSeason = chosen
                    for (texture, found) in places {
                        for place in found where chosen == "all" || (GameIndex.season(of: place) ?? "other") == chosen {
                            entry.textureTargets.append(TextureTarget(member: texture.member, erp: place.erp,
                                                                      surface: place.surface, season: GameIndex.season(of: place)))
                        }
                    }
                    entry.textureTargets.sort { ($0.erp, $0.surface) < ($1.erp, $1.surface) }
                    for target in entry.textureTargets {
                        let body = target.surface.hasPrefix("eaid://") ? String(target.surface.dropFirst(7)) : target.surface
                        if let car = ModParser.car(fromPath: body.split(separator: "/").map(String.init).dropLast()),
                           !entry.cars.contains(car) {
                            entry.cars.append(car)
                        }
                    }
                }
            } else if !entry.textures.isEmpty {
                problems.append("waiting for the game folder to place \(entry.textures.count) texture(s).")
            }

            if !entry.files.isEmpty || !entry.textureTargets.isEmpty { result.append(entry) }
        }
        return (result, problems)
    }

    /// Recognises mods made for other games, so the player gets a clear answer instead of a silent no.
    static func notAnF125Mod(_ members: [String]) -> String? {
        let names = Set(members.compactMap { pathComponents($0).last?.lowercased() })
        if names.contains("skin.ini") || names.contains("ui_skin.json") || names.contains("ext_config.ini") {
            return "this is an Assetto Corsa skin (it has skin.ini / ui_skin.json), not an F1 25 mod — it only works in Assetto Corsa."
        }
        return nil
    }

    /// Newest cars first: 2026 before 2025, F1 before F2, the main game before story mode.
    static func orderedSeasons(_ seasons: Set<String>) -> [String] {
        func rank(_ season: String) -> (Int, Int, Int) {
            let year = Int(season.filter(\.isNumber).prefix(4)) ?? 0
            return (-year, season.hasPrefix("F2") ? 1 : 0, season.contains("story") ? 1 : (season == "other" ? 2 : 0))
        }
        return seasons.sorted { rank($0) < rank($1) }
    }

    /// The player's choice; else a season named in the mod's folders; else the car whose original
    /// textures the mod's textures look most like; else the newest.
    private func chooseSeason(for entry: ModEntry, options: [String], places: [ModTexture: [GameIndex.Place]],
                              archive: URL, game: GameIndex, override: String?) -> String? {
        guard !options.isEmpty else { return nil }
        if let override, override == "all" || options.contains(override) { return override }
        if options.count == 1 { return options[0] }
        // Only the game's own package folder names count ("f1_2026_vehicle_package"); names like
        // "2026 Livery" often describe the livery, not the car it's for.
        let hinted = Set(entry.textures.flatMap(\.hints).compactMap(ModParser.season(fromPackage:)))
        if hinted.count == 1, let season = hinted.first, options.contains(season) { return season }
        let values = try? archive.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(archive.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(entry.id)|\(options.joined(separator: ","))"
        lock.lock()
        let cached = seasonCache[key]
        lock.unlock()
        if let cached, options.contains(cached) { return cached }

        var best: (season: String, score: Double)?
        let sample = entry.textures.filter { places[$0] != nil }.sorted { $0.key < $1.key }.prefix(3)
        let work = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        if !sample.isEmpty, (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil,
           (try? ArchiveTool.extract(archive, members: sample.map(\.member), to: work)) != nil {
            let images = sample.compactMap { texture -> (ModTexture, DDSImage)? in
                guard let data = try? Data(contentsOf: work.appendingPathComponent(texture.member)),
                      let dds = try? DDSImage(data: data) else { return nil }
                return (texture, dds)
            }
            var opened: [String: ERPArchive] = [:]
            for option in options where option != "other" {
                var total = 0.0, counted = 0
                for (texture, dds) in images {
                    guard let place = places[texture]?.first(where: { GameIndex.season(of: $0) == option }) else { continue }
                    if opened[place.erp] == nil { opened[place.erp] = try? ERPArchive(url: game.gameDir.appendingPathComponent(place.erp)) }
                    guard let erp = opened[place.erp], let difference = TextureInjector.difference(dds, from: erp, surface: place.surface) else { continue }
                    total += difference; counted += 1
                }
                if counted > 0, best == nil || total / Double(counted) < best!.score {
                    best = (option, total / Double(counted))
                }
            }
        }
        let chosen = best?.season ?? options[0]
        lock.lock()
        seasonCache[key] = chosen
        let snapshot = seasonCache
        lock.unlock()
        if let seasonCacheFile, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: seasonCacheFile, options: .atomic) }
        ActivityLog.write("\(entry.displayName): textures look most like the \(chosen) car\(best.map { String(format: " (difference %.1f)", $0.score) } ?? "")")
        return chosen
    }

    /// Looks inside .erp files that aren't in a team folder (e.g. SERPs shader-package liveries) to
    /// find which cars they change.
    private func addCarsFromERPs(_ entries: [ModEntry], archive: URL) -> [ModEntry] {
        let values = try? archive.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(archive.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        func key(_ member: String) -> String { "\(stamp)|\(member)" }
        func needsLook(_ file: ModFile) -> Bool {
            file.relativePath.lowercased().hasSuffix(".erp")
                && ModParser.car(fromPath: pathComponents(file.relativePath).dropLast()) == nil
        }

        lock.lock()
        let unknown = entries.flatMap(\.files).filter { needsLook($0) && carCache[key($0.member)] == nil }.map(\.member)
        lock.unlock()
        if !unknown.isEmpty {
            let work = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var found: [String: [CarTarget]] = [:]
            if (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil,
               (try? ArchiveTool.extract(archive, members: unknown, to: work)) != nil {
                for member in unknown {
                    guard let data = try? Data(contentsOf: work.appendingPathComponent(member), options: .mappedIfSafe) else { continue }
                    found[key(member)] = ModParser.cars(inERP: data)
                }
            }
            lock.lock()
            carCache.merge(found) { $1 }
            let snapshot = carCache
            lock.unlock()
            if let carCacheFile, let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: carCacheFile, options: .atomic)
            }
        }

        lock.lock()
        defer { lock.unlock() }
        return entries.map { entry in
            var entry = entry
            for file in entry.files where needsLook(file) {
                for car in carCache[key(file.member)] ?? [] where !entry.cars.contains(car) { entry.cars.append(car) }
            }
            return entry
        }
    }

    /// Archive listing, cached by size and modification date.
    func members(of url: URL) throws -> [String] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? -1
        let modified = values.contentModificationDate ?? .distantPast
        lock.lock()
        if let cached = cache[url.path], cached.size == size, cached.modified == modified {
            lock.unlock()
            return cached.members
        }
        lock.unlock()
        let members = try ArchiveTool.list(url)
        lock.lock()
        cache[url.path] = (size, modified, members)
        lock.unlock()
        return members
    }

    struct ImportResult: Sendable {
        var added: [String] = []
        var failures: [String] = []
    }

    /// Copies archives (or zips folders) into the library after checking they contain F1 25 files.
    func importItems(_ urls: [URL], game: GameIndex? = nil) -> ImportResult {
        let fm = FileManager.default
        var result = ImportResult()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for url in urls {
            let name = url.lastPathComponent
            var workDir: URL?
            defer { if let workDir { try? fm.removeItem(at: workDir) } }
            do {
                var source = url
                if isDirectory(url) {
                    let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    workDir = dir
                    source = dir.appendingPathComponent("\(name).zip")
                    let zip = try runProcess("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl",
                                                                "--keepParent", url.path, source.path])
                    guard zip.status == 0 else { throw LauncherError.toolFailed("Zipping \(name)", zip.errorText) }
                } else if !isArchive(url) {
                    result.failures.append("\(name) isn't a .zip, .rar or .7z file.")
                    continue
                }
                if source.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") {
                    continue // already in the library
                }
                let listing = try ArchiveTool.list(source)
                if let reason = Self.notAnF125Mod(listing) {
                    result.failures.append("\(name): \(reason)")
                    continue
                }
                let parsed = ModParser.parse(members: listing, archiveID: name, url: source, name: name)
                guard !parsed.entries.isEmpty else {
                    result.failures.append("\(name) doesn't contain any F1 25 game files or .dds textures.")
                    continue
                }
                if let game {
                    let resolved = resolve(parsed.entries, archive: source, game: game, seasons: [:])
                    guard !resolved.entries.isEmpty else {
                        result.failures.append("\(name): " + (resolved.problems.first ?? "none of its files match anything in F1 25."))
                        continue
                    }
                }
                let destination = uniqueURL(root.appendingPathComponent(source.lastPathComponent))
                try fm.copyItem(at: source, to: destination)
                result.added.append(destination.deletingPathExtension().lastPathComponent)
            } catch {
                result.failures.append("\(name): \(error.localizedDescription)")
            }
        }
        return result
    }

    func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var number = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    /// Moves an archive into `category` (nil = top level) and/or renames it. Returns the new archive ID.
    func move(_ archive: ModArchive, toCategory category: String?, newName: String? = nil) throws -> String {
        let fm = FileManager.default
        let folder = category.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = (newName ?? archive.name) + "." + archive.url.pathExtension
        var destination = folder.appendingPathComponent(fileName)
        let newPath = destination.standardizedFileURL.path
        let oldPath = archive.url.standardizedFileURL.path
        if newPath.lowercased() == oldPath.lowercased() {
            // Same file (maybe a case-only rename, which FileManager refuses on case-insensitive disks).
            if newPath != oldPath, rename(oldPath, newPath) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } else {
            destination = uniqueURL(destination)
            try fm.moveItem(at: archive.url, to: destination)
        }
        return category.map { "\($0)/\(destination.lastPathComponent)" } ?? destination.lastPathComponent
    }
}

// MARK: - Installing and restoring

struct FileStamp: Codable, Equatable, Sendable {
    let size: UInt64
    let modified: Double

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date else { return nil }
        self.size = size.uint64Value
        self.modified = date.timeIntervalSinceReferenceDate
    }
}

struct InstallSession: Codable, Sendable {
    var gamePath: String
    var startedAt: Date
    var modIDs: [String]
    var modNames: [String]
    /// What each installed file looked like right after installing, so a game update made while mods
    /// were in place isn't overwritten with a stale backup.
    var installed: [String: FileStamp]
    /// Folders that didn't exist before, removed again (if empty) on restore.
    var createdFolders: [String]?
    var complete: Bool
}

struct RestoreReport: Sendable {
    var restored = 0
    var removed = 0
    var keptGameUpdates = 0
    var failures: [String] = []
}

/// Keeps the on-disk casing of existing game folders and files, so restoring never renames anything.
final class CaseResolver {
    private let base: URL
    private var listings: [String: [String]] = [:]

    init(base: URL) { self.base = base }

    func resolve(_ relativePath: String) -> String {
        var directory = base
        var resolved: [String] = []
        for component in pathComponents(relativePath) {
            let names = listing(of: directory)
            let actual = names.first { $0 == component }
                ?? names.first { $0.caseInsensitiveCompare(component) == .orderedSame }
                ?? component
            resolved.append(actual)
            directory = directory.appendingPathComponent(actual)
        }
        return resolved.joined(separator: "/")
    }

    private func listing(of directory: URL) -> [String] {
        if let cached = listings[directory.path] { return cached }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        listings[directory.path] = names
        return names
    }
}

/// Backups/originals/<path>  – game files moved aside while mods are installed
/// Backups/added/<path>      – empty markers for files that mods added (removed again on restore)
/// Backups/session.json      – what was installed, and where
final class Installer: @unchecked Sendable {
    let stateDir: URL
    let tempDir: URL
    private let fm = FileManager.default

    var originalsDir: URL { stateDir.appendingPathComponent("originals", isDirectory: true) }
    var addedDir: URL { stateDir.appendingPathComponent("added", isDirectory: true) }
    var sessionFile: URL { stateDir.appendingPathComponent("session.json") }

    init(stateDir: URL, tempDir: URL) {
        self.stateDir = stateDir
        self.tempDir = tempDir
    }

    var hasActiveSession: Bool {
        fm.fileExists(atPath: sessionFile.path) || !files(under: originalsDir).isEmpty || !files(under: addedDir).isEmpty
    }

    func loadSession() -> InstallSession? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallSession.self, from: data)
    }

    private func save(_ session: InstallSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try encoder.encode(session).write(to: sessionFile, options: .atomic)
    }

    func install(_ entries: [ModEntry], into gameDir: URL, progress: (Double, String) -> Void) throws {
        guard !hasActiveSession else { throw LauncherError.sessionActive }
        var session = InstallSession(gamePath: gameDir.path, startedAt: Date(), modIDs: entries.map(\.id),
                                     modNames: entries.map(\.displayName), installed: [:], complete: false)
        try save(session)

        ActivityLog.write("Installing \(entries.count) mod(s) into \(gameDir.path)")
        let total = Double(max(1, entries.reduce(0) { $0 + $1.files.count + $1.textureTargets.count }))
        var done = 0.0
        var createdFolders: [String] = []
        let resolver = CaseResolver(base: gameDir)
        for entry in entries where !entry.files.isEmpty {
            ActivityLog.write("• \(entry.displayName) — \(entry.files.count) file(s) from \(entry.archiveURL.lastPathComponent)")
            progress(done / total, "Unpacking \(entry.displayName)…")
            let work = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            try ArchiveTool.extract(entry.archiveURL, members: entry.files.map(\.member), to: work)

            progress(done / total, "Installing \(entry.displayName)…")
            for file in entry.files {
                let source = work.appendingPathComponent(file.member)
                guard fm.fileExists(atPath: source.path) else {
                    throw LauncherError.missingFromArchive(entry.archiveURL.lastPathComponent, file.member)
                }
                let relative = resolver.resolve(file.relativePath)
                let destination = gameDir.appendingPathComponent(relative)
                let folders = pathComponents(relative).dropLast()
                for depth in folders.indices {
                    let folder = folders[...depth].joined(separator: "/")
                    if !fm.fileExists(atPath: gameDir.appendingPathComponent(folder).path), !createdFolders.contains(folder) {
                        createdFolders.append(folder)
                        session.createdFolders = createdFolders
                    }
                }
                let expectedSize = FileStamp(source)?.size
                let replaced = try place(source, at: destination, relativePath: relative)
                // Check the file really is in the game folder, with the size it had in the archive.
                guard let placed = FileStamp(destination), placed.size == expectedSize else {
                    ActivityLog.write("    FAILED to place \(relative)")
                    throw LauncherError.toolFailed("Installing \(relative)", "The file didn't end up in the game folder.")
                }
                ActivityLog.write("    \(replaced ? "replaced" : "added") \(relative) (\(placed.size) bytes)")
                session.installed[relative] = placed
                done += 1
            }
            try save(session)
        }
        // Texture mods: pack the .dds files into the game's .erp files. Several mods can paint into the
        // same .erp; it's built from whatever is in the game folder now (so it stacks on file mods too).
        let painting = entries.flatMap { entry in entry.textureTargets.map { (entry, $0) } }
        for (erpPath, items) in Dictionary(grouping: painting, by: { $0.1.erp }).sorted(by: { $0.key < $1.key }) {
            let relative = resolver.resolve(erpPath)
            let fileName = (relative as NSString).lastPathComponent
            progress(done / total, "Painting \(items.count) texture(s) into \(fileName)…")
            ActivityLog.write("• Textures → \(relative): " + items.map { "\($0.0.displayName)/\(pathComponents($0.1.member).last ?? $0.1.member)" }.joined(separator: ", "))
            let work = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }

            var images: [String: DDSImage] = [:]
            for (archive, group) in Dictionary(grouping: items, by: { $0.0.archiveURL }) {
                let folder = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let members = Array(Set(group.map { $0.1.member }))
                try ArchiveTool.extract(archive, members: members, to: folder)
                for member in members {
                    let url = folder.appendingPathComponent(member)
                    guard fm.fileExists(atPath: url.path) else {
                        throw LauncherError.missingFromArchive(archive.lastPathComponent, member)
                    }
                    do {
                        images["\(archive.path)|\(member)"] = try DDSImage(data: Data(contentsOf: url, options: .mappedIfSafe))
                    } catch {
                        throw LauncherError.toolFailed("Reading \(pathComponents(member).last ?? member)", error.localizedDescription)
                    }
                }
            }

            let destination = gameDir.appendingPathComponent(relative)
            let built = work.appendingPathComponent(fileName)
            do {
                let erp = try ERPArchive(url: destination)
                let textures = items.compactMap { item -> (surface: String, dds: DDSImage)? in
                    images["\(item.0.archiveURL.path)|\(item.1.member)"].map { (item.1.surface, $0) }
                }
                let replacements = try TextureInjector.replacements(in: erp, textures: textures)
                try erp.write(to: built, replacing: replacements)
                // Check the new file reads back, with every replaced texture complete.
                let check = try ERPArchive(url: built)
                for (surface, dds) in textures {
                    guard let resource = check.resource(named: surface), resource.fragments.count == 2 else {
                        throw LauncherError.toolFailed("Checking \(fileName)", "\(surface) is missing.")
                    }
                    let header = GameTexture.Header(raw: try check.unpacked(resource.fragments[0]))
                    ActivityLog.write("    painted \(GameIndex.textureKey(ofSurface: surface)): \(dds.width)×\(dds.height), "
                        + "\(header.mips) mip level(s), format \(header.format)")
                }
            } catch let error as LauncherError {
                throw error
            } catch {
                throw LauncherError.toolFailed("Packing textures into \(fileName)", error.localizedDescription)
            }
            let replaced = try place(built, at: destination, relativePath: relative)
            guard let placed = FileStamp(destination) else {
                throw LauncherError.toolFailed("Installing \(relative)", "The file didn't end up in the game folder.")
            }
            ActivityLog.write("    \(replaced ? "replaced" : "added") \(relative) (\(placed.size) bytes)")
            session.installed[relative] = placed
            done += Double(items.count)
            try save(session)
        }

        session.complete = true
        try save(session)
        ActivityLog.write("Install finished and verified: \(session.installed.count) file(s) in place")
        progress(1, "Mods installed")
    }

    /// Puts `source` at `destination`, setting the game's own file aside first. Returns true if a game
    /// file was replaced, false if the file is new to the game folder.
    @discardableResult
    private func place(_ source: URL, at destination: URL, relativePath: String) throws -> Bool {
        let backup = originalsDir.appendingPathComponent(relativePath)
        let marker = addedDir.appendingPathComponent(relativePath)
        let existed = fm.fileExists(atPath: destination.path)
        if existed {
            if fm.fileExists(atPath: backup.path) || fm.fileExists(atPath: marker.path) {
                try fm.removeItem(at: destination) // already a modded copy from this session
            } else {
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: destination, to: backup)
            }
        } else {
            try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: marker.path, contents: nil) else {
                throw LauncherError.toolFailed("Recording \(relativePath)", "")
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fm.moveItem(at: source, to: destination)
        return existed
    }

    func restore(fallbackGameDir: URL?, progress: (Double, String) -> Void) -> RestoreReport {
        var report = RestoreReport()
        let session = loadSession()
        guard let gamePath = session?.gamePath ?? fallbackGameDir?.path else {
            report.failures.append("The game folder for the installed mods is unknown.")
            return report
        }
        let gameDir = URL(fileURLWithPath: gamePath)
        let stamps = session?.installed ?? [:]
        let added = files(under: addedDir)
        let originals = files(under: originalsDir)
        let total = Double(max(1, added.count + originals.count))
        var done = 0.0
        ActivityLog.write("Restoring \(gameDir.path): \(originals.count) original(s) to put back, \(added.count) added file(s) to remove")
        progress(0, "Putting the original game files back…")

        for relative in added {
            let destination = gameDir.appendingPathComponent(relative)
            if let current = FileStamp(destination) {
                if let installed = stamps[relative], installed != current {
                    report.keptGameUpdates += 1 // the game replaced it since, so it isn't ours any more
                } else {
                    do {
                        try retrying { try fm.removeItem(at: destination) }
                        report.removed += 1
                    } catch {
                        report.failures.append(relative)
                        continue
                    }
                }
            }
            try? fm.removeItem(at: addedDir.appendingPathComponent(relative))
            done += 1
            progress(done / total, "Putting the original game files back…")
        }

        for relative in originals {
            let backup = originalsDir.appendingPathComponent(relative)
            let destination = gameDir.appendingPathComponent(relative)
            if let current = FileStamp(destination), let installed = stamps[relative], installed != current {
                // Steam updated this file while mods were installed, so the backup is out of date.
                try? fm.removeItem(at: backup)
                report.keptGameUpdates += 1
            } else {
                do {
                    try retrying {
                        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try replaceAtomically(destination, with: backup)
                    }
                    report.restored += 1
                } catch {
                    report.failures.append(relative)
                }
            }
            done += 1
            progress(done / total, "Putting the original game files back…")
        }

        // Deepest first, and rmdir only removes folders that are empty.
        for folder in (session?.createdFolders ?? []).sorted(by: { $0.count > $1.count }) {
            rmdir(gameDir.appendingPathComponent(folder).path)
        }

        ActivityLog.write("Restore finished: \(report.restored) put back, \(report.removed) removed, "
            + "\(report.keptGameUpdates) kept (updated by Steam), \(report.failures.count) failed \(report.failures)")
        if report.failures.isEmpty {
            try? fm.removeItem(at: originalsDir)
            try? fm.removeItem(at: addedDir)
            try? fm.removeItem(at: sessionFile)
        }
        progress(1, "Original files restored")
        return report
    }

    /// rename(2) swaps the file in one step on the same volume; fall back to remove + move otherwise.
    private func replaceAtomically(_ destination: URL, with source: URL) throws {
        if rename(source.path, destination.path) == 0 { return }
        let code = errno
        guard code == EXDEV else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: source, to: destination)
    }

    private func retrying(_ body: () throws -> Void) throws {
        var attempt = 0
        while true {
            do { return try body() } catch {
                attempt += 1
                if attempt >= 4 { throw error }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    /// Regular files under `directory`, as "/"-separated relative paths.
    func files(under directory: URL) -> [String] {
        guard let enumerator = fm.enumerator(atPath: directory.path) else { return [] }
        var result: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeRegular {
                result.append(relative)
            }
        }
        return result.sorted()
    }
}

// MARK: - Finding the game and CrossOver

enum GameLocator {
    static let bottlesDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)

    static func isGameFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(ModRules.gameExecutable).path)
    }

    static func autodetect() -> URL? {
        for bottle in bottles() {
            for library in steamLibraries(in: bottle) {
                let game = library.appendingPathComponent("steamapps/common/F1 25", isDirectory: true)
                if isGameFolder(game) { return game }
            }
        }
        return nil
    }

    static func bottles() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: bottlesDir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { isDirectory($0.appendingPathComponent("drive_c")) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func steamInstall(in bottle: URL) -> URL? {
        ["drive_c/Program Files (x86)/Steam", "drive_c/Program Files/Steam"]
            .map { bottle.appendingPathComponent($0, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("steam.exe").path) }
    }

    /// The main Steam folder plus any extra libraries listed in libraryfolders.vdf.
    static func steamLibraries(in bottle: URL) -> [URL] {
        guard let steam = steamInstall(in: bottle) else { return [] }
        var libraries = [steam]
        let vdf = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: "\"path\"\\s+\"([^\"]+)\"") {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let pathRange = Range(match.range(at: 1), in: text),
                      let url = unixPath(forWindowsPath: String(text[pathRange]), in: bottle) else { continue }
                if !libraries.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { libraries.append(url) }
            }
        }
        return libraries
    }

    static func unixPath(forWindowsPath path: String, in bottle: URL) -> URL? {
        let windows = path.replacingOccurrences(of: "\\\\", with: "\\")
        let characters = Array(windows)
        guard characters.count >= 2, characters[1] == ":" else { return nil }
        let drive = bottle.appendingPathComponent("dosdevices/\(String(characters[0]).lowercased()):").resolvingSymlinksInPath()
        guard isDirectory(drive) else { return nil }
        return pathComponents(String(windows.dropFirst(2))).reduce(drive) { $0.appendingPathComponent($1) }
    }
}

struct CrossOverTarget: Sendable, Equatable {
    let wine: URL
    let appName: String
    let bottleName: String
    let bottleRoot: URL
    let steamExe: URL

    /// Steam writes "AppID … adding PID" / "Remove … from running list" here as games start and stop.
    var steamLog: URL { steamExe.deletingLastPathComponent().appendingPathComponent("logs/gameprocess_log.txt") }
}

enum CrossOver {
    /// CrossOver's command line `wine`, preferring the copy whose wineserver is already running.
    static func wineCandidates() -> [URL] {
        var apps: [URL] = []
        if let ps = try? runProcess("/bin/ps", ["-axo", "comm="]) {
            for line in ps.output.split(whereSeparator: \.isNewline) where line.hasSuffix("/wineserver") {
                if let range = line.range(of: ".app/Contents/SharedSupport/CrossOver/") {
                    apps.append(URL(fileURLWithPath: String(line[..<range.lowerBound]) + ".app"))
                }
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            apps += items.filter { $0.lastPathComponent.hasPrefix("CrossOver") && $0.pathExtension == "app" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return apps.map { $0.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine") }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func bottle(containing gameDir: URL) -> (name: String, root: URL)? {
        let components = gameDir.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: "Bottles"), index + 1 < components.count else { return nil }
        return (components[index + 1], URL(fileURLWithPath: NSString.path(withComponents: Array(components[...(index + 1)]))))
    }

    static func target(for gameDir: URL) -> CrossOverTarget? {
        guard let bottle = bottle(containing: gameDir), let wine = wineCandidates().first else { return nil }
        // …/Steam/steamapps/common/F1 25 → …/Steam/steam.exe, else the bottle's main Steam install.
        let sibling = gameDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("steam.exe")
        let steamExe = FileManager.default.fileExists(atPath: sibling.path)
            ? sibling
            : GameLocator.steamInstall(in: bottle.root)?.appendingPathComponent("steam.exe")
        guard let steamExe else { return nil }
        let appName = wine.pathComponents.first { $0.hasSuffix(".app") }?.replacingOccurrences(of: ".app", with: "") ?? "CrossOver"
        return CrossOverTarget(wine: wine, appName: appName, bottleName: bottle.name, bottleRoot: bottle.root, steamExe: steamExe)
    }

    /// C:\… path for a file inside the bottle's drive_c. CrossOver's --cx-app only accepts Windows paths.
    static func windowsPath(for url: URL, bottleRoot: URL) -> String? {
        let driveC = bottleRoot.appendingPathComponent("drive_c").standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > driveC.count, Array(parts[..<driveC.count]) == driveC else { return nil }
        return "C:\\" + parts[driveC.count...].joined(separator: "\\")
    }

    static func launchArguments(for target: CrossOverTarget) -> [String] {
        var arguments = ["--bottle", target.bottleName, "--no-wait"]
        if let windows = windowsPath(for: target.steamExe, bottleRoot: target.bottleRoot) {
            arguments += ["--cx-app", windows]
        } else {
            arguments.append(target.steamExe.path) // outside drive_c: a Mac path works as a plain argument
        }
        return arguments + ["-applaunch", ModRules.steamAppID]
    }

    /// Asks Steam inside the bottle to start F1 25 — the same as pressing Play in Steam.
    static func launchGame(_ target: CrossOverTarget, log: URL) throws {
        let arguments = launchArguments(for: target)
        ActivityLog.write("Asking Steam in bottle “\(target.bottleName)” to start F1 25: wine \(arguments.joined(separator: " "))")
        let process = Process()
        process.executableURL = target.wine
        process.arguments = arguments
        // Output goes to a file, not a pipe: Steam inherits it and would otherwise keep us waiting.
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try? handle.close()
        let output = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ActivityLog.write("CrossOver finished with status \(process.terminationStatus)\(output.isEmpty ? "" : ": \(output)")")
        guard process.terminationStatus == 0, !output.contains("wine:error") else {
            throw LauncherError.toolFailed("CrossOver couldn't start Steam.", output)
        }
    }
}

struct GameStatus: Equatable, Sendable {
    /// F1_25.exe itself.
    var gameProcess = false
    /// EAAntiCheat.GameServiceLauncher.exe — Steam starts this, it starts F1_25.exe and waits for it.
    var launcherProcess = false
    /// Steam's own record (gameprocess_log.txt) says F1 25 is running.
    var steamSaysRunning = false

    var isRunning: Bool { gameProcess || launcherProcess || steamSaysRunning }

    var description: String {
        var parts: [String] = []
        if gameProcess { parts.append("F1_25.exe") }
        if launcherProcess { parts.append("anti-cheat launcher") }
        if steamSaysRunning { parts.append("Steam says running") }
        return parts.isEmpty ? "not running" : parts.joined(separator: " + ")
    }
}

enum GameProcess {
    static let launcherExecutable = "EAAntiCheat.GameServiceLauncher.exe"

    /// Wine lists Windows programs in `ps` by their Windows path, e.g. C:\…\F1 25\F1_25.exe. Only the
    /// program's file name is used, so a command that merely mentions the game doesn't count.
    static func programName(_ psLine: Substring) -> String {
        let trimmed = psLine.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        return (trimmed.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? "").lowercased()
    }

    /// True if the last F1 25 event in Steam's gameprocess_log.txt is a start rather than a stop.
    static func steamLogSaysRunning(_ text: String) -> Bool {
        let id = ModRules.steamAppID
        var running = false
        for line in text.split(whereSeparator: \.isNewline) where line.contains(id) {
            if line.contains("AppID \(id) adding PID") {
                running = true
            } else if line.contains("Remove \(id) from running list") {
                running = false
            }
        }
        return running
    }

    static func status(steamLog: URL?) -> GameStatus {
        var status = GameStatus()
        guard let ps = try? runProcess("/bin/ps", ["-axo", "comm="]) else { return status }
        let names = Set(ps.output.split(whereSeparator: \.isNewline).map(programName))
        status.gameProcess = names.contains(ModRules.gameExecutable.lowercased())
        status.launcherProcess = names.contains(launcherExecutable.lowercased())
        if names.contains("steam.exe"), let steamLog, let text = tail(of: steamLog, bytes: 64 * 1024) {
            status.steamSaysRunning = steamLogSaysRunning(text)
        }
        return status
    }

    static func isRunning() -> Bool { status(steamLog: nil).isRunning }

    private static func tail(of url: URL, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > bytes ? size - bytes : 0)
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }
}

// MARK: - Settings

struct LauncherSettings: Codable {
    var gamePath: String?
    var favorites: [String] = []
    var selection: [String] = []
    var collapsed: [String] = []
    /// Which car a texture mod goes on: entry id → "2025", "2026", "all"…
    var textureSeasons: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gamePath = try container.decodeIfPresent(String.self, forKey: .gamePath)
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites) ?? []
        selection = try container.decodeIfPresent([String].self, forKey: .selection) ?? []
        collapsed = try container.decodeIfPresent([String].self, forKey: .collapsed) ?? []
        textureSeasons = try container.decodeIfPresent([String: String].self, forKey: .textureSeasons) ?? [:]
    }

    static func load() -> LauncherSettings {
        guard let data = try? Data(contentsOf: AppPaths.settings),
              let settings = try? JSONDecoder().decode(LauncherSettings.self, from: data) else { return LauncherSettings() }
        return settings
    }

    func save() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: AppPaths.settings, options: .atomic)
    }
}
