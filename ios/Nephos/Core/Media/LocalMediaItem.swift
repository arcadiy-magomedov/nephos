import Foundation

struct LocalMediaItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case photo, video
    }

    let id: String
    let kind: Kind
    let capturedAt: Date?
    let modifiedAt: Date?
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
    var isLivePhoto = false

    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    static func playbackTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(min(seconds, Double(Int.max / 2)))
        let pattern: Duration.TimeFormatStyle.Pattern = value >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(value).formatted(.time(pattern: pattern))
    }
}
