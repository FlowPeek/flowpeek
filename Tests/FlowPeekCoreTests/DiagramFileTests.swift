import XCTest
@testable import FlowPeekCore

final class DiagramFileTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/release-train.mmd")

    func testAPreviewIsNamedAfterTheFile() {
        XCTAssertEqual(DiagramFile.title(for: url, fallback: "Diagram"), "release-train")
    }

    /// A file whose whole name is `.mmd` is a hidden file called `.mmd`, and Foundation does not
    /// treat a leading dot as an extension. Titling the window with the name it has is truthful;
    /// inventing a different one would not be.
    func testAHiddenFileKeepsTheNameItHas() {
        XCTAssertEqual(
            DiagramFile.title(for: URL(fileURLWithPath: "/tmp/.mmd"), fallback: "Diagram"),
            ".mmd"
        )
    }

    /// Defensive: nothing Finder hands over has an empty name, and a window titled with nothing is
    /// a window nobody can find in a list.
    func testAnEmptyNameFallsBack() {
        XCTAssertEqual(DiagramFile.title(for: URL(fileURLWithPath: "/"), fallback: "Diagram"), "Diagram")
    }

    func testASecondExtensionIsKept() {
        // `notes.v2.mmd` is a file called "notes.v2", not one called "notes".
        XCTAssertEqual(
            DiagramFile.title(for: URL(fileURLWithPath: "/tmp/notes.v2.mmd"), fallback: "Diagram"),
            "notes.v2"
        )
    }

    func testAFileIsRead() throws {
        let text = try DiagramFile.read(
            contentsOf: url,
            attributes: { _ in 40 },
            contents: { _ in "flowchart LR\n  A --> B" }
        )
        XCTAssertEqual(text, "flowchart LR\n  A --> B")
    }

    /// The size is checked before the contents are touched, so an enormous file costs an attribute
    /// lookup rather than the memory to hold it.
    func testSomethingEnormousIsRefusedWithoutBeingRead() {
        var readContents = false
        XCTAssertThrowsError(
            try DiagramFile.read(
                contentsOf: url,
                attributes: { _ in DiagramFile.maximumBytes + 1 },
                contents: { _ in readContents = true; return "" }
            )
        ) { error in
            XCTAssertEqual(error as? DiagramFile.Failure, .tooLarge(bytes: DiagramFile.maximumBytes + 1))
        }
        XCTAssertFalse(readContents, "the contents were read after the size had already refused them")
    }

    func testExactlyTheLimitIsAllowed() throws {
        _ = try DiagramFile.read(
            contentsOf: url,
            attributes: { _ in DiagramFile.maximumBytes },
            contents: { _ in "flowchart LR\n  A --> B" }
        )
    }

    func testSomethingThatIsNotTextIsRefused() {
        XCTAssertThrowsError(
            try DiagramFile.read(contentsOf: url, attributes: { _ in 10 }, contents: { _ in nil })
        ) { error in
            XCTAssertEqual(error as? DiagramFile.Failure, .notText)
        }
    }

    /// A file whose size cannot be read is still worth trying: an unreadable attribute is not the
    /// same as an unreadable file.
    func testAnUnknownSizeIsNotARefusal() throws {
        let text = try DiagramFile.read(
            contentsOf: url,
            attributes: { _ in nil },
            contents: { _ in "flowchart LR\n  A --> B" }
        )
        XCTAssertFalse(text.isEmpty)
    }
}
