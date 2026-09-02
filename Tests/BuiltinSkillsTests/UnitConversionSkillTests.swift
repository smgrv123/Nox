import SkillManifest
import XCTest

@testable import BuiltinSkills

final class UnitConversionSkillTests: XCTestCase {

    func testConvertsTenMilesToKilometers() async throws {
        let summary = try await convert(value: 10, from: "miles", to: "kilometers")
        XCTAssertEqual(summary, "16.09 km")
    }

    func testConvertsFiveKilogramsToPounds() async throws {
        let summary = try await convert(value: 5, from: "kilograms", to: "pounds")
        XCTAssertEqual(summary, "11.02 lb")
    }

    func testConvertsTemperaturesBetweenCelsiusFahrenheitAndKelvin() async throws {
        let cToF = try await convert(value: 0, from: "celsius", to: "fahrenheit")
        XCTAssertEqual(cToF, "32 °F")
        let fToC = try await convert(value: 32, from: "fahrenheit", to: "celsius")
        XCTAssertEqual(fToC, "0 °C")
        let cToK = try await convert(value: 0, from: "celsius", to: "kelvin")
        XCTAssertEqual(cToK, "273.15 K")
        let kToC = try await convert(value: 273.15, from: "kelvin", to: "celsius")
        XCTAssertEqual(kToC, "0 °C")
        let fToK = try await convert(value: 32, from: "fahrenheit", to: "kelvin")
        XCTAssertEqual(fToK, "273.15 K")
        let kToF = try await convert(value: 273.15, from: "kelvin", to: "fahrenheit")
        XCTAssertEqual(kToF, "32 °F")
    }

    func testUnknownUnitReturnsGracefulError() async throws {
        do {
            _ = try await makeRouter().execute(
                skillID: "unit_conversion",
                parameters: objectParams([
                    "value": .double(10),
                    "from_unit": .string("furlongs"),
                    "to_unit": .string("kilometers"),
                ])
            )
            XCTFail("expected SkillExecutionError.unknownUnit for furlongs")
        } catch SkillExecutionError.unknownUnit(let name) {
            XCTAssertEqual(name, "furlongs")
        }
    }

    func testSameUnitReturnsTheInputValue() async throws {
        let summary = try await convert(value: 10, from: "miles", to: "miles")
        XCTAssertTrue(summary.hasPrefix("10 "), "expected the input value 10, got \(summary)")
        XCTAssertTrue(summary.contains("mi"), "expected miles symbol, got \(summary)")
    }

    func testConvertsVolumeSpeedAndArea() async throws {
        let liters = try await convert(value: 1, from: "gallons", to: "liters")
        XCTAssertTrue(liters.contains("3.79"), "1 US gallon ≈ 3.79 L, got \(liters)")
        let kmh = try await convert(value: 60, from: "mph", to: "km/h")
        XCTAssertTrue(kmh.contains("96.56"), "60 mph ≈ 96.56 km/h, got \(kmh)")
        let sqm = try await convert(value: 1, from: "square feet", to: "square meters")
        XCTAssertTrue(sqm.contains("0.09"), "1 sq ft ≈ 0.09 m², got \(sqm)")
    }

    func testConvertsIntegerJSONValueToKilometers() async throws {
        let result = try await makeRouter().execute(
            skillID: "unit_conversion",
            parameters: objectParams([
                "value": .int(10),
                "from_unit": .string("miles"),
                "to_unit": .string("kilometers"),
            ])
        )
        XCTAssertEqual(result.summary, "16.09 km")
    }

    private func convert(value: Double, from: String, to: String) async throws -> String {
        let result = try await makeRouter().execute(
            skillID: "unit_conversion",
            parameters: objectParams([
                "value": .double(value),
                "from_unit": .string(from),
                "to_unit": .string(to),
            ])
        )
        return result.summary
    }
}
