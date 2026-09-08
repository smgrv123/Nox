import Foundation
import LLMRuntime
import SkillManifest
import XCTest

@testable import CommandRouter

final class LocalCommandRouterTests: XCTestCase {

    private let fixtureEndpoint = LLMEndpoint(
        baseURL: URL(string: "http://127.0.0.1:5555")!, model: "test-model", isLocal: true)

    private let cannedRaw =
        #"{"intent":"open Safari","skill_id":"open_application","parameters":{"app_name":"Safari"}}"#

    func testRouteReturnsExpectedRoutedIntentFromCannedCompletion() async throws {
        let valueRange = try utf8Range(of: #""open_application""#, in: cannedRaw)
        let completion = RouterCompletion(
            raw: cannedRaw,
            tokenLogprobs: [
                TokenLogprob(token: #""open_application""#, logprob: -0.08, byteRange: valueRange)
            ])
        let client = MockLLMClient(routeCompletion: completion)
        let router = LocalCommandRouter(
            client: client,
            skillCatalog: "- open_application: launch an app",
            grammar: "root ::= skill")

        let routed = try await router.route(
            transcript: "open safari",
            whisperAvgLogprob: -0.21,
            endpoint: fixtureEndpoint)

        XCTAssertEqual(routed.decision.intent, "open Safari")
        XCTAssertEqual(routed.decision.skillID, "open_application")
        XCTAssertEqual(routed.decision.parameters, .object(["app_name": .string("Safari")]))
        XCTAssertEqual(routed.confidence.idSelectingTokenCount, 1)
        XCTAssertEqual(routed.confidence.logprobSum, -0.08)
        XCTAssertEqual(routed.confidence.logprobMean, -0.08)

        let callCount = await client.routeCompleteCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testRejectsCloudEndpoint() async {
        let client = MockLLMClient()
        let router = LocalCommandRouter(
            client: client, skillCatalog: "", grammar: "root ::= skill")
        let cloud = LLMEndpoint(
            baseURL: URL(string: "https://api.example.com")!,
            model: "cloud-model",
            isLocal: false)

        do {
            _ = try await router.route(
                transcript: "open safari", whisperAvgLogprob: -0.2, endpoint: cloud)
            XCTFail("expected cloud endpoint to be rejected")
        } catch let error as RoutingError {
            XCTAssertEqual(error, .cloudEndpointRejected)
        } catch {
            XCTFail("expected RoutingError.cloudEndpointRejected, got \(error)")
        }
    }
}
