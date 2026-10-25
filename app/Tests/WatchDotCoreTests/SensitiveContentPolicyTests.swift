import XCTest
@testable import WatchDotCore

final class SensitiveContentPolicyTests: XCTestCase {
    func testContentVisibleOnlyInActiveUnprotectedDisplay() {
        for active in [false, true] {
            for dimmed in [false, true] {
                for redacted in [false, true] {
                    XCTAssertEqual(SensitiveContentPolicy.isVisible(isActive: active,
                        luminanceReduced: dimmed, privacyRedacted: redacted), active && !dimmed && !redacted)
                }
            }
        }
    }
}
