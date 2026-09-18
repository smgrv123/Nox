import XCTest

@testable import Personalization

final class BiasPromptCacheTests: XCTestCase {

    private struct Boom: Error {}

    func testReturnsMemoizedValueWhenGenerationUnchanged() async throws {
        let cache = BiasPromptCache()
        var computeCount = 0

        let first = await cache.value(forGeneration: 1) {
            computeCount += 1
            return "prompt-a"
        }
        let second = await cache.value(forGeneration: 1) {
            computeCount += 1
            return "prompt-b"
        }

        XCTAssertEqual(first, "prompt-a")
        XCTAssertEqual(second, "prompt-a", "same generation must return the memoized value, not recompute")
        XCTAssertEqual(computeCount, 1, "compute must not run again for an unchanged generation")
    }

    func testRecomputesWhenGenerationChanges() async throws {
        let cache = BiasPromptCache()
        var computeCount = 0

        _ = await cache.value(forGeneration: 1) {
            computeCount += 1
            return "prompt-a"
        }
        let second = await cache.value(forGeneration: 2) {
            computeCount += 1
            return "prompt-b"
        }

        XCTAssertEqual(second, "prompt-b")
        XCTAssertEqual(computeCount, 2, "a changed generation must recompute")
    }

    func testCachesANilValueWithoutRecomputing() async throws {
        let cache = BiasPromptCache()
        var computeCount = 0

        let first = await cache.value(forGeneration: 1) {
            computeCount += 1
            return nil
        }
        let second = await cache.value(forGeneration: 1) {
            computeCount += 1
            return "should-not-run"
        }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(computeCount, 1, "a memoized nil result must still short-circuit recompute")
    }

    func testThrowFromComputePropagatesAndLeavesCacheUntouched() async throws {
        let cache = BiasPromptCache()
        var computeCount = 0

        do {
            _ = try await cache.value(forGeneration: 1) {
                computeCount += 1
                throw Boom()
            }
            XCTFail("expected Boom to propagate")
        } catch is Boom {
            // expected
        }

        let recovered = await cache.value(forGeneration: 1) {
            computeCount += 1
            return "prompt-a"
        }

        XCTAssertEqual(recovered, "prompt-a")
        XCTAssertEqual(computeCount, 2, "a throw must not be cached — the same generation must retry")
    }
}
