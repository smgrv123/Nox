/// Shared JSON terminals always appended to the generated grammar (LLD §2.2.2 / §4.4).
enum GBNFSharedTerminals {
    static let lines: [String] = [
        #"string ::= "\"" char* "\"""#,
        #"char ::= [^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)"#,
        "hex ::= [0-9a-fA-F]",
        #"integer ::= "-"? ("0" | [1-9] [0-9]*)"#,
        #"number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?"#,
        #"boolean ::= "true" | "false""#,
        #"ws ::= ([ \t\n])*"#,
    ]
}
