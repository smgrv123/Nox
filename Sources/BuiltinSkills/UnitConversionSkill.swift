import CommandDispatcher
import Foundation
import SkillManifest

enum UnitConversionSkill {
    static func run(parameters: JSONValue) throws -> SkillResult {
        let value = try ParameterReader.requiredDouble("value", in: parameters)
        let fromName = try ParameterReader.requiredString("from_unit", in: parameters)
        let toName = try ParameterReader.requiredString("to_unit", in: parameters)
        guard let from = UnitLookup.resolve(fromName), let to = UnitLookup.resolve(toName) else {
            let unknown = UnitLookup.resolve(fromName) == nil ? fromName : toName
            throw SkillExecutionError.unknownUnit(unknown)
        }
        guard let summary = convert(value, from: from, to: to) else {
            return SkillResult(summary: "Can't convert \(fromName) to \(toName).")
        }
        return SkillResult(summary: summary)
    }

    private static func convert(_ value: Double, from: PhysicalQuantity, to: PhysicalQuantity) -> String? {
        switch (from, to) {
        case (.length(let fromUnit), .length(let toUnit)):
            return convert(value, from: fromUnit, to: toUnit)
        case (.mass(let fromUnit), .mass(let toUnit)):
            return convert(value, from: fromUnit, to: toUnit)
        case (.temperature(let fromUnit), .temperature(let toUnit)):
            return convert(value, from: fromUnit, to: toUnit)
        case (.volume(let fromUnit), .volume(let toUnit)):
            return convert(value, from: fromUnit, to: toUnit)
        case (.speed(let fromUnit), .speed(let toUnit)):
            return convert(value, from: fromUnit, to: toUnit)
        case (.area(let fromUnit), .area(let toUnit)):
            return convert(value, from: fromUnit, to: toUnit)
        default:
            return nil
        }
    }

    private static func convert<UnitType: Dimension>(_ value: Double, from: UnitType, to: UnitType) -> String {
        format(Measurement(value: value, unit: from).converted(to: to))
    }

    private static func format<UnitType: Dimension>(_ measurement: Measurement<UnitType>) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        let number = formatter.string(from: NSNumber(value: measurement.value)) ?? String(measurement.value)
        return "\(number) \(measurement.unit.symbol)"
    }
}

enum PhysicalQuantity {
    case length(UnitLength)
    case mass(UnitMass)
    case temperature(UnitTemperature)
    case volume(UnitVolume)
    case speed(UnitSpeed)
    case area(UnitArea)
}

enum UnitLookup {
    static func resolve(_ name: String) -> PhysicalQuantity? {
        table[normalize(name)]
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let table: [String: PhysicalQuantity] = {
        var map: [String: PhysicalQuantity] = [:]
        func alias(_ names: String..., to quantity: PhysicalQuantity) {
            for name in names { map[name] = quantity }
        }
        alias("mile", "miles", "mi", to: .length(.miles))
        alias("kilometer", "kilometers", "km", to: .length(.kilometers))
        alias("meter", "meters", "m", to: .length(.meters))
        alias("foot", "feet", "ft", to: .length(.feet))
        alias("inch", "inches", "in", to: .length(.inches))
        alias("kilogram", "kilograms", "kg", to: .mass(.kilograms))
        alias("pound", "pounds", "lb", "lbs", to: .mass(.pounds))
        alias("gram", "grams", "g", to: .mass(.grams))
        alias("ounce", "ounces", "oz", to: .mass(.ounces))
        alias("celsius", "c", "centigrade", to: .temperature(.celsius))
        alias("fahrenheit", "f", to: .temperature(.fahrenheit))
        alias("kelvin", "k", to: .temperature(.kelvin))
        alias("gallon", "gallons", "gal", to: .volume(.gallons))
        alias("liter", "liters", "l", to: .volume(.liters))
        alias("milliliter", "milliliters", "ml", to: .volume(.milliliters))
        alias("cup", "cups", to: .volume(.cups))
        alias("mph", "miles per hour", to: .speed(.milesPerHour))
        alias("km/h", "kph", "kilometers per hour", to: .speed(.kilometersPerHour))
        alias("m/s", "meters per second", to: .speed(.metersPerSecond))
        alias("square feet", "sq ft", "sqft", "ft2", "ft²", to: .area(.squareFeet))
        alias("square meters", "sq m", "sqm", "m2", "m²", to: .area(.squareMeters))
        alias("square inch", "square inches", "sq in", to: .area(.squareInches))
        return map
    }()
}
