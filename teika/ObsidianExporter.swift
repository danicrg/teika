import Foundation
import Observation
import SwiftData

/// Saves notes into an Obsidian vault, each as its own Markdown file, named and filled
/// the way the vault's Unique note creator would. Saving is always explicit; saving a
/// note again updates its file until that file is changed in Obsidian.
///
/// Independent of the task exporter: a note can go to Things and to the vault.
@MainActor
@Observable
final class ObsidianExporter {
    static let enabledKey = "obsidianExportEnabled"
    static let bookmarkKey = "obsidianVaultBookmark"
    static let vaultNameKey = "obsidianVaultName"
    static let folderKey = "obsidianFolderOverride"
    static let filenameKey = "obsidianFilenameOverride"
    static let templateKey = "obsidianTemplateOverride"

    static func isActive(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey) && defaults.data(forKey: bookmarkKey) != nil
    }

    private(set) var isEnabled: Bool
    private(set) var vaultName: String?
    /// The vault's own settings, before Teika's overrides. Nil until read.
    private(set) var vaultSettings: VaultNoteSettings?
    private(set) var effectiveSettings: VaultNoteSettings?
    private(set) var setupError: String?
    private(set) var lastError: String?
    /// Bumped for each successful save, for a confirmation on screen.
    private(set) var savedSerial = 0
    private(set) var lastSavedPath: String?
    private(set) var isSaving = false

    var overrides: VaultNoteSettings.Overrides {
        didSet {
            guard overrides != oldValue else { return }
            store.defaults.set(overrides.folder, forKey: Self.folderKey)
            store.defaults.set(overrides.filenameFormat, forKey: Self.filenameKey)
            store.defaults.set(overrides.templatePath, forKey: Self.templateKey)
            recomputeEffective()
        }
    }

    var hasVault: Bool { store.defaults.data(forKey: Self.bookmarkKey) != nil }

    private let store: NoteStore
    private let makeWriter: (@MainActor () -> VaultWriter?)?
    private let now: () -> Date

    /// `writer` replaces the bookmarked vault, for tests.
    init(
        store: NoteStore, now: @escaping () -> Date = Date.init,
        writer: (@MainActor () -> VaultWriter?)? = nil
    ) {
        self.store = store
        self.makeWriter = writer
        self.now = now
        let defaults = store.defaults
        isEnabled = Self.isActive(in: defaults) || (writer != nil && defaults.bool(forKey: Self.enabledKey))
        vaultName = defaults.string(forKey: Self.vaultNameKey)
        overrides = .init(
            filenameFormat: defaults.string(forKey: Self.filenameKey) ?? "",
            folder: defaults.string(forKey: Self.folderKey) ?? "",
            templatePath: defaults.string(forKey: Self.templateKey) ?? "")
    }

    // MARK: Setup

    /// Takes a folder from the document picker. The picker's URL is security-scoped
    /// for this launch only; the bookmark keeps access across launches.
    func chooseVault(_ url: URL) {
        setupError = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            store.defaults.set(bookmark, forKey: Self.bookmarkKey)
            store.defaults.set(url.lastPathComponent, forKey: Self.vaultNameKey)
            vaultName = url.lastPathComponent
            setEnabled(true)
            Task { await refreshSettings() }
        } catch {
            setupError = "Couldn’t keep access to that folder. Choose it again."
        }
    }

    func removeVault() {
        store.defaults.removeObject(forKey: Self.bookmarkKey)
        store.defaults.removeObject(forKey: Self.vaultNameKey)
        vaultName = nil
        vaultSettings = nil
        effectiveSettings = nil
        setEnabled(false)
    }

    func setEnabled(_ enabled: Bool) {
        store.defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled && (hasVault || makeWriter != nil)
    }

    /// Reads the vault's Unique note and Templates settings, for display.
    func refreshSettings() async {
        guard let writer = writer() else { return }
        let result = await Task.detached { Result { try writer.settings(overrides: .init()) } }.value
        switch result {
        case .success(let settings):
            vaultSettings = settings
            setupError = nil
        case .failure:
            vaultSettings = nil
            setupError = "Couldn’t read the vault. Open Obsidian once, or choose the folder again."
        }
        recomputeEffective()
    }

    private func recomputeEffective() {
        guard let vaultSettings else { effectiveSettings = nil; return }
        var settings = vaultSettings
        if !overrides.filenameFormat.trimmed.isEmpty { settings.filenameFormat = overrides.filenameFormat }
        if !overrides.folder.trimmed.isEmpty { settings.folder = overrides.folder }
        if !overrides.templatePath.trimmed.isEmpty { settings.templatePath = overrides.templatePath }
        effectiveSettings = settings
    }

    /// An example file path for the current settings.
    var examplePath: String? {
        guard let effectiveSettings else { return nil }
        let date = now()
        let folder = effectiveSettings.resolvedFolder(for: date)
        let name = effectiveSettings.baseName(for: date) + ".md"
        return folder.isEmpty ? name : "\(folder)/\(name)"
    }

    private func writer() -> VaultWriter? {
        if let makeWriter { return makeWriter() }
        guard let bookmark = store.defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            setupError = "Teika lost access to the vault. Choose the folder again."
            return nil
        }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(
                options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                store.defaults.set(fresh, forKey: Self.bookmarkKey)
            }
        }
        return VaultWriter(root: url)
    }

    // MARK: Saving

    /// Nothing reaches the vault on its own: a note is written only when saved here.
    /// The first save creates a uniquely named file; later saves of the same note
    /// rewrite the transcript in that file, unless it was changed in Obsidian.
    @discardableResult
    func save(_ note: Note) async -> Bool {
        guard isEnabled, !note.isDeleted, note.modelContext != nil, !isSaving else { return false }
        let context = store.container.mainContext
        let id = note.persistentModelID
        let text = note.text
        let record = note.vaultRecord
        guard !text.trimmed.isEmpty else { return false }
        if record != nil, note.vaultState == .saved, note.vaultSyncedText == text { return true }
        guard let writer = writer() else {
            lastError = "Teika lost access to the vault. Choose the folder again in Settings."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let createdAt = note.createdAt
        let overrides = overrides
        let result = await Task.detached { () -> Result<VaultWriteResult, Error> in
            Result {
                if let record { return try writer.update(record, text: text) }
                return .saved(try writer.create(text: text, date: createdAt, overrides: overrides))
            }
        }.value

        // The note may have been deleted while the file was written.
        guard let note = context.model(for: id) as? Note, !note.isDeleted, note.modelContext != nil
        else { return false }
        var saved = false
        switch result {
        case .success(.saved(let written)):
            note.vaultRecord = written
            note.vaultSyncedText = text
            note.vaultState = .saved
            lastError = nil
            lastSavedPath = written.path
            savedSerial += 1
            saved = true
        case .success(.editedElsewhere):
            note.vaultState = .editedElsewhere
            lastError = "This note was changed in Obsidian, so Teika didn’t overwrite it."
        case .success(.missing):
            note.vaultState = .missing
            lastError = "This note was moved or deleted in Obsidian."
        case .failure:
            lastError = "Couldn’t save to Obsidian. Check that iCloud Drive is available and try again."
        }
        try? context.save()
        return saved
    }

    /// Detaches a note from a file that was edited or removed in Obsidian, and saves
    /// it as a new note there instead.
    @discardableResult
    func saveAsNewNote(_ note: Note) async -> Bool {
        note.vaultRecord = nil
        note.vaultSyncedText = nil
        note.vaultState = nil
        try? store.container.mainContext.save()
        return await save(note)
    }
}
