/// Result of dispatching a ``RoutedIntent`` (docs/05-lld.md §3.1).
public enum DispatchOutcome: Equatable, Sendable {
    /// Gate and scanner allowed the skill; the executor returned this result.
    case executed(SkillResult)
    /// Gate Confirm-Back and/or scanner Confirm — do not run until the user approves.
    case confirmBack(prompt: ConfirmBackPrompt)
    /// Scanner Hard-Block: no override path in v1.
    case hardBlocked(reason: String)
    /// Unresolved skill, schema hard-reject, or routing confidence below the floor.
    case promptedBack(suggestion: String?)
    /// Skill lookup or execution failed.
    case failed(error: String)
}
