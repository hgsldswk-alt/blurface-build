import Foundation

struct Milestones: Codable, Equatable {
    private(set) var savedImages = 0
    private(set) var saveEvents = 0
    private(set) var firstSaveDay: Date?
    private(set) var multipleDays = false
    private(set) var requests: [Date] = []

    var hasCard: Bool { savedImages >= 10 }

    mutating func recordSave(images: Int, at date: Date, calendar: Calendar = .current) {
        guard images > 0 else { return }
        savedImages += images
        saveEvents += 1
        if let firstSaveDay {
            if calendar.startOfDay(for: date) > calendar.startOfDay(for: firstSaveDay) {
                multipleDays = true
            }
        } else {
            firstSaveDay = date
        }
    }

    mutating func registerReviewIfEligible(at date: Date) -> Bool {
        let day: TimeInterval = 86_400
        guard multipleDays, saveEvents >= 3,
              requests.allSatisfy({ date.timeIntervalSince($0) >= 90 * day }) else { return false }
        let thisYear = requests.filter { date.timeIntervalSince($0) < 365 * day }
        guard thisYear.count < 2 else { return false }
        requests = thisYear + [date]
        return true
    }
}
