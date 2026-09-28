import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct F1ModLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LauncherStore.shared

    init() {
        #if DEBUG
        DebugHarness.start()
        #endif
    }

    var body: some Scene {
        Window("F1 25 Mod Launcher", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 580, minHeight: 520)
        }
        .defaultSize(width: 680, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Mods…") { store.presentImportPanel() }
                    .keyboardShortcut("o")
                Button("Open Mods Folder") { store.openModsFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Mod List") { store.rescan() }
                    .keyboardShortcut("r")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.showSettings = true }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Button("Show Activity Log") { store.openActivityLog() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LauncherStore.shared.shouldTerminate()
    }
}

// MARK: - Store

struct Banner: Identifiable, Equatable {
    enum Style { case info, success, warning }
    let id = UUID()
    let text: String
    let style: Style

    var icon: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch style {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        }
    }
}

struct AlertAction: Identifiable {
    let id = UUID()
    let title: String
    var role: ButtonRole?
    let run: () -> Void
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var actions: [AlertAction] = []
}

struct ArchiveRowModel: Identifiable {
    let archive: ModArchive
    let entries: [ModEntry]
    var id: String { archive.id }
}

struct ModSection: Identifiable {
    let id: String
    let title: String
    let rows: [ArchiveRowModel]
}

@MainActor
final class LauncherStore: ObservableObject {
    static let shared = LauncherStore()

    enum Phase: Equatable {
        case idle, installing, waitingForGame, gameRunning, restoring
        /// The game has closed; the originals go back at this time unless it starts again first.
        case gameClosed(Date)
    }

