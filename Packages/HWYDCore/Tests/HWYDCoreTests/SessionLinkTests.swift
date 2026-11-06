import XCTest
@testable import HWYDCore

final class SessionLinkTests: XCTestCase {
    let id = UUID(uuidString: "467F65AC-2420-4C18-9043-CEEA5CE60254")!

    func testParsesCanonicalAndResourceLinks() {
        XCTAssertEqual(SessionLink(URL(string: "hwyd://session/467f65ac-2420-4c18-9043-ceea5ce60254")!), SessionLink(SessionLink.session(id)))
        XCTAssertEqual(SessionLink(SessionLink.session(id))?.recordingID, id)
        XCTAssertNil(SessionLink(SessionLink.session(id))?.artifact)
        XCTAssertEqual(SessionLink(URL(string: "hwyd://recording/\(id.uuidString)/notes.md")!)?.artifact, .notes)
        XCTAssertEqual(SessionLink(URL(string: "hwyd://recording/\(id.uuidString)/summary.md")!)?.artifact, .summary)
        XCTAssertEqual(SessionLink(URL(string: "hwyd://recording/\(id.uuidString)")!)?.recordingID, id)
    }

    func testRejectsOtherShapes() {
        for raw in ["https://session/\(id.uuidString)", "hwyd://session/not-a-uuid", "hwyd://session/\(id.uuidString)/notes.md",
                    "hwyd://recording/\(id.uuidString)/audio.md", "hwyd://recording/\(id.uuidString)/notes.md?x=1", "hwyd://people/\(id.uuidString)"] {
            XCTAssertNil(SessionLink(URL(string: raw)!), raw)
        }
    }

    func testExportOmitsAbsentSummary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = Recording(title: "Sans synthèse", notes: "Notes")
        XCTAssertEqual(SessionExporter.artifact(recording, "summary"), "")
        try SessionExporter.export(recording, to: directory)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasSuffix(".md") })
        let markdown = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
        XCTAssertFalse(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("## Notes") && markdown.contains("## Transcript"))
    }
}
