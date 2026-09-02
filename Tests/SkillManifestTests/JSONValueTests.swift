import Foundation
import XCTest

@testable import SkillManifest

final class JSONValueTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    private let decoder = JSONDecoder()

    // MARK: - Primitive round-trips

    func testStringRoundTrip() throws {
        let value = JSONValue.string("hello")
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.stringValue, "hello")
    }

    func testIntRoundTrip() throws {
        let value = JSONValue.int(42)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.intValue, 42)
    }

    func testDoubleRoundTrip() throws {
        let value = JSONValue.double(3.14)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.doubleValue, 3.14)
    }

    func testBoolTrueRoundTrip() throws {
        let value = JSONValue.bool(true)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.boolValue, true)
    }

    func testBoolFalseRoundTrip() throws {
        let value = JSONValue.bool(false)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.boolValue, false)
    }

    func testNullRoundTrip() throws {
        let value = JSONValue.null
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertTrue(decoded.isNull)
    }

    // MARK: - Composite round-trips

    func testArrayRoundTrip() throws {
        let value = JSONValue.array([.string("a"), .int(1), .bool(true), .null])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.arrayValue?.count, 4)
    }

    func testObjectRoundTrip() throws {
        let value = JSONValue.object([
            "name": .string("test"),
            "count": .int(5),
        ])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.objectValue?["name"], .string("test"))
    }

    func testNestedObjectAndArrayRoundTrip() throws {
        let value = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "minLength": .int(1),
                ])
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // MARK: - Subscript access

    func testSubscriptReturnsValueForObjectKey() {
        let value = JSONValue.object(["key": .string("val")])
        XCTAssertEqual(value["key"], .string("val"))
    }

    func testSubscriptReturnsNilForMissingKey() {
        let value = JSONValue.object(["key": .string("val")])
        XCTAssertNil(value["missing"])
    }

    func testSubscriptReturnsNilForNonObject() {
        let value = JSONValue.string("hello")
        XCTAssertNil(value["anything"])
    }

    // MARK: - Accessor returns nil for wrong type

    func testStringValueReturnsNilForInt() {
        XCTAssertNil(JSONValue.int(42).stringValue)
    }

    func testIntValueReturnsNilForString() {
        XCTAssertNil(JSONValue.string("hello").intValue)
    }

    func testDoubleValueReturnsNilForString() {
        XCTAssertNil(JSONValue.string("hello").doubleValue)
    }

    func testBoolValueReturnsNilForString() {
        XCTAssertNil(JSONValue.string("hello").boolValue)
    }

    func testArrayValueReturnsNilForString() {
        XCTAssertNil(JSONValue.string("hello").arrayValue)
    }

    func testObjectValueReturnsNilForString() {
        XCTAssertNil(JSONValue.string("hello").objectValue)
    }

    // MARK: - Decode from raw JSON

    func testDecodeFromRawJSON() throws {
        let json = """
            {"flag":true,"items":[1,2.5,"three"],"nested":{"x":null}}
            """
        let data = Data(json.utf8)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded["flag"], .bool(true))
        XCTAssertEqual(decoded["nested"]?["x"], .null)
        XCTAssertEqual(decoded["items"]?.arrayValue?.count, 3)
    }

    // MARK: - Integer vs double disambiguation

    func testWholeNumberDecodesAsInt() throws {
        let json = Data("[42]".utf8)
        let decoded = try decoder.decode(JSONValue.self, from: json)
        XCTAssertEqual(decoded.arrayValue?.first, .int(42))
    }

    func testFractionalNumberDecodesAsDouble() throws {
        let json = Data("[3.14]".utf8)
        let decoded = try decoder.decode(JSONValue.self, from: json)
        XCTAssertEqual(decoded.arrayValue?.first, .double(3.14))
    }

    // MARK: - Sendable, Hashable

    func testJSONValueIsHashable() {
        var set = Set<JSONValue>()
        set.insert(.string("a"))
        set.insert(.int(1))
        set.insert(.null)
        XCTAssertEqual(set.count, 3)
    }
}