    /// F1 25 in CrossOver sometimes closes and relaunches itself, and after a crash you'll want to
    /// press Play again — so wait a little before putting the original files back.
    static let restoreDelay: TimeInterval = 45
    enum LaunchMode { case launch, installOnly }
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case favorites = "Favorites"
        var id: String { rawValue }
    }

    @Published private(set) var gameDir: URL?
    @Published private(set) var crossOver: CrossOverTarget?
    @Published private(set) var archives: [ModArchive] = []
    @Published private(set) var categories: [String] = []
    @Published private(set) var libraryProblems: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var selection: Set<String> = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var collapsed: Set<String> = []
    @Published var search = ""
    @Published var filter: Filter = .all
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var gameRunning = false
    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var sessionPending = false
    @Published var banner: Banner?
    @Published var alert: AlertItem?
    @Published var showSettings = false
    @Published var renameTarget: ModArchive?
    @Published var renameText = ""
    @Published var categoryTarget: ModArchive?
    @Published var categoryText = ""

    let library = ModLibrary(root: AppPaths.mods, tempRoot: AppPaths.temp, carCacheFile: AppPaths.carCache,
                             seasonCacheFile: AppPaths.seasonCache)
    /// What's in the game folder, for matching loose files and textures. Loaded in the background.
    private var gameIndex: GameIndex?
    @Published private(set) var isIndexingGame = false
    let installer = Installer(stateDir: AppPaths.backups, tempDir: AppPaths.temp)
    private var settings = LauncherSettings.load()
    private var monitorTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var lastGameStatus: GameStatus?

    private init() {
        ActivityLog.isEnabled = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        ActivityLog.write("──────── F1 25 Mod Launcher \(version) started ────────")
        try? FileManager.default.createDirectory(at: AppPaths.mods, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: AppPaths.temp)
        favorites = Set(settings.favorites)
        selection = Set(settings.selection)
        collapsed = Set(settings.collapsed)
        if let path = settings.gamePath, GameLocator.isGameFolder(URL(fileURLWithPath: path)) {
            gameDir = URL(fileURLWithPath: path)
        } else if let detected = GameLocator.autodetect() {
            gameDir = detected
            settings.gamePath = detected.path
            settings.save()
        }
        ActivityLog.write("Game folder: \(gameDir?.path ?? "not found")")
        refreshCrossOver()
        // With a game folder, the mods are read once the game index is ready (loose files and textures
        // need it); without one, straight away.
        if gameDir != nil { loadGameIndex() } else { rescan() }
        resumeSessionIfNeeded()
        startMonitoring()
    }

    // MARK: Derived state

    var allEntries: [ModEntry] { archives.flatMap(\.entries) }
    var baseEntry: ModEntry? { archives.first(where: \.isBaseFiles)?.entries.first }
    var selectedEntries: [ModEntry] {
        allEntries.filter { selection.contains($0.id) }.sorted { $0.isBaseFiles && !$1.isBaseFiles }
    }
    var canChangeSelection: Bool { phase == .idle && !sessionPending }

    var sections: [ModSection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func visibleEntries(of archive: ModArchive) -> [ModEntry] {
            if archive.isBaseFiles { return archive.entries } // always pinned, like SERPs Launcher
            var entries = archive.entries
            if filter == .favorites { entries = entries.filter { favorites.contains($0.id) } }
            if !query.isEmpty, !archive.name.lowercased().contains(query) {
                entries = entries.filter {
                    $0.title.lowercased().contains(query) || $0.teams.joined(separator: " ").lowercased().contains(query)
                }
            }
            return entries
        }
        func rows(_ archives: [ModArchive]) -> [ArchiveRowModel] {
            archives.compactMap { archive in
                let entries = visibleEntries(of: archive)
                return entries.isEmpty ? nil : ArchiveRowModel(archive: archive, entries: entries)
            }
        }

        var result: [ModSection] = []
        let base = rows(archives.filter(\.isBaseFiles))
        if !base.isEmpty { result.append(ModSection(id: "#base", title: "Base Files", rows: base)) }
        let others = archives.filter { !$0.isBaseFiles }
        let top = rows(others.filter { $0.category == nil })
        if !top.isEmpty { result.append(ModSection(id: "#top", title: "Mods", rows: top)) }
        for category in categories {
            let categoryRows = rows(others.filter { $0.category == category })
            if !categoryRows.isEmpty { result.append(ModSection(id: category, title: category, rows: categoryRows)) }
        }
        return result
    }

    var hasVisibleMods: Bool { sections.contains { $0.id != "#base" } }

    /// Which cars to check in the game for the installed mods, e.g. "Haas (2025 car)".
    var lookFor: String? {
        let cars = allEntries.filter { installedIDs.contains($0.id) && !$0.isBaseFiles }.flatMap(\.cars)
            .reduce(into: [CarTarget]()) { if !$0.contains($1) { $0.append($1) } }
        return cars.isEmpty ? nil : ListFormatter.localizedString(byJoining: cars.map(\.description))
    }

    var subtitle: String {
        if let crossOver { return "CrossOver bottle “\(crossOver.bottleName)”" }
        return gameDir == nil ? "Game folder not set" : "CrossOver not found"
    }

    // MARK: Game folder & CrossOver

    func setGameDir(_ url: URL) {
        gameDir = url
        settings.gamePath = url.path
        settings.save()
        refreshCrossOver()
        loadGameIndex()
    }

    /// Indexes the game folder (cached until the game updates), then re-reads the mods with it.
    func loadGameIndex() {
        guard let gameDir else { gameIndex = nil; return }
        isIndexingGame = true
        Task {
            let index = await Task.detached(priority: .userInitiated) {
                GameIndex.load(gameDir: gameDir, cacheFile: AppPaths.gameIndex)
            }.value
            guard self.gameDir == gameDir else { return }
            gameIndex = index
            isIndexingGame = false
            rescan()
        }
    }

    func refreshCrossOver() {
        guard let gameDir else { crossOver = nil; return }
        Task {
            crossOver = await Task.detached { CrossOver.target(for: gameDir) }.value
            if let crossOver {
                ActivityLog.write("CrossOver: \(crossOver.appName) (\(crossOver.wine.path)), bottle “\(crossOver.bottleName)”, Steam \(crossOver.steamExe.path)")
            } else {
                ActivityLog.write("CrossOver: not found for this game folder — the game has to be started by hand")
            }
        }
    }

    func autodetectGame() {
        if let detected = GameLocator.autodetect() {
            setGameDir(detected)
            showBanner("Found F1 25 in CrossOver.", style: .success)
        } else {
            alert = AlertItem(title: "Couldn't find F1 25",
                              message: "No CrossOver bottle has F1 25 installed through Steam. Choose the game folder yourself — it's the “F1 25” folder that contains F1_25.exe.")
        }
    }

    func chooseGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose the “F1 25” folder inside your CrossOver bottle (the one with F1_25.exe in it)."
        panel.directoryURL = gameDir ?? GameLocator.bottlesDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if GameLocator.isGameFolder(url) {
            setGameDir(url)
        } else {
            alert = AlertItem(title: "That's not the F1 25 folder",
                              message: "\(url.lastPathComponent) doesn't contain F1_25.exe. Look for …/drive_c/Program Files (x86)/Steam/steamapps/common/F1 25.")
        }
    }

    // MARK: Library

    func rescan() {
        isScanning = true
        let library = self.library
        let game = gameIndex
        let seasons = settings.textureSeasons
        Task {
            let result = await Task.detached { library.scan(game: game, seasons: seasons) }.value
            archives = result.archives
            categories = result.categories
            libraryProblems = result.problems
            isScanning = false
            let complete = game != nil || gameDir == nil
            ActivityLog.write("Mods found: " + (archives.isEmpty ? "none" : archives.map { archive in
                "\(archive.id) [\(archive.entries.map { "\($0.title): \($0.files.count) file(s)\($0.cars.isEmpty ? "" : ", changes \($0.cars.map(\.description).joined(separator: ", "))")" }.joined(separator: "; "))]"
            }.joined(separator: ", ")) + (libraryProblems.isEmpty ? "" : " — problems: \(libraryProblems)"))
            let known = Set(allEntries.map(\.id))
            // Texture mods only show up once the game is indexed; don't forget they were ticked.
            if complete && !selection.isSubset(of: known) {
                selection.formIntersection(known)
                saveSettings()
            }
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Mods"
        panel.message = "Choose mod archives (.zip, .rar, .7z) or a folder with your own livery files."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder] + ["rar", "7z"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { importItems(panel.urls) }
    }

    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let library = self.library
        let game = gameIndex
        showBanner(urls.count == 1 ? "Adding \(urls[0].lastPathComponent)…" : "Adding \(urls.count) items…")
        Task {
            let result = await Task.detached { library.importItems(urls, game: game) }.value
            rescan()
            if !result.failures.isEmpty {
                alert = AlertItem(title: result.added.isEmpty ? "Nothing was added" : "Some items weren't added",
                                  message: result.failures.joined(separator: "\n\n"))
            } else if !result.added.isEmpty {
                showBanner("Added \(result.added.joined(separator: ", ")).", style: .success)
            }
        }
    }

    func openModsFolder() {
        try? FileManager.default.createDirectory(at: AppPaths.mods, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppPaths.mods)
    }

    func reveal(_ archive: ModArchive) {
        NSWorkspace.shared.activateFileViewerSelecting([archive.url])
    }

    func beginRename(_ archive: ModArchive) {
        renameText = archive.name
        renameTarget = archive
    }

    func commitRename() {
        guard let archive = renameTarget else { return }
        renameTarget = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, name != archive.name else { return }
        relocate(archive, category: archive.category, newName: name)
    }

    func beginNewCategory(_ archive: ModArchive) {
        categoryText = ""
        categoryTarget = archive
    }

    func commitNewCategory() {
        guard let archive = categoryTarget else { return }
        categoryTarget = nil
        let name = categoryText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { return }
        relocate(archive, category: name, newName: nil)
    }

    func move(_ archive: ModArchive, to category: String?) {
        relocate(archive, category: category, newName: nil)
    }

    private func relocate(_ archive: ModArchive, category: String?, newName: String?) {
        do {
            let newID = try library.move(archive, toCategory: category, newName: newName)
            migrateIDs(from: archive.id, to: newID)
            rescan()
        } catch {
            alert = AlertItem(title: "Couldn't move \(archive.name)", message: error.localizedDescription)
        }
    }

    func trash(_ archive: ModArchive) {
        do {
            try FileManager.default.trashItem(at: archive.url, resultingItemURL: nil)
            selection = selection.filter { !belongs($0, to: archive.id) }
            saveSettings()
            rescan()
            showBanner("Moved \(archive.name) to the Trash.")
        } catch {
            alert = AlertItem(title: "Couldn't move \(archive.name) to the Trash", message: error.localizedDescription)
        }
    }

    private func belongs(_ entryID: String, to archiveID: String) -> Bool {
        entryID == archiveID || entryID.hasPrefix(archiveID + "::")
    }

    private func migrateIDs(from old: String, to new: String) {
        func map(_ id: String) -> String { belongs(id, to: old) ? new + id.dropFirst(old.count) : id }
        selection = Set(selection.map(map))
        favorites = Set(favorites.map(map))
        collapsed = Set(collapsed.map(map))
        settings.textureSeasons = Dictionary(settings.textureSeasons.map { (map($0.key), $0.value) }) { $1 }
        saveSettings()
    }

    // MARK: Selection

    func selectionBinding(for entry: ModEntry) -> Binding<Bool> {
        Binding(get: { self.selection.contains(entry.id) }, set: { _ in self.toggle(entry) })
    }

    func toggle(_ entry: ModEntry) {
        guard canChangeSelection else { return }
        if selection.contains(entry.id) {
            selection.remove(entry.id)
            if entry.isBaseFiles {
                let dependants = selectedEntries.filter(\.needsBaseFiles)
                dependants.forEach { selection.remove($0.id) }
                if !dependants.isEmpty {
                    showBanner("Also turned off \(names(dependants)) — they need the Base Files.", style: .warning)
                }
            }
        } else {
            if entry.needsBaseFiles, baseEntry == nil {
                alert = AlertItem(
                    title: "This mod needs the SERPs Base Files",
                    message: "Download “SERPs Base Files for F1 25” and drop the zip onto this window, then turn this mod on again.",
                    actions: [
                        AlertAction(title: "Open Download Page") { NSWorkspace.shared.open(ModRules.baseFilesDownloadURL) },
                        AlertAction(title: "Cancel", role: .cancel) {},
                    ])
                return
            }
            let turnedOff = select(entry)
            var notes: [String] = []
            if entry.needsBaseFiles, let base = baseEntry, !selection.contains(base.id) {
                _ = select(base, keeping: entry)
                notes.append("Turned on the Base Files, which this mod needs.")
            }
            if !turnedOff.isEmpty {
                notes.append("Turned off \(names(turnedOff)) — it changes the same game files.")
            }
            if !notes.isEmpty { showBanner(notes.joined(separator: " "), style: turnedOff.isEmpty ? .info : .warning) }
        }
        saveSettings()
    }

    /// Selects `entry` and turns off anything that writes the same game files. Returns what was turned off.
    private func select(_ entry: ModEntry, keeping protected: ModEntry? = nil) -> [ModEntry] {
        let conflicts = selectedEntries.filter {
            $0.id != entry.id && $0.id != protected?.id && !$0.fileKeys.isDisjoint(with: entry.fileKeys)
        }
        conflicts.forEach { selection.remove($0.id) }
        selection.insert(entry.id)
        return conflicts
    }

    func clearSelection() {
        guard canChangeSelection else { return }
        selection.removeAll()
        saveSettings()
    }

    /// Which car a texture mod goes on ("2025", "2026", "all").
    func setTextureSeason(_ entry: ModEntry, to season: String) {
        guard canChangeSelection else { return }
        settings.textureSeasons[entry.id] = season
        saveSettings()
        ActivityLog.write("\(entry.displayName): textures now go on the \(season == "all" ? "cars of every season" : "\(season) car")")
        rescan()
    }

    func textureSeasonLabel(_ season: String?) -> String {
        guard let season else { return "Car" }
        return season == "all" ? "All cars" : season == "other" ? "Other" : "\(season) car"
    }

    func toggleFavorite(_ entry: ModEntry) {
        if favorites.contains(entry.id) { favorites.remove(entry.id) } else { favorites.insert(entry.id) }
        saveSettings()
    }

    func expansionBinding(for archive: ModArchive) -> Binding<Bool> {
        Binding(get: { !self.collapsed.contains(archive.id) }, set: { expanded in
            if expanded { self.collapsed.remove(archive.id) } else { self.collapsed.insert(archive.id) }
            self.saveSettings()
        })
    }

    private func names(_ entries: [ModEntry]) -> String {
        ListFormatter.localizedString(byJoining: entries.map(\.displayName))
    }

    private func saveSettings() {
        settings.selection = Array(selection).sorted()
        settings.favorites = Array(favorites).sorted()
        settings.collapsed = Array(collapsed).sorted()
        settings.save()
    }

    // MARK: Launching

    func launch(_ mode: LaunchMode) {
        guard phase == .idle, !sessionPending, let gameDir else { return }
        guard !gameRunning else {
            alert = AlertItem(title: "F1 25 is already running",
                              message: "Quit the game first, then launch it from here so your mods can be installed.")
            return
        }
        let entries = selectedEntries
        guard !entries.isEmpty else {
            if mode == .launch { Task { await startGame(withMods: false) } }
            return
        }

        phase = .installing
        progress = 0
        status = "Getting ready…"
        ActivityLog.write("Launch pressed (\(mode == .launch ? "install + start game" : "install only")) with: \(entries.map(\.displayName).joined(separator: ", "))")
        let installer = self.installer
        Task {
            do {
                try await Task.detached {
                    try installer.install(entries, into: gameDir) { value, text in
                        LauncherStore.report(progress: value, status: text)
                    }
                }.value
                installedIDs = Set(entries.map(\.id))
                sessionPending = true
                phase = .waitingForGame
                if mode == .launch {
                    await startGame(withMods: true)
                } else {
                    status = "Start F1 25 from Steam in CrossOver whenever you're ready."
                }
            } catch {
                status = "Something went wrong — putting the original files back…"
                let failure = error.localizedDescription
                ActivityLog.write("Install FAILED: \(failure)")
                await performRestore(announce: false, reason: "install failed")
                alert = AlertItem(title: "Couldn't install your mods",
                                  message: failure + "\n\nYour game files have been put back to how they were.")
            }
        }
    }

    private func startGame(withMods: Bool) async {
        guard let target = crossOver else {
            status = "Start F1 25 from Steam in CrossOver — the launcher couldn't find CrossOver to do it for you."
            if !withMods { alert = AlertItem(title: "CrossOver not found", message: "Start F1 25 from Steam in CrossOver.") }
            return
        }
        status = "Asking Steam in CrossOver to start F1 25…"
        do {
            try await Task.detached { try CrossOver.launchGame(target, log: AppPaths.launchLog) }.value
            status = "Starting F1 25… this can take a minute in CrossOver. If it doesn't open, press Play in Steam."
            if !withMods { showBanner("Starting F1 25 without mods…") }
        } catch {
            status = "Your mods are installed — press Play on F1 25 in Steam (in CrossOver)."
            alert = AlertItem(
                title: "Couldn't start F1 25 automatically",
                message: error.localizedDescription + (withMods
                    ? "\n\nYour mods ARE installed. Press Play on F1 25 in Steam inside CrossOver — the launcher will notice the game and keep the mods in place."
                    : "\n\nStart F1 25 from Steam in CrossOver."))
        }
    }

    /// Start (or restart) the game while mods are installed.
    func startGameAgain() {
        switch phase {
        case .waitingForGame, .gameClosed:
            phase = .waitingForGame
            Task { await startGame(withMods: true) }
        default:
            break
        }
    }

    /// The game closed but the player wants to go again — leave the mods where they are.
    func keepModsInstalled() {
        guard case .gameClosed = phase else { return }
        ActivityLog.write("Keep Mods Installed pressed")
        phase = .waitingForGame
        status = "Mods are still installed. Start F1 25 from here or press Play in Steam."
    }

    func openActivityLog() {
        ActivityLog.flush()
        if !FileManager.default.fileExists(atPath: ActivityLog.url.path) {
            try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: ActivityLog.url.path, contents: nil)
        }
        NSWorkspace.shared.open(ActivityLog.url)
    }

    nonisolated static func report(progress value: Double, status text: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LauncherStore.shared.progress = value
                LauncherStore.shared.status = text
            }
        }
    }

    // MARK: Watching the game & restoring

    /// Steam's gameprocess_log.txt inside the bottle.
    private var steamLog: URL? {
        crossOver?.steamLog ?? gameDir.map {
            $0.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("logs/gameprocess_log.txt")
        }
    }

    private func startMonitoring() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let log = self?.steamLog
                let status = await Task.detached(priority: .utility) { GameProcess.status(steamLog: log) }.value
                self?.gameStateChanged(status)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func gameStateChanged(_ gameStatus: GameStatus) {
        let running = gameStatus.isRunning
        if gameStatus != lastGameStatus {
            ActivityLog.write("Game status: \(gameStatus.description)")
            lastGameStatus = gameStatus
        }
        if gameRunning != running { gameRunning = running }
        switch phase {
        case .waitingForGame where running:
            phase = .gameRunning
            status = ""
            ActivityLog.write("F1 25 started — mods are in place" + (lookFor.map { ". Look for: \($0)" } ?? ""))
        case .gameRunning where !running:
            phase = .gameClosed(Date().addingTimeInterval(Self.restoreDelay))
            ActivityLog.write("F1 25 closed — original files go back in \(Int(Self.restoreDelay)) s unless it starts again")
        case .gameClosed where running:
            phase = .gameRunning
            ActivityLog.write("F1 25 started again — mods stay in place")
        case .gameClosed(let deadline) where Date() >= deadline:
            phase = .restoring
            Task { await performRestore(announce: true, reason: "game closed \(Int(Self.restoreDelay)) s ago") }
        default:
            break
        }
    }

    private func resumeSessionIfNeeded() {
        guard installer.hasActiveSession else { return }
        sessionPending = true
        installedIDs = Set(installer.loadSession()?.modIDs ?? [])
        phase = .restoring
        status = "Checking for mods left from last time…"
        let log = steamLog
        Task {
            let gameStatus = await Task.detached { GameProcess.status(steamLog: log) }.value
            let running = gameStatus.isRunning
            gameRunning = running
            ActivityLog.write("Mods from last time are still installed; game status: \(gameStatus.description)")
            if running {
                phase = .gameRunning // the game is still going; restore once it closes
            } else {
                await performRestore(announce: false, reason: "left over from last time")
                if !sessionPending {
                    showBanner("Put back the original game files left modded from last time.", style: .success)
                }
            }
        }
    }

    func restoreNow() {
        var allowed = false
        switch phase {
        case .idle, .waitingForGame, .gameClosed: allowed = true
        default: break
        }
        guard !gameRunning, allowed else {
            if gameRunning {
                alert = AlertItem(title: "F1 25 is still running",
                                  message: "Quit the game first. The original files go back automatically after it closes.")
            }
            return
        }
        Task { await performRestore(announce: true, reason: "Restore pressed") }
    }

    private func performRestore(announce: Bool, reason: String) async {
        ActivityLog.write("Restoring original files (\(reason))")
        phase = .restoring
        progress = 0
        status = "Putting the original game files back…"
        let installer = self.installer
        let fallback = gameDir
        let report = await Task.detached {
            installer.restore(fallbackGameDir: fallback) { value, text in
                LauncherStore.report(progress: value, status: text)
            }
        }.value
        sessionPending = installer.hasActiveSession
        installedIDs = sessionPending ? installedIDs : []
        phase = .idle
        status = ""
        if !report.failures.isEmpty {
            alert = AlertItem(
                title: "Some files couldn't be put back",
                message: "\(report.failures.count) file(s) are still modded. Try “Restore Original Files” again. If that keeps failing, use Steam ▸ F1 25 ▸ Properties ▸ Installed Files ▸ Verify integrity.")
        } else if announce {
            var text = "Original game files restored — F1 25 is clean again."
            if report.keptGameUpdates > 0 { text += " Kept \(report.keptGameUpdates) file(s) Steam updated in the meantime." }
            showBanner(text, style: .success)
        }
    }

    func shouldTerminate() -> NSApplication.TerminateReply {
        defer { ActivityLog.flush() }
        if phase == .installing || phase == .restoring {
            let alert = NSAlert()
            alert.messageText = "Please wait a moment"
            alert.informativeText = "The launcher is still copying game files. Quit once it has finished."
            alert.runModal()
            return .terminateCancel
        }
        guard sessionPending || installer.hasActiveSession else { return .terminateNow }
        if gameRunning {
            let alert = NSAlert()
            alert.messageText = "F1 25 is still running with your mods"
            alert.informativeText = "If you quit now, the original game files will be put back the next time you open F1 25 Mod Launcher. Don't play online until then."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            let quit = alert.runModal() == .alertFirstButtonReturn
            if quit { ActivityLog.write("Quit while F1 25 is running — mods left in place") }
            return quit ? .terminateNow : .terminateCancel
        }
        let alert = NSAlert()
        alert.messageText = "Your mods are still installed"
        alert.informativeText = "Put the original game files back before quitting? If you keep the mods, they'll be removed the next time you open F1 25 Mod Launcher (unless the game is running then)."
        alert.addButton(withTitle: "Put Originals Back & Quit")
        alert.addButton(withTitle: "Keep Mods & Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                await performRestore(announce: false, reason: "quitting the launcher")
                ActivityLog.flush()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            ActivityLog.write("Quit with mods left installed")
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // MARK: Banner

    func showBanner(_ text: String, style: Banner.Style = .info) {
        withAnimation(.snappy) { banner = Banner(text: text, style: style) }
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { banner = nil }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject private var store: LauncherStore
    @State private var dropTargeted = false
    @State private var showProblems = false

    var body: some View {
        VStack(spacing: 0) {
            if store.gameDir == nil {
                SetupView()
            } else {
                if store.archives.isEmpty {
                    if store.isScanning || store.isIndexingGame {
                        ProgressView("Reading your mods…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyLibraryView()
                    }
                } else {
                    ModListView()
                }
                LaunchBar()
            }
        }
        .overlay(alignment: .top) { BannerView() }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(Label("Drop to add mods", systemImage: "square.and.arrow.down").font(.title2.weight(.semibold)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importItems(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search mods or teams")
        .navigationTitle("F1 25 Mod Launcher")
        .navigationSubtitle(store.subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.libraryProblems.isEmpty {
                    Button { showProblems.toggle() } label: {
                        Label("Problems", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .help("Some files in your mods folder couldn't be used")
                    .popover(isPresented: $showProblems) { ProblemsView() }
                }
                Button {
                    store.filter = store.filter == .favorites ? .all : .favorites
                } label: {
                    Label("Favorites Only", systemImage: store.filter == .favorites ? "star.fill" : "star")
                        .foregroundStyle(store.filter == .favorites ? Color.yellow : Color.primary)
                }
                .help(store.filter == .favorites ? "Showing favorites only — click to show all mods" : "Show only your favorite mods")
                Button { store.presentImportPanel() } label: { Label("Add Mods", systemImage: "plus") }
                    .help("Add mods (.zip, .rar, .7z or a folder)")
                Button { store.openModsFolder() } label: { Label("Mods Folder", systemImage: "folder") }
                    .help("Open the mods folder in Finder — make sub-folders to create categories")
                Button { store.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings")
            }
        }
        .sheet(isPresented: $store.showSettings) { SettingsView().environmentObject(store) }
        .alert(store.alert?.title ?? "", isPresented: Binding(
            get: { store.alert != nil },
            set: { if !$0 { store.alert = nil } }
        ), presenting: store.alert) { item in
            ForEach(item.actions) { action in
                Button(action.title, role: action.role) { action.run() }
            }
        } message: { item in
            Text(item.message)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        ContentUnavailableView {
            Label("Where's F1 25?", systemImage: "folder.badge.questionmark")
        } description: {
            Text("The launcher couldn't find F1 25 in your CrossOver bottles. Choose the “F1 25” folder inside your bottle — usually drive_c ▸ Program Files (x86) ▸ Steam ▸ steamapps ▸ common ▸ F1 25.")
        } actions: {
            Button("Choose Folder…") { store.chooseGameFolder() }
                .buttonStyle(.borderedProminent)
            Button("Search Again") { store.autodetectGame() }
        }
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        ContentUnavailableView {
            Label("No Mods Yet", systemImage: "paintbrush.pointed")
        } description: {
            Text("Drag livery mods onto this window — .zip, .rar or .7z archives, or a folder with your own livery files laid out like the game (2025_asset_groups/…).")
        } actions: {
            Button("Add Mods…") { store.presentImportPanel() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ModListView: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        List {
            ForEach(store.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        ArchiveView(row: row)
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if !store.hasVisibleMods {
                if store.filter == .favorites && store.search.isEmpty {
                    ContentUnavailableView("No Favorites Yet", systemImage: "star",
                                           description: Text("Click the star next to a mod to add it here."))
                } else if !store.search.isEmpty {
                    ContentUnavailableView.search(text: store.search)
                } else {
                    EmptyLibraryView()
                }
            }
        }
    }
}

struct ArchiveView: View {
    @EnvironmentObject private var store: LauncherStore
    let row: ArchiveRowModel

    var body: some View {
        Group {
            if row.archive.hasVariants {
                DisclosureGroup(isExpanded: store.expansionBinding(for: row.archive)) {
                    ForEach(row.entries) { entry in
                        EntryRow(entry: entry, title: entry.title)
                    }
                } label: {
                    VariantHeader(archive: row.archive)
                }
            } else if let entry = row.entries.first {
                EntryRow(entry: entry, title: row.archive.name)
            }
        }
        .contextMenu { ArchiveMenu(archive: row.archive) }
    }
}

struct VariantHeader: View {
    @EnvironmentObject private var store: LauncherStore
    let archive: ModArchive

    var body: some View {
        let selected = archive.entries.filter { store.selection.contains($0.id) }.count
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(archive.name).fontWeight(.medium).lineLimit(1)
                Text(selected > 0 ? "\(archive.entries.count) versions · \(selected) selected" : "\(archive.entries.count) versions — pick one")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct EntryRow: View {
    @EnvironmentObject private var store: LauncherStore
    let entry: ModEntry
    let title: String

    var body: some View {
        let isFavorite = store.favorites.contains(entry.id)
        HStack(spacing: 8) {
            Toggle(isOn: store.selectionBinding(for: entry)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 2)
            }
            .toggleStyle(.checkbox)
            .disabled(!store.canChangeSelection)
            Spacer(minLength: 8)
            if entry.isTextureMod && entry.textureSeasons.count > 1 {
                Menu {
                    ForEach(entry.textureSeasons, id: \.self) { season in
                        Button {
                            store.setTextureSeason(entry, to: season)
                        } label: {
                            if season == entry.textureSeason { Label(store.textureSeasonLabel(season), systemImage: "checkmark") }
                            else { Text(store.textureSeasonLabel(season)) }
                        }
                    }
                    Divider()
                    Button {
                        store.setTextureSeason(entry, to: "all")
                    } label: {
                        if entry.textureSeason == "all" { Label("All Cars", systemImage: "checkmark") } else { Text("All Cars") }
                    }
                } label: {
                    Text(store.textureSeasonLabel(entry.textureSeason))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!store.canChangeSelection)
                .help("Which car these textures go on. The launcher picked the one they look most like.")
            }
            if entry.isTextureMod {
                Pill(text: "Textures", color: .purple)
                    .help("Loose .dds textures — packed into the game's files when you launch.")
            }
            if store.installedIDs.contains(entry.id) {
                Pill(text: "Installed", color: .green)
            }
            if entry.isBaseFiles {
                Pill(text: "Base Files", color: .blue)
                    .help("Needed by many SERPs-compatible mods. Turned on automatically when a mod needs it.")
            } else if entry.needsBaseFiles {
                Pill(text: "Needs Base Files", color: .orange)
                    .help("This mod only works together with the SERPs Base Files.")
            }
            Button {
                store.toggleFavorite(entry)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.vertical, 3)
    }
}

/// The red launch button. Drawn by hand so it stays red when the window isn't focused.
struct LaunchButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.7))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isEnabled ? Color(red: 0.84, green: 0.11, blue: 0.16) : Color.gray.opacity(0.45))
            )
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .fixedSize()
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

struct ArchiveMenu: View {
    @EnvironmentObject private var store: LauncherStore
    let archive: ModArchive

    var body: some View {
        Button("Show in Finder") { store.reveal(archive) }
        Group {
            Button("Rename…") { store.beginRename(archive) }
            Menu("Move to Category") {
                Button("No Category") { store.move(archive, to: nil) }
                    .disabled(archive.category == nil)
                if !store.categories.isEmpty { Divider() }
                ForEach(store.categories, id: \.self) { category in
                    Button(category) { store.move(archive, to: category) }
                        .disabled(archive.category == category)
                }
                Divider()
                Button("New Category…") { store.beginNewCategory(archive) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { store.trash(archive) }
        }
        .disabled(!store.canChangeSelection)
    }
}

struct LaunchBar: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                switch store.phase {
                case .idle: idle
                case .installing, .restoring: working
                case .waitingForGame: waiting
                case .gameRunning: running
                case .gameClosed(let deadline): closed(until: deadline)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(minHeight: 72)
        }
        .background(.bar)
        .alert("Rename Mod", isPresented: Binding(
            get: { store.renameTarget != nil },
            set: { if !$0 { store.renameTarget = nil } }
        )) {
            TextField("Name", text: $store.renameText)
            Button("Rename") { store.commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Category", isPresented: Binding(
            get: { store.categoryTarget != nil },
            set: { if !$0 { store.categoryTarget = nil } }
        )) {
            TextField("Category name", text: $store.categoryText)
            Button("Create") { store.commitNewCategory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Categories are folders inside your mods folder.")
        }
    }

    private var headline: String {
        if store.isIndexingGame { return "Reading the game folder…" }
        if store.sessionPending { return "Some mods are still installed" }
        if store.gameRunning { return "F1 25 is already running" }
        switch store.selection.count {
        case 0: return "No mods selected"
        case 1: return "1 mod selected"
        default: return "\(store.selection.count) mods selected"
        }
    }

    private var detail: String {
        if store.sessionPending { return "Put the original game files back before launching again." }
        if store.gameRunning { return "Quit the game to launch it with mods." }
        let selected = store.selectedEntries
        if selected.isEmpty { return "F1 25 will start without mods." }
        return ListFormatter.localizedString(byJoining: selected.map(\.displayName))
    }

    private var idle: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(headline).font(.headline)
                    if !store.selection.isEmpty && store.canChangeSelection && !store.gameRunning {
                        Button("Clear") { store.clearSelection() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail)
                if !store.selection.isEmpty && !store.sessionPending && !store.gameRunning {
                    Label("Offline modes only — don't play online with mods.", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            if store.sessionPending {
                Button("Restore Original Files") { store.restoreNow() }
                    .controlSize(.large)
                    .disabled(store.gameRunning)
            } else {
                Menu {
                    Button("Install Mods Without Starting the Game") { store.launch(.installOnly) }
                        .disabled(store.selection.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .controlSize(.large)
                .fixedSize()
                .help("More launch options")
                .disabled(store.gameRunning)
                Button {
                    store.launch(.launch)
                } label: {
                    Label("Launch F1 25", systemImage: "flag.checkered")
                }
                .buttonStyle(LaunchButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(store.gameRunning || store.isIndexingGame)
                .help(store.isIndexingGame ? "Reading the game folder…" : "Install the ticked mods and start F1 25")
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.status.isEmpty ? "Working…" : store.status)
                .font(.callout)
                .lineLimit(1)
            ProgressView(value: store.progress)
        }
    }

    private var waiting: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mods installed — waiting for F1 25").font(.headline)
                if let lookFor = store.lookFor {
                    Label("In the game, look for: \(lookFor)", systemImage: "eye")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Text(store.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Restore Original Files") { store.restoreNow() }
                .help("Changed your mind? Put the original files back without playing.")
            if store.crossOver != nil {
                Button {
                    store.startGameAgain()
                } label: {
                    Label("Start F1 25", systemImage: "flag.checkered")
                }
                .buttonStyle(LaunchButtonStyle())
                .help("Ask Steam in CrossOver to start the game (your mods are already installed)")
            }
        }
    }

    private func closed(until deadline: Date) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("F1 25 closed — original files go back in \(seconds) s").font(.headline)
                }
                Text("Crashed, or going again? Keep the mods and start the game again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Restore Now") { store.restoreNow() }
            Button("Keep Mods Installed") { store.keepModsInstalled() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var running: some View {
        HStack(spacing: 14) {
            Image(systemName: "flag.checkered")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.installedIDs.isEmpty ? "F1 25 is running" : "F1 25 is running with your mods").font(.headline)
                if let lookFor = store.lookFor {
                    Label("Look for: \(lookFor)", systemImage: "eye")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Text("The original files go back after you quit the game. Keep this app open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }
}

struct BannerView: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        if let banner = store.banner {
            Label {
                Text(banner.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: banner.icon).foregroundStyle(banner.color)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.top, 10)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { withAnimation(.snappy) { store.banner = nil } }
            .id(banner.id)
        }
    }
}

struct ProblemsView: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Files that can't be used").font(.headline)
            ForEach(store.libraryProblems, id: \.self) { problem in
                Label(problem, systemImage: "doc.questionmark")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Mods need the usual SERPs layout: a 2025_asset_groups folder with the game files inside.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Mods Folder") { store.openModsFolder() }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LauncherStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("F1 25") {
                    LabeledContent("Game folder") {
                        Text(store.gameDir?.path ?? "Not set")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Button("Choose…") { store.chooseGameFolder() }
                        Button("Auto-Detect") { store.autodetectGame() }
                        Spacer()
                        Button("Show in Finder") {
                            if let dir = store.gameDir { NSWorkspace.shared.open(dir) }
                        }
                        .disabled(store.gameDir == nil)
                    }
                    .disabled(store.phase != .idle || store.sessionPending)
                }
                Section("CrossOver") {
                    LabeledContent("Bottle", value: store.crossOver?.bottleName ?? "Not found")
                    LabeledContent("App", value: store.crossOver?.appName ?? "Not found")
                    LabeledContent("Starts the game with") {
                        Text(store.crossOver == nil ? "Start F1 25 yourself in CrossOver" : "Steam in the bottle (like pressing Play)")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Mods") {
                    LabeledContent("Mods folder") {
                        Text(AppPaths.mods.path)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Button("Open Mods Folder") { store.openModsFolder() }
                        Button("Refresh") { store.rescan() }
                        Button("Activity Log") { store.openActivityLog() }
                        Spacer()
                        if store.sessionPending {
                            Button("Restore Original Files") { store.restoreNow() }
                                .disabled(store.gameRunning || store.phase != .idle)
                        }
                    }
                }
                Section {
                    Text("A Mac version of SERPs Launcher for F1 25 by Team Simplified (MIT License). When you launch, the selected mods are copied into the game folder and the files they replace are set aside; when F1 25 closes, everything is put back exactly as it was.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 700)
    }
}
