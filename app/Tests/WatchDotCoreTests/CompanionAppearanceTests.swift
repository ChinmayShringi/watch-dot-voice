import XCTest
@testable import WatchDotCore

final class CompanionAppearanceTests: XCTestCase {
    func testMissingOptionalAssetFallsBackWithoutChangingSavedIdentity() {
        let savedID = "sprite"
        XCTAssertEqual(CompanionAppearance.resolve(savedID: savedID, spriteAvailable: false), .pebble)
        XCTAssertEqual(CompanionAppearance.resolve(savedID: savedID, spriteAvailable: true), .sprite)
    }

    func testUnknownPersistedValueResolvesToOriginalInEitherBuild() {
        for value in ["", "removed-appearance", "SPRITE"] {
            XCTAssertEqual(CompanionAppearance.resolve(savedID: value, spriteAvailable: false), .pebble)
            XCTAssertEqual(CompanionAppearance.resolve(savedID: value, spriteAvailable: true), .pebble)
        }
    }

    func testOriginalPreferencesSurviveOptionalAssetChanges() {
        for appearance in [CompanionAppearance.pebble, .orbit, .pixel] {
            for spriteAvailable in [true, false] {
                XCTAssertEqual(CompanionAppearance.resolve(savedID: appearance.rawValue,
                    spriteAvailable: spriteAvailable), appearance)
            }
        }
    }

    func testUnavailableSpriteCannotAppearInPicker() {
        XCTAssertEqual(CompanionAppearance.available(spriteAvailable: false), [.pebble, .orbit, .pixel])
        XCTAssertEqual(CompanionAppearance.available(spriteAvailable: true), [.sprite, .pebble, .orbit, .pixel])
    }

    func testSpriteUsesConnectedNameWhileOriginalNamesStayStable() {
        XCTAssertEqual(CompanionAppearance.sprite.displayName(spriteName: "My Companion"), "My Companion")
        XCTAssertEqual(CompanionAppearance.pebble.displayName(spriteName: "My Companion"), "Pebble")
        XCTAssertEqual(CompanionAppearance.orbit.displayName(spriteName: "My Companion"), "Orbit")
        XCTAssertEqual(CompanionAppearance.pixel.displayName(spriteName: "My Companion"), "Pixel")
    }
}
