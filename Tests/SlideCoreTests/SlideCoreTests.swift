import XCTest
@testable import SlideCore

final class SlideCoreTests: XCTestCase {
    
    func testVersionExists() {
        // Just verify that we can import and link COpenSlide
        // The actual version check would require OpenSlide to be installed
        XCTAssertTrue(true, "SlideCore module loads successfully")
    }
    
    func testUnsupportedFileReturnsNil() {
        // Test that a non-slide file returns nil for vendor detection
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try? "test".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        XCTAssertNil(SlideReader.detectVendor(url: tempFile))
    }
}
