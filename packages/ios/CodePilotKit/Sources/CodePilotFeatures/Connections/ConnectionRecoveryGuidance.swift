import Foundation
import CodePilotCore

public struct ConnectionRecoveryGuidance: Equatable, Sendable {
    public let title: String
    public let message: String
    public let actionLabel: String

    public init(title: String, message: String, actionLabel: String) {
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
    }
}

public enum ConnectionRecoveryAdvisor {
    public static func guidance(
        for config: ConnectionConfig,
        failureSummary: String?
    ) -> ConnectionRecoveryGuidance {
        let summary = failureSummary?.lowercased() ?? ""
        let pairingMismatch = summary.contains("invalid_otp")
            || summary.contains("auth_failed")
            || summary.contains("handshake")
        let transportReachability = summary.contains("transport_open_failed")
            || summary.contains("upgrade failed")
            || summary.contains("timed out")
            || summary.contains("cannot find host")
            || summary.contains("disconnected")

        switch config {
        case .lan:
            if pairingMismatch {
                return .init(
                    title: "Refresh saved pairing",
                    message: "This bridge answered, but the saved bridge key or OTP no longer matches. Scan the latest QR code or paste a fresh LAN payload to update this project.",
                    actionLabel: "Update Pairing"
                )
            }

            if transportReachability || summary.isEmpty {
                return .init(
                    title: "Check the bridge address",
                    message: "The saved LAN host may no longer point at the running bridge. If the bridge restarted on a new IP or hostname, scan a fresh QR code or paste an updated payload.",
                    actionLabel: "Update Pairing"
                )
            }

            return .init(
                title: "Refresh this LAN connection",
                message: "Reconnect first. If it keeps failing, refresh the saved LAN pairing from the latest QR code or payload.",
                actionLabel: "Update Pairing"
            )

        case .relay:
            if pairingMismatch {
                return .init(
                    title: "Refresh relay pairing",
                    message: "The relay channel is reachable, but the saved bridge key or OTP no longer matches. Scan a fresh QR code or paste an updated relay payload.",
                    actionLabel: "Update Pairing"
                )
            }

            if transportReachability || summary.isEmpty {
                return .init(
                    title: "Check relay endpoint",
                    message: "Verify the relay URL and channel still match the running bridge. If anything changed, refresh this project from the latest relay pairing payload.",
                    actionLabel: "Update Pairing"
                )
            }

            return .init(
                title: "Refresh this relay connection",
                message: "Reconnect first. If the relay project still fails, update it from a fresh relay QR code or payload.",
                actionLabel: "Update Pairing"
            )
        }
    }
}
