import XCTest
@testable import WatchDotCore

final class AvatarSelectionTests: XCTestCase {
    func testDownloadedIdentifiersDoNotCollideWithLocalPreferences() {
        XCTAssertEqual(AvatarSelection.identifier(for: "pebble"), "pet:pebble")
        XCTAssertEqual(AvatarSelection.petID(from: "pet:pebble"), "pebble")
        XCTAssertNil(AvatarSelection.petID(from: "sprite"))
        XCTAssertNil(AvatarSelection.petID(from: "pet:"))
    }

    func testCatalogRefreshPreservesFocusedPageByIdentity() {
        XCTAssertEqual(AvatarSelection.page(current: "pet:two", selected: "pet:one",
            available: ["pet:three", "pet:one", "pet:two"]), "pet:two")
    }

    func testRemovedPageResolvesToSelectionThenLocalFallback() {
        XCTAssertEqual(AvatarSelection.page(current: "pet:gone", selected: "sprite",
            available: ["pebble", "sprite"]), "sprite")
        XCTAssertEqual(AvatarSelection.page(current: "pet:gone", selected: "pet:missing",
            available: ["pebble", "orbit"]), "pebble")
        XCTAssertEqual(AvatarSelection.page(current: "", selected: "", available: []), "pebble")
    }
}
