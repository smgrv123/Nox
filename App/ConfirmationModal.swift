import AppKit
import SwiftUI

/// A **separate, ordinary, focus-taking** confirmation window — the infrastructure
/// for later destructive/typed confirmations (docs/04-hld.md §13.3; specs/P1
/// §"ConfirmationModal"). Phase 11 provides the mechanism; the wipe is its first
/// real trigger.
///
/// This is deliberately **the opposite of the Overlay**. The Overlay is a
/// *non-activating* `NSPanel` that must never become key/main, because it reports
/// listening state without stealing keyboard focus from the app the user is typing
/// in. A destructive confirmation is the reverse: it *must* take focus and demand a
/// distinct, unmistakable action before anything irreversible happens. So this is an
/// ordinary titled `NSWindow` that activates the app and becomes key — a genuinely
/// different window from the overlay, not a restyle of it.
///
/// "Distinct, deliberate action" is enforced in the view: the destructive button
/// carries the `.destructive` role and is **not** the default action, so Return
/// never triggers it — only an explicit click does. Escape maps to Cancel (the safe
/// path). Later phases can extend this same window with typed confirmation (e.g.
/// "type WIPE to confirm") without changing callers.
///
/// This is an OS-bound UI shell (per specs/P1 §"Testing Decisions", not unit-tested);
/// the tested logic it guards — the wipe scope — lives in `Persistence.HistoryWipe`.
final class ConfirmationModal {

    /// The text + styling a confirmation presents. Value-only so callers stay
    /// declarative and the window mechanism stays generic.
    struct Content {
        var title: String
        var message: String
        var confirmTitle: String
        var cancelTitle: String
        /// Renders the confirm button with destructive styling (red). Wipe = true.
        var isDestructive: Bool

        init(
            title: String,
            message: String,
            confirmTitle: String,
            cancelTitle: String = "Cancel",
            isDestructive: Bool = true
        ) {
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
            self.cancelTitle = cancelTitle
            self.isDestructive = isDestructive
        }
    }

    /// Retained while presented so the window isn't deallocated out from under the
    /// user. One modal at a time — a new request replaces any prior window.
    private var window: NSWindow?

    /// Present the confirmation. `onConfirm` runs only when the user takes the
    /// deliberate destructive action; any other dismissal simply closes the window.
    /// Must be called on the main thread (all AppKit UI is main-thread-bound).
    func present(_ content: Content, onConfirm: @escaping () -> Void) {
        dismiss()

        let view = ConfirmationModalView(
            content: content,
            onConfirm: { [weak self] in
                self?.dismiss()
                onConfirm()
            },
            onCancel: { [weak self] in self?.dismiss() })

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        // Ordinary titled window (NOT `.nonactivatingPanel`): it can become key/main.
        // No close button — the user must choose one of the two explicit buttons.
        window.styleMask = [.titled]
        window.title = content.title
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        window.center()
        self.window = window

        // Take focus: activate the app and make this the key window, so keyboard
        // focus lands here (unlike the overlay, which must never do this).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Close and release the current window, if any.
    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

/// The confirmation's SwiftUI content. Thin view shell bound to a `Content` and two
/// callbacks; the focus + window behavior lives in `ConfirmationModal`.
private struct ConfirmationModalView: View {
    let content: ConfirmationModal.Content
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(content.title)
                .font(.headline)
            Text(content.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(content.cancelTitle, action: onCancel)
                    .keyboardShortcut(.cancelAction)  // Esc → the safe path.
                Button(
                    content.confirmTitle,
                    role: content.isDestructive ? .destructive : nil,
                    action: onConfirm)
                // Intentionally NOT `.defaultAction`: Return must never fire a
                // destructive action — it requires a deliberate explicit click.
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
