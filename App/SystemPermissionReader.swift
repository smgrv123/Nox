import AVFoundation
import ApplicationServices
import CoreGraphics
import EventKit
import IOKit.hid
import Permissions

/// The thin **effectful shell** behind `PermissionGate` (docs/05-lld.md §8): it performs
/// the real TCC status queries and maps them onto the pure `PermissionStatus` enum. It is
/// deliberately tiny and OS-bound — all the logic (hints, deep-links, degradation) lives in
/// the headless-testable `Permissions` module; this file is verified by running the app.
///
/// Every query here is **prompt-free** (User Story 27): it reads `authorizationStatus` /
/// preflight state only and never calls a `requestAccess` API, so opening Settings never
/// triggers a system dialog and always reflects the true current state.
struct SystemPermissionReader {

    /// Prompt-free status for one permission. Suitable to hand to
    /// `PermissionGate(read:)`.
    func liveStatus(for permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .accessibility:
            // AX exposes only a trusted/not-trusted boolean (no "not determined").
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            // The listen-only CGEventTap (Push-to-Talk) requires Input Monitoring
            // (kTCCServiceListenEvent), queried prompt-free via IOHIDCheckAccess.
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notDetermined  // kIOHIDAccessTypeUnknown ⇒ not yet determined
            }
        case .calendar:
            return Self.map(EKEventStore.authorizationStatus(for: .event))
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied  // fail safe: unknown ⇒ feature disabled
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> PermissionStatus {
        // macOS 14+ cases only (`.authorized` is deprecated → `.fullAccess`); the calendar
        // skill reads events, so write-only doesn't count as usable.
        switch status {
        case .fullAccess: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .writeOnly: return .denied
        @unknown default: return .denied
        }
    }
}
