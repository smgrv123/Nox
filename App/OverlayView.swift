import Overlay
import SwiftUI

/// The SwiftUI content the Overlay panel hosts — one visual per `OverlayState`
/// (docs/04-hld.md §13.1; User Stories 5, 6, 10). A thin, declarative view: it reads
/// `controller.state` and renders; all state logic lives in `OverlayStateMachine`.
///
/// Phase 4 renders each state's *visual* with placeholder copy — the real transcript,
/// result, and prompt text are supplied by the Phase-6 voice driver. The card is
/// theme-aware (`.regularMaterial` + semantic colors) so it reads in light and dark.
struct OverlayView: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        content
            .frame(width: 320, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .padding(10)
            .animation(.easeInOut(duration: 0.15), value: controller.state)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .hidden:
            Color.clear.frame(height: 0)
        case .listening:
            row(
                icon: "mic.fill", tint: .red, title: "Listening…",
                detail: "Hold to talk — release to send.")
        case .processing:
            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26)
                labels(title: "Processing…", detail: "Transcribing and routing.")
            }
        case .showingResult:
            row(
                icon: "checkmark.circle.fill", tint: .green, title: "Done",
                detail: "Here's what Aide did.")
        case .promptBack:
            row(
                icon: "questionmark.circle.fill", tint: .blue, title: "Did you mean…?",
                detail: "Aide isn't sure — pick or rephrase.")
        case .confirmBack:
            row(
                icon: "exclamationmark.triangle.fill", tint: .orange, title: "Confirm?",
                detail: "Approve this action before Aide runs it.")
        }
    }

    /// An icon + title + detail row — the shared layout for the non-spinner states.
    private func row(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 26)
            labels(title: title, detail: detail)
        }
    }

    private func labels(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
