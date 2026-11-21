import Foundation
import ServiceManagement

/// Starts the app when the Mac's user logs in, and starts it again if it crashes. The app has a
/// launch agent inside it (`build.sh` writes it): launchd keeps it running unless it quit normally,
/// so quitting from the menu stays quit and only a crash brings it back. Nothing is registered
/// until the operator switches it on; macOS may then ask them to allow it in Login Items.
enum LaunchAtLogin {
    static let plistName = "com.churchfront.cuevideo.agent.plist"

    enum State: Equatable {
        case on
        case off
        /// Registered, but waiting for the operator to allow it in System Settings > Login Items.
        case needsApproval
        /// Not running from the built app, so there is no agent to register.
        case unavailable
    }

    static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .on
        case .notRegistered: return .off
        case .requiresApproval: return .needsApproval
        default: return .unavailable
        }
    }

    private static var service: SMAppService { .agent(plistName: plistName) }

    static var current: State { state(service.status) }

    static func set(_ on: Bool) throws {
        if on { try service.register() } else { try service.unregister() }
    }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
