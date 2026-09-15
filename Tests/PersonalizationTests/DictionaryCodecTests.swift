import XCTest

@testable import Personalization

final class DictionaryCodecTests: XCTestCase {

    func testLLDFixtureRoundTrip() throws {
        let decoded = try DictionaryCodec.decode(Data(Self.lldFixture.utf8))

        XCTAssertEqual(decoded.schemaVersion, DictionaryDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.hardCap, BudgetConfig.default.hardCap)
        XCTAssertEqual(decoded.entries.count, 2)

        let kubernetes = try XCTUnwrap(decoded.entries.first { $0.correctTerm == "Kubernetes" })
        XCTAssertEqual(kubernetes.id, "e_01H...")
        XCTAssertEqual(kubernetes.mishearings, ["cooper nettie's", "kubernetis", "coober netties"])
        XCTAssertEqual(kubernetes.occurrenceCount, 4)
        XCTAssertTrue(kubernetes.promoted)
        XCTAssertEqual(kubernetes.source, .auto)
        XCTAssertEqual(kubernetes.createdAt, Self.isoDate("2026-07-10T14:00:00Z"))
        XCTAssertEqual(kubernetes.lastUsedAt, Self.isoDate("2026-07-20T09:12:00Z"))

        let sumrit = try XCTUnwrap(decoded.entries.first { $0.correctTerm == "Sumrit" })
        XCTAssertEqual(sumrit.id, "e_01J...")
        XCTAssertEqual(sumrit.mishearings, ["sam rit", "some writ"])
        XCTAssertEqual(sumrit.occurrenceCount, 9)
        XCTAssertTrue(sumrit.promoted)
        XCTAssertEqual(sumrit.source, .explicit)

        let encoded = try DictionaryCodec.encode(decoded)
        let roundTripped = try DictionaryCodec.decode(encoded)
        XCTAssertEqual(roundTripped, decoded)

        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schema_version\""))
        XCTAssertTrue(text.contains("\"hard_cap\""))
        XCTAssertTrue(text.contains("\"correct_term\""))
        XCTAssertTrue(text.contains("\"occurrence_count\""))
        XCTAssertTrue(text.contains("\"last_used_at\""))
    }

    func testUnknownSourceIsSkippedOnLoad() throws {
        let json = """
            {
              "schema_version": 1,
              "hard_cap": \(BudgetConfig.default.hardCap),
              "entries": [
                {
                  "id": "e_bad",
                  "correct_term": "Nope",
                  "mishearings": [],
                  "occurrence_count": 1,
                  "promoted": true,
                  "source": "imported",
                  "created_at": "2026-07-10T14:00:00Z",
                  "last_used_at": "2026-07-10T14:00:00Z"
                },
                {
                  "id": "e_ok",
                  "correct_term": "Aide",
                  "mishearings": ["aid"],
                  "occurrence_count": 1,
                  "promoted": true,
                  "source": "explicit",
                  "created_at": "2026-07-10T14:00:00Z",
                  "last_used_at": "2026-07-10T14:00:00Z"
                }
              ]
            }
            """
        let decoded = try DictionaryCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.entries.map(\.id), ["e_ok"])
    }

    func testMissingOrNullLastUsedAtDecodesAsDistantPast() throws {
        let json = """
            {
              "schema_version": 1,
              "hard_cap": \(BudgetConfig.default.hardCap),
              "entries": [
                {
                  "id": "e_missing",
                  "correct_term": "Missing",
                  "mishearings": [],
                  "occurrence_count": 1,
                  "promoted": true,
                  "source": "explicit",
                  "created_at": "2026-07-10T14:00:00Z"
                },
                {
                  "id": "e_null",
                  "correct_term": "Null",
                  "mishearings": [],
                  "occurrence_count": 1,
                  "promoted": true,
                  "source": "explicit",
                  "created_at": "2026-07-10T14:00:00Z",
                  "last_used_at": null
                }
              ]
            }
            """
        let decoded = try DictionaryCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.entries.map(\.id), ["e_missing", "e_null"])
        XCTAssertEqual(decoded.entries.map(\.lastUsedAt), [Date.distantPast, Date.distantPast])

        let encoded = try DictionaryCodec.encode(decoded)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"last_used_at\""))
    }

    private static func isoDate(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string) ?? Date.distantPast
    }

    /// LLD §2.3 fixture (timestamps already second-precision).
    private static let lldFixture = """
        {
          "schema_version": 1,
          "hard_cap": 500,
          "entries": [
            {
              "id": "e_01H...",
              "correct_term": "Kubernetes",
              "mishearings": ["cooper nettie's", "kubernetis", "coober netties"],
              "occurrence_count": 4,
              "promoted": true,
              "source": "auto",
              "created_at": "2026-07-10T14:00:00Z",
              "last_used_at": "2026-07-20T09:12:00Z"
            },
            {
              "id": "e_01J...",
              "correct_term": "Sumrit",
              "mishearings": ["sam rit", "some writ"],
              "occurrence_count": 9,
              "promoted": true,
              "source": "explicit",
              "created_at": "2026-07-01T00:00:00Z",
              "last_used_at": "2026-07-21T08:00:00Z"
            }
          ]
        }
        """
}
