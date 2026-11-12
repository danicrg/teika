import SwiftData
import XCTest
@testable import Teika

/// The vault in these tests mirrors a real one: Unique note creator writing
/// `YYYY-MM-DD HHmm` notes to the root from `Templates/Journal Template`.
@MainActor
final class ObsidianExportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let en = Locale(identifier: "en_US_POSIX")
    /// 2026-11-05 14:32:09.250 UTC, a Thursday.
    private let date = Date(timeIntervalSince1970: 1_793_889_129.25)
    private var vault: URL!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: vault.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: vault.appending(path: "Templates"), withIntermediateDirectories: true)
        try write(".obsidian/zk-prefixer.json", #"""
            {"format": "YYYY-MM-DD HHmm", "folder": "/", "template": "Templates/Journal Template"}
            """#)
        try write(".obsidian/templates.json", #"{"folder": "Templates"}"#)
        try write("Templates/Journal Template.md", "---\ncreated: {{date}}\n---\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: moment formats

    func testMomentFormatsCommonObsidianPatterns() {
        func f(_ format: String) -> String {
            MomentFormat.string(from: date, format: format, locale: en, timeZone: utc)
        }
        XCTAssertEqual(f("YYYY-MM-DD HHmm"), "2026-11-05 1432")
        XCTAssertEqual(f("YYYYMMDDHHmm"), "202611051432")
        XCTAssertEqual(f("YYYY-MM-DD"), "2026-11-05")
        XCTAssertEqual(f("HH:mm:ss.SSS"), "14:32:09.250")
        XCTAssertEqual(f("dddd, MMMM Do YYYY"), "Thursday, November 5th 2026")
        XCTAssertEqual(f("ddd D MMM YY"), "Thu 5 Nov 26")
        XCTAssertEqual(f("h:mm A"), "2:32 PM")
        XCTAssertEqual(f("GGGG-[W]WW"), "2026-W45")
        XCTAssertEqual(f("[Voice] YYYY"), "Voice 2026")
        XCTAssertEqual(f("Q"), "4")
        XCTAssertEqual(f("DDDD"), "309")
    }

    // MARK: settings and templates

    func testVaultSettingsFollowTheUniqueNoteCreator() {
        let settings = VaultNoteSettings.fromVault(
            uniqueNoteJSON: Data(#"{"format":"YYYY-MM-DD HHmm","folder":"/","template":"Templates/Journal Template"}"#.utf8),
            templatesJSON: Data(#"{"folder":"Templates"}"#.utf8))
        XCTAssertEqual(settings.filenameFormat, "YYYY-MM-DD HHmm")
        XCTAssertEqual(settings.resolvedFolder(for: date, timeZone: utc), "")
        XCTAssertEqual(settings.resolvedTemplatePath, "Templates/Journal Template.md")
        XCTAssertEqual(settings.dateFormat, "YYYY-MM-DD")
        XCTAssertEqual(settings.timeFormat, "HH:mm")
    }

    func testOverridesWinAndMissingSettingsFallBack() {
        let none = VaultNoteSettings.fromVault(uniqueNoteJSON: nil, templatesJSON: nil)
        XCTAssertEqual(none.filenameFormat, "YYYY-MM-DD HHmm")
        XCTAssertNil(none.resolvedTemplatePath)

        // Obsidian's own default when the plugin is set up without a format.
        let bare = VaultNoteSettings.fromVault(uniqueNoteJSON: Data("{}".utf8), templatesJSON: nil)
        XCTAssertEqual(bare.filenameFormat, "YYYYMMDDHHmm")

        let overridden = VaultNoteSettings.fromVault(
            uniqueNoteJSON: Data(#"{"format":"YYYY-MM-DD HHmm","folder":"/"}"#.utf8),
            templatesJSON: Data(#"{"dateFormat":"DD.MM.YYYY"}"#.utf8),
            overrides: .init(filenameFormat: "[Voice] YYYY-MM-DD HHmm", folder: "Inbox/{{date:YYYY}}/"))
        XCTAssertEqual(overridden.baseName(for: date, timeZone: utc), "Voice 2026-11-05 1432")
        XCTAssertEqual(overridden.resolvedFolder(for: date, timeZone: utc), "Inbox/2026")
        XCTAssertEqual(overridden.dateFormat, "DD.MM.YYYY")
    }

    func testTemplateRendersLikeObsidianAndPlacesTheTranscript() {
        let settings = VaultNoteSettings()
        let after = VaultNoteTemplate.render(
            template: "---\ncreated: {{date}}\n---", title: "2026-11-05 1432", date: date,
            settings: settings, timeZone: utc)
        XCTAssertEqual(after.content(with: "Call mom."), "---\ncreated: 2026-11-05\n---\nCall mom.")

        let placed = VaultNoteTemplate.render(
            template: "# {{title}}\n{{text}}\n\nat {{time}} on {{date:dddd}} {{unknown}}",
            title: "Note", date: date, settings: settings, timeZone: utc)
        XCTAssertEqual(
            placed.content(with: "Hello"), "# Note\nHello\n\nat 14:32 on Thursday {{unknown}}")

        XCTAssertEqual(
            VaultNoteTemplate.render(
                template: nil, title: "x", date: date, settings: settings
            ).content(with: "Just text"),
            "Just text")
    }

    func testFileNamesDropCharactersObsidianRejects() {
        XCTAssertEqual(VaultNoteTemplate.sanitizedName("a/b:c*d?e|f#g^h[i]"), "a-b-c-d-e-f-g-h-i-")
        XCTAssertEqual(VaultNoteTemplate.sanitizedName("..hidden"), "hidden")
    }

    // MARK: writer

    func testCreatesAUniqueNoteFromTheVaultsTemplate() throws {
        let writer = VaultWriter(root: vault, scoped: false)
        let first = try writer.create(text: "Buy oat milk.", date: date, overrides: .init(), timeZone: utc)
        let second = try writer.create(text: "Second thought.", date: date, overrides: .init(), timeZone: utc)

        XCTAssertEqual(first.path, "2026-11-05 1432.md")
        XCTAssertEqual(second.path, "2026-11-05 1432 2.md")
        XCTAssertEqual(try read(first.path), "---\ncreated: 2026-11-05\n---\nBuy oat milk.")
        XCTAssertEqual(try read(second.path), "---\ncreated: 2026-11-05\n---\nSecond thought.")
    }

    func testFolderOverrideIsCreated() throws {
        let writer = VaultWriter(root: vault, scoped: false)
        let record = try writer.create(
            text: "x", date: date, overrides: .init(folder: "Inbox/Voice"), timeZone: utc)
        XCTAssertEqual(record.path, "Inbox/Voice/2026-11-05 1432.md")
        XCTAssertEqual(try read(record.path), "---\ncreated: 2026-11-05\n---\nx")
    }

    func testUpdatesOnlyAFileNobodyElseChanged() throws {
        let writer = VaultWriter(root: vault, scoped: false)
        let record = try writer.create(text: "First draft", date: date, overrides: .init(), timeZone: utc)

        guard case .saved(let updated) = try writer.update(record, text: "First draft, fixed") else {
            return XCTFail("expected a save")
        }
        XCTAssertEqual(try read(record.path), "---\ncreated: 2026-11-05\n---\nFirst draft, fixed")

        try write(record.path, "---\ncreated: 2026-11-05\n---\nEdited in Obsidian")
        XCTAssertEqual(try writer.update(updated, text: "Teika again"), .editedElsewhere)
        XCTAssertEqual(try read(record.path), "---\ncreated: 2026-11-05\n---\nEdited in Obsidian")
    }

    func testFollowsANoteRenamedInObsidianAndReportsDeletedOnes() throws {
        let writer = VaultWriter(root: vault, scoped: false)
        let record = try writer.create(text: "Trip idea", date: date, overrides: .init(), timeZone: utc)
        try FileManager.default.moveItem(
            at: vault.appending(path: record.path), to: vault.appending(path: "Trip idea.md"))

        guard case .saved(let followed) = try writer.update(record, text: "Trip idea: Lisbon") else {
            return XCTFail("expected the renamed file to be found")
        }
        XCTAssertEqual(followed.path, "Trip idea.md")
        XCTAssertEqual(try read("Trip idea.md"), "---\ncreated: 2026-11-05\n---\nTrip idea: Lisbon")

        try FileManager.default.removeItem(at: vault.appending(path: "Trip idea.md"))
        XCTAssertEqual(try writer.update(followed, text: "gone"), .missing)
    }

    // MARK: exporter

    func testNothingReachesTheVaultUntilSaved() async throws {
        let (store, exporter) = try makeExporter()
        let note = try store.add(text: "Remember the dentist", createdAt: date, isDraft: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(note.vaultState)
        XCTAssertEqual(try markdownFiles(), [])

        let saved = await exporter.save(note)
        XCTAssertTrue(saved)
        XCTAssertEqual(note.vaultState, .saved)
        let path = try XCTUnwrap(note.vaultPath)
        XCTAssertEqual(try read(path), "---\ncreated: 2026-11-05\n---\nRemember the dentist")
        XCTAssertEqual(exporter.savedSerial, 1)
    }

    func testSavingAgainUpdatesTheSameFileUnlessObsidianChangedIt() async throws {
        let (store, exporter) = try makeExporter()
        let note = try store.add(text: "Remember the dentist", createdAt: date)
        await exporter.save(note)
        let path = try XCTUnwrap(note.vaultPath)

        note.text = "Remember the dentist on Friday"
        XCTAssertTrue(note.hasUnsavedVaultChanges)
        XCTAssertEqual(try read(path), "---\ncreated: 2026-11-05\n---\nRemember the dentist", "edits wait for Save")
        await exporter.save(note)
        XCTAssertFalse(note.hasUnsavedVaultChanges)
        XCTAssertEqual(try read(path), "---\ncreated: 2026-11-05\n---\nRemember the dentist on Friday")
        XCTAssertEqual(try markdownFiles().count, 1, "a second save must not create a second file")

        try write(path, "changed in Obsidian")
        note.text = "Teika edit"
        let overwrote = await exporter.save(note)
        XCTAssertFalse(overwrote)
        XCTAssertEqual(note.vaultState, .editedElsewhere)
        XCTAssertEqual(try read(path), "changed in Obsidian")

        await exporter.saveAsNewNote(note)
        XCTAssertEqual(note.vaultState, .saved)
        XCTAssertNotEqual(note.vaultPath, path)
        XCTAssertTrue(try read(try XCTUnwrap(note.vaultPath)).hasSuffix("---\nTeika edit"))
    }

    func testEmptyNotesAreNotSaved() async throws {
        let (store, exporter) = try makeExporter()
        let note = try store.add(text: "  \n", createdAt: date)
        let saved = await exporter.save(note)
        XCTAssertFalse(saved)
        XCTAssertEqual(try markdownFiles(), [])
    }

    // MARK: drafts

    func testTheNewestDraftIsResumed() throws {
        let store = try NoteStore(inMemory: true)
        _ = try store.add(text: "Finished", createdAt: date)
        _ = try store.add(text: "Old draft", createdAt: date, isDraft: true)
        let newest = try store.add(text: "New draft", createdAt: date.addingTimeInterval(60), isDraft: true)
        XCTAssertEqual(store.currentDraft()?.persistentModelID, newest.persistentModelID)
        newest.isDraft = nil
        XCTAssertEqual(store.currentDraft()?.text, "Old draft")
    }

    func testDictationGoesInAtTheCursorWithSensibleSpacing() {
        XCTAssertEqual(DraftText.insert("More.", into: "First thought.").text, "First thought. More.")
        XCTAssertEqual(DraftText.insert(" More. ", into: "Line\n").text, "Line\nMore.")
        XCTAssertEqual(DraftText.insert("Start.", into: "").text, "Start.")

        let middle = DraftText.insert("really", into: "I want coffee.", replacing: 7..<7)
        XCTAssertEqual(middle.text, "I want really coffee.")
        XCTAssertEqual(middle.cursor, 14)

        let replaced = DraftText.insert("tea", into: "I want coffee.", replacing: 7..<13)
        XCTAssertEqual(replaced.text, "I want tea.")
        XCTAssertEqual(replaced.cursor, 10)

        XCTAssertEqual(DraftText.insert("x", into: "abc", replacing: 10..<20).text, "abc x")
        XCTAssertEqual(DraftText.insert("  ", into: "abc").text, "abc")
    }

    // MARK: helpers

    private func makeExporter() throws -> (NoteStore, ObsidianExporter) {
        let defaults = UserDefaults(suiteName: "obsidian-\(UUID().uuidString)")!
        defaults.set(true, forKey: ObsidianExporter.enabledKey)
        // Any bookmark counts as set up; the injected writer stands in for it.
        defaults.set(Data([1]), forKey: ObsidianExporter.bookmarkKey)
        let store = try NoteStore(inMemory: true, defaults: defaults)
        let exporter = ObsidianExporter(store: store) { [vault] in VaultWriter(root: vault!, scoped: false) }
        return (store, exporter)
    }

    private func markdownFiles() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: vault.path(percentEncoded: false))
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix("Templates/") }
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: vault.appending(path: path))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: vault.appending(path: path), encoding: .utf8)
    }
}
