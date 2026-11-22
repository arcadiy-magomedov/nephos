import Foundation

enum LocalMediaError: LocalizedError {
    case unavailable, deletionUnsupported, exportUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This item is no longer available. It may have been removed or Photos access may have changed."
        case .deletionUnsupported:
            "Photos does not allow this item to be deleted by Nephos."
        case .exportUnavailable:
            "Photos could not provide this media for sharing. Check your connection if the original is in iCloud."
        }
    }
}
