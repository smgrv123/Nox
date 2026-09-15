import Foundation

/// Injected knobs for dictionary promotion, eviction, and (later phases) prompt
/// budgeting. Tests pass a smaller config rather than asserting the production
/// literals; those literals live only on `BudgetConfig.default`.
public struct BudgetConfig: Equatable, Sendable {

    public var hardCap: Int
    public var tokenBudget: Int
    public var substitutionTopN: Int
    public var recencyHalfLifeDays: Double
    public var promoteMin: Int
    public var appNameCap: Int

    public init(
        hardCap: Int,
        tokenBudget: Int,
        substitutionTopN: Int,
        recencyHalfLifeDays: Double,
        promoteMin: Int,
        appNameCap: Int
    ) {
        self.hardCap = hardCap
        self.tokenBudget = tokenBudget
        self.substitutionTopN = substitutionTopN
        self.recencyHalfLifeDays = recencyHalfLifeDays
        self.promoteMin = promoteMin
        self.appNameCap = appNameCap
    }

    public static let `default` = BudgetConfig(
        hardCap: 500,
        tokenBudget: 200,
        substitutionTopN: 40,
        recencyHalfLifeDays: 14,
        promoteMin: 2,
        appNameCap: 50)
}
