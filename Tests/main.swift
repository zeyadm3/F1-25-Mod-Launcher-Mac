import Foundation

// Exercises Core.swift against a throw-away fake game folder — never the real install.
// Usage: core-tests <scratch dir> [path to a real SERPs Base Files zip]

let fm = FileManager.default
var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)  (Tests/main.swift:\(line))")
    }
}

func write(_ text: String, _ url: URL) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

func archive(_ output: URL, format: String, from dir: URL, _ items: [String]) {
    try! fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let result = try! runProcess("/usr/bin/bsdtar", ["--format", format, "-cf", output.path, "-C", dir.path] + items)
    guard result.status == 0 else { fatalError("bsdtar failed: \(result.errorText)") }
}

let scratch = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
let root = scratch.appendingPathComponent("f1ml-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
defer { if ProcessInfo.processInfo.environment["F1ML_KEEP"] == nil { try? fm.removeItem(at: root) } else { print("kept \(root.path)") } }

let bottle = root.appendingPathComponent("Bottles/Steam", isDirectory: true)
let game = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/F1 25", isDirectory: true)
let assets = game.appendingPathComponent("2025_asset_groups")
let modsDir = root.appendingPathComponent("Mods", isDirectory: true)
let sources = root.appendingPathComponent("sources", isDirectory: true)

// Fake game install
write("exe", game.appendingPathComponent("F1_25.exe"))
write("steam", bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
write("orig vfx", assets.appendingPathComponent("vfx_package/common.erp"))
write("orig 2025", assets.appendingPathComponent("f1_2025_vehicle_package/teams/common.erp"))
write("orig ferrari", assets.appendingPathComponent("f1_2025_vehicle_package/teams/ferrari/Livery.erp"))
write("orig splash", game.appendingPathComponent("EAAntiCheat.splash.png"))
try! fm.createDirectory(at: bottle.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
try! fm.createSymbolicLink(atPath: bottle.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")

// Mod archives
let baseSrc = sources.appendingPathComponent("base")
write("base vfx", baseSrc.appendingPathComponent("F1 25/2025_asset_groups/vfx_package/common.erp"))
write("base 2025", baseSrc.appendingPathComponent("F1 25/2025_asset_groups/f1_2025_vehicle_package/teams/common.erp"))
write("base splash", baseSrc.appendingPathComponent("F1 25/EAAntiCheat.splash.png"))
write("pdf", baseSrc.appendingPathComponent("SERPs Base Files for F1 25 - Read Me.pdf"))
archive(modsDir.appendingPathComponent("SERPs Base Files.zip"), format: "zip", from: baseSrc,
        ["F1 25", "SERPs Base Files for F1 25 - Read Me.pdf"])

let packSrc = sources.appendingPathComponent("pack")
let ferrari = "Livery Pack/Ferrari/F1 25/2025_asset_groups/f1_2025_vehicle_package/teams/ferrari"
write("mod ferrari", packSrc.appendingPathComponent("\(ferrari)/livery.erp"))
write("mod decal", packSrc.appendingPathComponent("\(ferrari)/new_decal.erp"))
write("mod mclaren", packSrc.appendingPathComponent("Livery Pack/McLaren/F1 25/2025_asset_groups/f1_2025_vehicle_package/teams/mclaren/livery.erp"))
write("readme", packSrc.appendingPathComponent("Livery Pack/readme.txt"))
write("junk", packSrc.appendingPathComponent("__MACOSX/Livery Pack/Ferrari/F1 25/2025_asset_groups/._livery.erp"))
archive(modsDir.appendingPathComponent("Livery Pack.zip"), format: "zip", from: packSrc, ["Livery Pack", "__MACOSX"])

let weirdSrc = sources.appendingPathComponent("weird")
write("mod fonts", weirdSrc.appendingPathComponent("2025_asset_groups/ui_package/fonts.erp"))
write("mod particle", weirdSrc.appendingPathComponent("2025_asset_groups/vfx_package/particles/x[1].erp"))
archive(modsDir.appendingPathComponent("Category A/[Weird] Mod*.7z"), format: "7zip", from: weirdSrc, ["2025_asset_groups"])

let notModSrc = sources.appendingPathComponent("notmod")
write("hello", notModSrc.appendingPathComponent("readme.txt"))
archive(modsDir.appendingPathComponent("Not a mod.zip"), format: "zip", from: notModSrc, ["readme.txt"])

let library = ModLibrary(root: modsDir, tempRoot: root.appendingPathComponent("Temp"))
let installer = Installer(stateDir: root.appendingPathComponent("Backups"), tempDir: root.appendingPathComponent("Temp"))

print("Scanning the library")
let scan = library.scan()
check(scan.archives.count == 3, "finds the 3 mod archives (got \(scan.archives.map(\.id)))")
check(scan.problems.count == 1 && scan.problems[0].contains("Not a mod.zip"), "reports the archive without game files")
check(scan.categories == ["Category A"], "sub-folders become categories")

let base = scan.archives.first { $0.isBaseFiles }
check(base?.entries.count == 1, "base files are one entry")
check(base?.entries.first?.files.count == 2, "base files install 2 files, skipping the anti-cheat splash and the PDF")

let pack = scan.archives.first { $0.name == "Livery Pack" }
check(pack?.entries.map(\.title) == ["Ferrari", "McLaren"], "variants are named by what differs (got \(pack?.entries.map(\.title) ?? []))")
let ferrariEntry = pack?.entries.first { $0.title == "Ferrari" }
check(ferrariEntry?.files.count == 2, "__MACOSX junk is ignored")
check(ferrariEntry?.teams == ["Ferrari"], "team is detected from the path")
check(ferrariEntry?.cars == [CarTarget(team: "Ferrari", season: "2025")], "…along with which season's car it is")
check(ferrariEntry?.summary == "Ferrari — 2025 car · 2 files", "summary says which car (got \(ferrariEntry?.summary ?? "nil"))")
check(ferrariEntry?.files.first { $0.member.hasSuffix("livery.erp") }?.relativePath
      == "2025_asset_groups/f1_2025_vehicle_package/teams/ferrari/livery.erp", "variant root is stripped from game paths")

let weird = scan.archives.first { $0.category == "Category A" }
check(weird?.entries.count == 1 && weird?.entries.first?.needsBaseFiles == true, "7z mod that touches fonts.erp needs base files")
check(base?.entries.first?.fileKeys.isDisjoint(with: ferrariEntry?.fileKeys ?? []) == true, "base files and Ferrari livery don't conflict")

print("Installing Base Files + Ferrari variant + 7z mod")
let chosen = [base!.entries[0], ferrariEntry!, weird!.entries[0]]
do {
    try installer.install(chosen, into: game) { _, _ in }
    check(true, "install succeeded")
} catch {
    check(false, "install succeeded: \(error.localizedDescription)")
}
let ferrariDir = assets.appendingPathComponent("f1_2025_vehicle_package/teams/ferrari")
check(read(assets.appendingPathComponent("vfx_package/common.erp")) == "base vfx", "base vfx common.erp installed")
check(read(ferrariDir.appendingPathComponent("Livery.erp")) == "mod ferrari", "Ferrari livery installed")
check((try? fm.contentsOfDirectory(atPath: ferrariDir.path))?.contains("Livery.erp") == true, "existing file keeps its on-disk casing")
check(read(ferrariDir.appendingPathComponent("new_decal.erp")) == "mod decal", "new file added")
check(read(assets.appendingPathComponent("ui_package/fonts.erp")) == "mod fonts", "7z file installed into a new folder")
check(read(assets.appendingPathComponent("vfx_package/particles/x[1].erp")) == "mod particle", "file names with [ ] extract fine")
check(read(game.appendingPathComponent("EAAntiCheat.splash.png")) == "orig splash", "anti-cheat splash untouched")
check(installer.hasActiveSession, "session is recorded")
check(installer.loadSession()?.complete == true && installer.loadSession()?.installed.count == 6, "session lists all 6 installed files")
check((try? installer.install([ferrariEntry!], into: game) { _, _ in }) == nil, "refuses to install over an active session")

print("Restoring")
var report = installer.restore(fallbackGameDir: nil) { _, _ in }
check(report.failures.isEmpty, "restore had no failures")
check(report.restored == 3 && report.removed == 3, "3 originals restored, 3 added files removed (got \(report.restored)/\(report.removed))")
check(read(assets.appendingPathComponent("vfx_package/common.erp")) == "orig vfx", "vfx common.erp is original again")
check(read(ferrariDir.appendingPathComponent("Livery.erp")) == "orig ferrari", "Ferrari livery is original again")
check((try? fm.contentsOfDirectory(atPath: ferrariDir.path)) == ["Livery.erp"], "added files are gone and casing is intact")
check(!exists(assets.appendingPathComponent("ui_package")), "folders created for added files are removed again")
check(exists(assets.appendingPathComponent("vfx_package/particles")) == false, "…including nested ones")
check(!installer.hasActiveSession, "session cleared")

print("Game update while mods are installed")
try! installer.install([ferrariEntry!], into: game) { _, _ in }
write("steam update, longer", ferrariDir.appendingPathComponent("Livery.erp"))
report = installer.restore(fallbackGameDir: nil) { _, _ in }
check(report.keptGameUpdates == 1, "keeps the file Steam updated instead of restoring a stale backup")
check(read(ferrariDir.appendingPathComponent("Livery.erp")) == "steam update, longer", "updated file left in place")
check(!exists(ferrariDir.appendingPathComponent("new_decal.erp")), "mod's added file still removed")
write("orig ferrari", ferrariDir.appendingPathComponent("Livery.erp"))

print("Recovering without session.json (e.g. after a crash)")
try! installer.install([ferrariEntry!], into: game) { _, _ in }
try! fm.removeItem(at: installer.sessionFile)
check(installer.hasActiveSession, "leftover backups still count as an active session")
report = installer.restore(fallbackGameDir: game) { _, _ in }
check(report.failures.isEmpty && read(ferrariDir.appendingPathComponent("Livery.erp")) == "orig ferrari", "restores using the fallback game folder")
check(!exists(ferrariDir.appendingPathComponent("new_decal.erp")) && !installer.hasActiveSession, "clean afterwards")

print("Importing")
let ownSrc = sources.appendingPathComponent("My Own Livery")
write("my haas", ownSrc.appendingPathComponent("2025_asset_groups/f1_2025_vehicle_package/teams/haas/livery.erp"))
write("x", sources.appendingPathComponent("photo.jpg"))
let imported = library.importItems([ownSrc, sources.appendingPathComponent("photo.jpg"), notModSrc])
check(imported.added == ["My Own Livery"], "a mod folder is zipped into the library (got \(imported.added))")
check(imported.failures.count == 2, "non-mod items are rejected (got \(imported.failures))")
let rescan = library.scan()
let own = rescan.archives.first { $0.name == "My Own Livery" }
check(own?.entries.first?.files.first?.relativePath == "2025_asset_groups/f1_2025_vehicle_package/teams/haas/livery.erp",
      "folder mod maps to the right game path")
let again = library.importItems([ownSrc])
check(again.added == ["My Own Livery 2"], "duplicate names get a number instead of overwriting")

print("Moving and renaming")
let newID = try! library.move(own!, toCategory: "My Liveries", newName: "Haas Custom")
check(newID == "My Liveries/Haas Custom.zip", "move + rename gives the new ID (got \(newID))")
check(exists(modsDir.appendingPathComponent("My Liveries/Haas Custom.zip")), "file moved")

print("CrossOver paths")
check(CrossOver.bottle(containing: game)?.name == "Steam", "bottle name comes from the game path")
check(GameLocator.unixPath(forWindowsPath: "C:\\\\SteamLibrary", in: bottle)?.path
      == bottle.appendingPathComponent("drive_c").resolvingSymlinksInPath().appendingPathComponent("SteamLibrary").path,
      "Windows library paths map into the bottle")
check(GameLocator.steamLibraries(in: bottle).count == 1, "finds the bottle's Steam install")
let steamExe = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
check(CrossOver.windowsPath(for: steamExe, bottleRoot: bottle) == "C:\\Program Files (x86)\\Steam\\steam.exe",
      "steam.exe gets a C:\\ path for CrossOver (got \(CrossOver.windowsPath(for: steamExe, bottleRoot: bottle) ?? "nil"))")
let fakeTarget = CrossOverTarget(wine: URL(fileURLWithPath: "/bin/echo"), appName: "Test", bottleName: "Steam",
                                 bottleRoot: bottle, steamExe: steamExe)
check(CrossOver.launchArguments(for: fakeTarget) == ["--bottle", "Steam", "--no-wait", "--cx-app",
      "C:\\Program Files (x86)\\Steam\\steam.exe", "-applaunch", "3059520"], "launch command uses the Windows path")
check(fakeTarget.steamLog.path.hasSuffix("Steam/logs/gameprocess_log.txt"), "Steam's game log is found next to steam.exe")

print("Steam's game log")
let realLogSample = """
[2026-09-28 20:35:14] AppID 3059520 adding PID 1640 as a tracked process ""C:\\Program Files (x86)\\Steam\\steamapps\\common\\F1 25\\EAAntiCheat.GameServiceLauncher.exe" -nomoviestartup -windowed"
[2026-09-28 20:35:15] AppID 3059520 adding PID 1680 as a tracked process "F1_25.exe"
[2026-09-28 20:35:21] AppID 3059520 no longer tracking PID 1680, exit code -1
"""
check(GameProcess.steamLogSaysRunning(realLogSample), "a crashed game process with the launcher still tracked counts as running")
check(!GameProcess.steamLogSaysRunning(realLogSample + "[2026-09-28 20:35:21] Remove 3059520 from running list\n"),
      "\"Remove … from running list\" means stopped")
let crlfLog = (realLogSample + "[2026-09-28 20:35:21] Remove 3059520 from running list\n").replacingOccurrences(of: "\n", with: "\r\n")
check(!GameProcess.steamLogSaysRunning(crlfLog), "Steam's Windows (CRLF) line endings are read correctly")
check(GameProcess.steamLogSaysRunning(realLogSample.replacingOccurrences(of: "\n", with: "\r\n")), "…and a running game still reads as running")
check(!GameProcess.steamLogSaysRunning("[x] AppID 1234 adding PID 5 as a tracked process \"other.exe\"\n"), "other games are ignored")
check(GameProcess.programName("\"C:\\Program Files (x86)\\Steam\\steamapps\\common\\F1 25\\F1_25.exe\"") == "f1_25.exe",
      "quoted Windows paths are understood")

if CommandLine.arguments.count > 2 {
    print("Real SERPs Base Files archive")
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let parsed = ModParser.parse(members: try! ArchiveTool.list(url), archiveID: "base.zip", url: url, name: "Base")
    check(parsed.isBaseFiles, "recognised as base files")
    check(parsed.entries.count == 1, "one entry")
    check(parsed.entries.first?.files.map(\.relativePath).sorted() == [
        "2025_asset_groups/f1_2025_vehicle_package/teams/common.erp",
        "2025_asset_groups/f1_2026_vehicle_package/teams/common.erp",
        "2025_asset_groups/vfx_package/common.erp",
    ], "installs the three common.erp files")
}

print("Cars named inside .erp files")
var erp = Data("ERPK\u{3}\u{0}".utf8)
erp.append(Data("\u{1}eaid://shader_package/vehicle_paint_v2/vehicle_metallic_paint.nefx2\u{0}".utf8))
erp.append(Data("\u{2}eaid://f1_2025_vehicle_package/shared/shadows/materials/f1_vehicle_shadow.material\u{0}".utf8))
erp.append(Data("\u{3}eaid://f1_2025_vehicle_package/teams/haas/textures/haas_paint_d.tif.image\u{0}".utf8))
erp.append(Data("\u{4}eaid://f1_2025_vehicle_package/teams/haas/materials/haas_carbon1.material\u{0}".utf8))
check(ModParser.cars(inERP: erp) == [CarTarget(team: "Haas", season: "2025")], "a shader-package livery is recognised as the 2025 Haas")
check(ModParser.season(fromPackage: "f1_2026_vehicle_package") == "2026" && ModParser.season(fromPackage: "f2_2025_vehicle_package") == "F2 2025"
      && ModParser.season(fromPackage: "f1_2025_story_vehicle_package") == "2025 story", "package names map to seasons")

print("Game detection")
let fakeGame = Process()
fakeGame.executableURL = URL(fileURLWithPath: "/bin/bash")
fakeGame.arguments = ["-c", "exec -a 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\F1 25\\F1_25.exe' sleep 5"]
try! fakeGame.run()
Thread.sleep(forTimeInterval: 0.5)
check(GameProcess.isRunning(), "a process whose program is F1_25.exe counts as the game")
fakeGame.terminate()
fakeGame.waitUntilExit()
let fakeLauncher = Process()
fakeLauncher.executableURL = URL(fileURLWithPath: "/bin/bash")
fakeLauncher.arguments = ["-c", "exec -a 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\F1 25\\EAAntiCheat.GameServiceLauncher.exe' sleep 5"]
try! fakeLauncher.run()
Thread.sleep(forTimeInterval: 0.5)
check(GameProcess.status(steamLog: nil).launcherProcess, "the anti-cheat launcher (which waits on the game) counts as the game session")
fakeLauncher.terminate()
fakeLauncher.waitUntilExit()
let mention = Process()
mention.executableURL = URL(fileURLWithPath: "/bin/sh")
mention.arguments = ["-c", "sleep 5; true", "F1_25.exe"] // "; true" stops sh from exec'ing sleep and dropping the args
try! mention.run()
Thread.sleep(forTimeInterval: 0.3)
let commandLines = (try? runProcess("/bin/ps", ["-axww", "-o", "command="]).output) ?? ""
check(commandLines.contains("sleep 5; true F1_25.exe"), "test process mentioning F1_25.exe is really running")
check(!GameProcess.isRunning(), "a command that only mentions F1_25.exe doesn't count")
mention.terminate()
mention.waitUntilExit()

print("zstd + .erp round trip")
let sample = Data((0..<300_000).map { UInt8(($0 * 7 + $0 / 1000) & 0xFF) })
check((try? Zstd.decompress(Zstd.rawFrame(sample))) == sample, "raw-block zstd frames decode back (300 KB, several blocks)")
check((try? Zstd.decompress(Zstd.rawFrame(Data()))) == Data(), "…and so does an empty one")

var dxt = [UInt8](repeating: 0, count: 64 * 64 * 4)
for y in 0..<64 { for x in 0..<64 { let i = (y * 64 + x) * 4; dxt[i] = UInt8(x * 4); dxt[i + 1] = UInt8(y * 4); dxt[i + 2] = UInt8((x + y) * 2); dxt[i + 3] = UInt8(255 - x) } }
for format in [TextureFormat.bc1, .bc3, .bc4, .bc5] {
    let encoded = BlockCodec.encode(dxt, width: 64, height: 64, format: format)
    let decoded = BlockCodec.decode(encoded, format: format, width: 64, height: 64) ?? []
    let channels = format == .bc4 ? [0] : format == .bc5 ? [0, 1] : [0, 1, 2]
    var error = 0.0
    for p in 0..<(64 * 64) { for c in channels { let d = Double(Int(dxt[p * 4 + c]) - Int(decoded[p * 4 + c])); error += d * d } }
    let psnr = 10 * log10(255 * 255 / (error / Double(64 * 64 * channels.count)))
    check(encoded.count == format.levelSize(width: 64, height: 64) && psnr > 32, "\(format) encodes a gradient cleanly (PSNR \(String(format: "%.1f", psnr)) dB)")
}

if let gamePath = ProcessInfo.processInfo.environment["F1ML_TEST_GAME"], let modPath = ProcessInfo.processInfo.environment["F1ML_TEST_TEXMOD"] {
    print("Texture mod, using copies of the real game's Haas files")
    let realGame = URL(fileURLWithPath: gamePath)
    let fakeGame = root.appendingPathComponent("TexGame/F1 25", isDirectory: true)
    let haas25 = "2025_asset_groups/f1_2025_vehicle_package/teams/haas/wep/haas.erp"
    let haas26 = "2025_asset_groups/f1_2026_vehicle_package/teams/haas/wep/haas.erp"
    for relative in [haas25, haas26, "F1_25.exe"] {
        let target = fakeGame.appendingPathComponent(relative)
        try! fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! fm.copyItem(at: realGame.appendingPathComponent(relative), to: target) // APFS clone, the real file is untouched
    }
    let index = GameIndex.load(gameDir: fakeGame, cacheFile: nil)
    check(index.places(forTexture: "haas_paint_d.tif").count == 2, "index finds haas_paint_d.tif in the 2025 and 2026 Haas files")

    let texMods = root.appendingPathComponent("TexMods", isDirectory: true)
    try! fm.createDirectory(at: texMods, withIntermediateDirectories: true)
    try! fm.copyItem(at: URL(fileURLWithPath: modPath), to: texMods.appendingPathComponent(URL(fileURLWithPath: modPath).lastPathComponent))
    let texLibrary = ModLibrary(root: texMods, tempRoot: root.appendingPathComponent("Temp3"))
    let texScan = texLibrary.scan(game: index)
    let texEntry = texScan.archives.first?.entries.first
    check(texEntry?.textures.count == 4 && texEntry?.textureTargets.count == 4, "the .dds mod has 4 textures, each matched to the game (problems: \(texScan.problems))")
    check(texEntry?.textureSeasons == ["2026", "2025"], "both Haas cars are offered (got \(texEntry?.textureSeasons ?? []))")
    print("    auto-picked: \(texEntry?.textureSeason ?? "nil") — \(texEntry?.summary ?? "")")
    if let texEntry {
        let work = root.appendingPathComponent("similarity", isDirectory: true)
        try! fm.createDirectory(at: work, withIntermediateDirectories: true)
        try! ArchiveTool.extract(URL(fileURLWithPath: modPath), members: texEntry.textures.map(\.member), to: work)
        for texture in texEntry.textures.sorted(by: { $0.key < $1.key }) {
            let dds = try! DDSImage(data: Data(contentsOf: work.appendingPathComponent(texture.member)))
            let scores = [("2025", haas25), ("2026", haas26)].map { season, erp -> String in
                let archive = try! ERPArchive(url: fakeGame.appendingPathComponent(erp))
                let surface = "eaid://f1_\(season)_vehicle_package/teams/haas/textures/\(texture.key).image"
                return "\(season): " + (TextureInjector.difference(dds, from: archive, surface: surface).map { String(format: "%.1f", $0) } ?? "n/a")
            }
            print("    \(texture.key) average difference — \(scores.joined(separator: ", "))")
        }
    }
    let forced = texLibrary.scan(game: index, seasons: [texEntry?.id ?? "": "2025"]).archives.first?.entries.first
    check(forced?.textureTargets.allSatisfy { $0.erp == haas25 } == true, "choosing the 2025 car sends every texture to the 2025 Haas file")

    if let texEntry {
        let chosenERP = texEntry.textureTargets[0].erp
        let before = try! Data(contentsOf: fakeGame.appendingPathComponent(chosenERP))
        let original = try! ERPArchive(data: before)
        let texInstaller = Installer(stateDir: root.appendingPathComponent("TexBackups"), tempDir: root.appendingPathComponent("Temp4"))
        let started = Date()
        do {
            try texInstaller.install([texEntry], into: fakeGame) { _, _ in }
            check(true, "textures packed and installed (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        } catch {
            check(false, "textures packed and installed: \(error.localizedDescription)")
        }
        if let export = ProcessInfo.processInfo.environment["F1ML_EXPORT"] {
            try? fm.removeItem(atPath: export)
            try? fm.copyItem(at: fakeGame.appendingPathComponent(chosenERP), to: URL(fileURLWithPath: export))
        }
        let modded = try! ERPArchive(url: fakeGame.appendingPathComponent(chosenERP))
        check(modded.resources.count == original.resources.count, "same number of resources as the original (\(modded.resources.count))")
        let replacedNames = Set(texEntry.textureTargets.flatMap { [$0.surface, String($0.surface.dropLast(6))] })
        var untouchedSame = true
        for (a, b) in zip(original.resources, modded.resources) where !replacedNames.contains(a.name) {
            if a.name != b.name || a.fragments.count != b.fragments.count || zip(a.fragments, b.fragments).contains(where: { original.packed($0) != modded.packed($1) }) {
                untouchedSame = false; break
            }
        }
        check(untouchedSame, "every other resource is byte-for-byte unchanged")
        let expected: [String: (Int, Int, UInt32)] = ["haas_paint_d.tif": (256, 256, 54), "haas_decal_da.tif": (4096, 4096, 57),
                                                       "haas_driver_31.tif": (1024, 512, 57), "haas_driver_87.tif": (1024, 512, 57)]
        for target in texEntry.textureTargets {
            let key = GameIndex.textureKey(ofSurface: target.surface)
            guard let surface = modded.resource(named: target.surface), surface.fragments.count == 2,
                  let header = try? GameTexture.Header(raw: modded.unpacked(surface.fragments[0])),
                  let view = modded.resource(named: String(target.surface.dropLast(6))),
                  let viewData = try? modded.unpacked(view.fragments[0]) else { check(false, "\(key) is complete"); continue }
            let want = expected[key]!
            let chainOK = surface.fragments[1].size == TextureFormat.fromGame(header.format)!.0.chainSize(width: header.width, height: header.height, mips: header.mips)
            check(header.width == want.0 && header.height == want.1 && header.format == want.2 && chainOK
                  && viewData.u32(at: 4) == header.format && Int(viewData.u32(at: 12)) == header.mips,
                  "\(key): \(header.width)×\(header.height), format \(header.format), \(header.mips) mips, view matches")
        }
        // How close is the packed decal to the mod's picture?
        if let decal = texEntry.textureTargets.first(where: { $0.surface.hasSuffix("haas_decal_da.tif.image") }),
           let surface = modded.resource(named: decal.surface), let chain = try? modded.unpacked(surface.fragments[1]) {
            let work = root.appendingPathComponent("ddscheck", isDirectory: true)
            try! fm.createDirectory(at: work, withIntermediateDirectories: true)
            try! ArchiveTool.extract(URL(fileURLWithPath: modPath), members: [decal.member], to: work)
            let dds = try! DDSImage(data: Data(contentsOf: work.appendingPathComponent(decal.member)))
            let level = dds.level(2) // 1024×1024
            let size = TextureFormat.bc3.levelSize(width: 1024, height: 1024)
            let offset = TextureFormat.bc3.chainSize(width: 4096, height: 4096, mips: 2)
            let ours = BlockCodec.decode(chain[(chain.startIndex + offset)..<(chain.startIndex + offset + size)], format: .bc3, width: 1024, height: 1024) ?? []
            let theirs = [UInt8](level.data)
            var error = 0.0
            for p in 0..<(1024 * 1024) { for c in 0..<4 { let d = Double(Int(ours[p * 4 + c]) - Int(theirs[p * 4 + c])); error += d * d } }
            let psnr = 10 * log10(255 * 255 / (error / Double(1024 * 1024 * 4)))
            check(psnr > 30, "packed decal matches the mod's picture (PSNR \(String(format: "%.1f", psnr)) dB at 1024×1024)")
        }
        let report = texInstaller.restore(fallbackGameDir: nil) { _, _ in }
        check(report.failures.isEmpty && (try? Data(contentsOf: fakeGame.appendingPathComponent(chosenERP))) == before,
              "restore puts the original .erp back byte for byte")
    }
}

if CommandLine.arguments.count > 3 {
    print("Your mods folder (read-only)")
    let yours = ModLibrary(root: URL(fileURLWithPath: CommandLine.arguments[3]), tempRoot: root.appendingPathComponent("Temp2"))
    for archive in yours.scan().archives {
        for entry in archive.entries { print("  \(entry.displayName): \(entry.summary)") }
    }
}

print("This Mac (read-only)")
let detected = GameLocator.autodetect()
print("  game folder: \(detected?.path ?? "not found")")
if let detected, let target = CrossOver.target(for: detected) {
    print("  CrossOver: \(target.appName), bottle \(target.bottleName)")
    print("  launch command: wine \(CrossOver.launchArguments(for: target).joined(separator: " "))")
    print("  F1 25 status: \(GameProcess.status(steamLog: target.steamLog).description)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
