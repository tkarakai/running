import Foundation
import Testing
@testable import Running

@Test func newerVersionsCompareNumerically() {
    #expect(Updater.isNewer("0.8.0", than: "0.7.0"))
    #expect(Updater.isNewer("0.10.0", than: "0.9.3"))
    #expect(Updater.isNewer("1.0", than: "0.99.99"))
    #expect(!Updater.isNewer("0.7.0", than: "0.7.0"))
    #expect(!Updater.isNewer("0.7.0", than: "0.7.1"))
    #expect(!Updater.isNewer("0.7.0", than: "0.7.0-dev"))
    #expect(Updater.isNewer("0.7.1", than: "0.7.0-dev"))
}

@Test func releaseParsesTheDiskImageAndItsChecksum() throws {
    let json = """
    {"tag_name":"v0.8.0","html_url":"https://github.com/tkarakai/running/releases/tag/v0.8.0",
     "body":"### Added\\n- **Updates** in the app\\n\\n## Downloads\\n\\nDrag it…",
     "assets":[
       {"name":"running-0.8.0-macos.tar.xz","size":1,"browser_download_url":"https://x/a.tar.xz","digest":"sha256:aa"},
       {"name":"Running-0.8.0-arm64.dmg","size":32555348,"browser_download_url":"https://x/Running-0.8.0-arm64.dmg","digest":"sha256:7D58"}]}
    """
    let r = try Updater.parse(Data(json.utf8))
    #expect(r.version == "0.8.0")
    #expect(r.dmg.absoluteString == "https://x/Running-0.8.0-arm64.dmg")
    #expect(r.size == 32555348)
    #expect(r.sha256 == "7D58")
    #expect(r.notes == "### Added\n- **Updates** in the app") // download instructions cut off
}

@Test func releaseWithoutADiskImageIsRejected() {
    let json = #"{"tag_name":"v0.8.0","html_url":"https://x","assets":[]}"#
    #expect(throws: UpdateError.self) { try Updater.parse(Data(json.utf8)) }
}

@MainActor @Test func releaseNotesBecomeHeadingsAndBullets() {
    let n = ReleaseNotes(markdown: "### Added\n- One\n  continued\n- Two\n\nPlain text")
    #expect(n.blocks == [.heading("Added"), .bullet("One continued"), .bullet("Two"), .text("Plain text")])
}
