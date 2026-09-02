import SkillManifest

/// Deterministic GBNF assembly from enabled manifests (LLD §2.2.2 / §4.4).
///
/// Rule names are `s-` plus the skill `id` with underscores kept (not rewritten as
/// hyphens). Manifest ids already match `^[a-z][a-z0-9_]{2,63}$`, so
/// `s-open_application` is a valid GBNF identifier. The same input set always
/// produces byte-identical output; alternatives are ordered by `id`.
///
/// `general_qa` and `screen_qa` are reserved router targets: they are always
/// present in the skill union (PRD story 4). When a reserved id already has a
/// registered manifest, that manifest's `parameters` rule is used; otherwise
/// the LLD §2.2.2 `"question": string` shape is emitted. `s-null` is always last.
public enum GBNFGrammarAssembler {

    /// Reserved built-in router targets. Always present in the skill union
    /// even when those manifests were not passed in.
    private static let reservedSkillIDs = ["general_qa", "screen_qa"]

    public static func assemble(from manifests: [Manifest]) -> String {
        let byID = Dictionary(manifests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set(manifests.map(\.id))
        ids.formUnion(reservedSkillIDs)
        let orderedIDs = ids.sorted()

        var lines: [String] = [
            #"root ::= "{" ws "\"intent\":" ws string "," ws skill "}" ws"#,
            skillUnion(ids: orderedIDs),
        ]
        for id in orderedIDs {
            if let manifest = byID[id] {
                lines.append(
                    skillRule(
                        id: id, parameters: GBNFParameterCompiler.compileObject(manifest.parameters)))
            } else {
                lines.append(skillRule(id: id, parameters: reservedQuestionParameters))
            }
        }
        lines.append(nullRule)
        lines.append(contentsOf: GBNFSharedTerminals.lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func skillUnion(ids: [String]) -> String {
        let alts = ids.map(ruleName) + ["s-null"]
        return "skill ::= " + alts.joined(separator: " | ")
    }

    private static func skillRule(id: String, parameters: String) -> String {
        let idLiteral = "\"\\\"\(id)\\\"\""
        return
            "\(ruleName(id)) ::= \"\\\"skill_id\\\":\" ws \(idLiteral) \",\" ws \"\\\"parameters\\\":\" ws \(parameters)"
    }

    /// LLD §2.2.2 shape used when a reserved id has no registered manifest.
    private static let reservedQuestionParameters = GBNFParameterCompiler.compileObject(
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("question")]),
            "properties": .object([
                "question": .object(["type": .string("string")])
            ]),
        ])
    )

    private static let nullRule =
        #"s-null ::= "\"skill_id\":" ws "null" "," ws "\"parameters\":" ws "{" ws "}""#

    /// Underscores in the skill id are kept so `open_application` → `s-open_application`.
    static func ruleName(_ id: String) -> String {
        "s-\(id)"
    }
}
