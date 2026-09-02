/// A node in the recursive command tree (LLD §4.3 Phase B).
///
/// Each node represents a single simple command with its arguments. Children
/// capture commands discovered inside this node — via substitutions (`$(...)`,
/// backticks), wrapper commands (`sh -c`, `eval`, `xargs`, …), or both.
public struct CommandNode: Equatable, Sendable {
    /// `argv[0]` is the program name; the remainder are arguments.
    public let argv: [String]
    /// Nesting trail from root, e.g. `["pipe", "sh -c"]`.
    public let path: [String]
    /// Commands discovered inside this node.
    public let children: [CommandNode]

    public init(argv: [String], path: [String] = [], children: [CommandNode] = []) {
        self.argv = argv
        self.path = path
        self.children = children
    }

    /// Every node in this subtree, depth-first (self, then children recursively).
    public var flattened: [CommandNode] {
        [self] + children.flatMap(\.flattened)
    }
}
