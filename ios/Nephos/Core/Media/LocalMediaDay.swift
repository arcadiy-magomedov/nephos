import Foundation

struct LocalMediaDay: Identifiable, Equatable {
    let id: Date?
    var items: [LocalMediaItem]

    static func group(_ items: [LocalMediaItem], calendar: Calendar = .current) -> [LocalMediaDay] {
        var days: [LocalMediaDay] = []
        for item in items {
            let day = item.capturedAt.map { calendar.startOfDay(for: $0) }
            if let last = days.indices.last, days[last].id == day {
                days[last].items.append(item)
            } else {
                days.append(LocalMediaDay(id: day, items: [item]))
            }
        }
        return days
    }
}
