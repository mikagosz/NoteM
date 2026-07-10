import Foundation

/// A single filter condition used in a smart folder.
enum SmartFolderCondition: Codable, Hashable {
    case tagContains(String)
    case titleContains(String)
    case modifiedToday
    case modifiedInDays(Int)
    case sourceFolder(String)
    case pinned
}

/// A saved search that surfaces notes matching one or more conditions.
struct SmartFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var icon: String
    var conditions: [SmartFolderCondition]
    /// `true` = ALL conditions must match (AND); `false` = ANY (OR).
    var conjunctive: Bool

    func matches(_ note: Note, now: Date = Date()) -> Bool {
        guard !conditions.isEmpty else { return false }
        let check: (SmartFolderCondition) -> Bool = { condition in
            switch condition {
            case .tagContains(let tag):
                return note.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
            case .titleContains(let text):
                return note.title.localizedCaseInsensitiveContains(text)
            case .modifiedToday:
                return Calendar.current.isDateInToday(note.modified)
            case .modifiedInDays(let days):
                guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return false }
                return note.modified >= cutoff
            case .sourceFolder(let folder):
                return note.folderPath.hasPrefix(folder + "/") || note.folderPath == folder
            case .pinned:
                return note.pinned
            }
        }
        return conjunctive ? conditions.allSatisfy(check) : conditions.contains(where: check)
    }

    // Stable UUIDs so predefined folders survive app restarts.
    static let dzisiejszeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let przypieteID  = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// Localized display name: built-in folders are translated; user folders keep
    /// their given name.
    func displayName(_ s: AppSettings) -> String {
        switch id {
        case Self.dzisiejszeID: return s.t("Dzisiejsze", "Today")
        case Self.przypieteID:  return s.t("Przypięte", "Pinned")
        default:                return name
        }
    }

    static let predefined: [SmartFolder] = [
        SmartFolder(
            id: dzisiejszeID,
            name: "Dzisiejsze",
            icon: "calendar",
            conditions: [.modifiedToday],
            conjunctive: true
        ),
        SmartFolder(
            id: przypieteID,
            name: "Przypięte",
            icon: "pin.fill",
            conditions: [.pinned],
            conjunctive: true
        ),
    ]
}
