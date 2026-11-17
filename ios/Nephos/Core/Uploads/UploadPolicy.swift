import Foundation

enum UploadPolicy: String, Codable, CaseIterable, Sendable {
    case allNetworks, wiFiOnly, disabled

    var title: String {
        switch self {
        case .allNetworks: "All networks"
        case .wiFiOnly: "Wi-Fi only"
        case .disabled: "Disabled"
        }
    }
}
