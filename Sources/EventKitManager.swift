import EventKit
import Foundation

/// Thread-safe EventKit access via Swift actor.
/// Returns serialized JSON Data from all methods to avoid Sendable issues at actor boundaries.
actor EventKitManager {
    static let shared = EventKitManager()

    private let store = EKEventStore()
    private var hasCalendarAccess = false
    private var hasReminderAccess = false
    private var needsRefresh = false

    private init() {}

    // MARK: - Permissions

    func requestCalendarAccess() async -> Bool {
        if hasCalendarAccess { return true }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        hasCalendarAccess = granted
        return granted
    }

    func requestReminderAccess() async -> Bool {
        if hasReminderAccess { return true }
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        hasReminderAccess = granted
        return granted
    }

    // MARK: - Refresh

    private func refreshIfNeeded() {
        if needsRefresh {
            store.refreshSourcesIfNecessary()
            needsRefresh = false
        }
    }

    private func markNeedsRefresh() {
        needsRefresh = true
    }

    private func serialize(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Calendars

    func listCalendars() async throws -> Data {
        guard await requestCalendarAccess() else {
            throw MCPError.permissionDenied("Calendar access not granted")
        }
        refreshIfNeeded()

        let eventCalendars = store.calendars(for: .event)
        let result = eventCalendars.map { cal in
            [
                "id": cal.calendarIdentifier,
                "title": cal.title,
                "source": cal.source?.title ?? "Unknown",
                "type": cal.type.description,
                "allowsModification": cal.allowsContentModifications,
            ] as [String: Any]
        }
        return try serialize(result)
    }

    // MARK: - Events

    func listEvents(startDate: Date, endDate: Date, calendarId: String?) async throws -> Data {
        guard await requestCalendarAccess() else {
            throw MCPError.permissionDenied("Calendar access not granted")
        }
        refreshIfNeeded()

        var calendars: [EKCalendar]? = nil
        if let calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw MCPError.notFound("Calendar not found: \(calendarId)")
            }
            calendars = [cal]
        }

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = store.events(matching: predicate)
        let isoFormatter = ISO8601DateFormatter()

        let result = events.map { event in
            var dict: [String: Any] = [
                "id": event.eventIdentifier ?? "",
                "title": event.title ?? "",
                "startDate": isoFormatter.string(from: event.startDate),
                "endDate": isoFormatter.string(from: event.endDate),
                "isAllDay": event.isAllDay,
                "calendar": event.calendar?.title ?? "",
            ]
            if let location = event.location, !location.isEmpty {
                dict["location"] = location
            }
            if let notes = event.notes, !notes.isEmpty {
                dict["notes"] = notes
            }
            if let url = event.url {
                dict["url"] = url.absoluteString
            }
            if event.hasRecurrenceRules {
                dict["isRecurring"] = true
            }
            return dict
        }
        return try serialize(result)
    }

    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarId: String?,
        isAllDay: Bool,
        location: String?,
        notes: String?,
        alarmMinutes: Int?
    ) async throws -> Data {
        guard await requestCalendarAccess() else {
            throw MCPError.permissionDenied("Calendar access not granted")
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay

        if let calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw MCPError.notFound("Calendar not found: \(calendarId)")
            }
            event.calendar = cal
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }

        if let location { event.location = location }
        if let notes { event.notes = notes }
        if let alarmMinutes {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alarmMinutes * 60)))
        }

        try store.save(event, span: .thisEvent)
        markNeedsRefresh()

        let isoFormatter = ISO8601DateFormatter()
        let result: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "startDate": isoFormatter.string(from: event.startDate),
            "endDate": isoFormatter.string(from: event.endDate),
            "calendar": event.calendar?.title ?? "",
            "created": true,
        ]
        return try serialize(result)
    }

    // MARK: - Reminder Lists

    func listReminderLists() async throws -> Data {
        guard await requestReminderAccess() else {
            throw MCPError.permissionDenied("Reminders access not granted")
        }
        refreshIfNeeded()

        let lists = store.calendars(for: .reminder)
        let result = lists.map { list in
            [
                "id": list.calendarIdentifier,
                "title": list.title,
                "source": list.source?.title ?? "Unknown",
                "allowsModification": list.allowsContentModifications,
            ] as [String: Any]
        }
        return try serialize(result)
    }

    // MARK: - Reminders

    func listReminders(listId: String?, includeCompleted: Bool) async throws -> Data {
        guard await requestReminderAccess() else {
            throw MCPError.permissionDenied("Reminders access not granted")
        }
        refreshIfNeeded()

        var calendars: [EKCalendar]? = nil
        if let listId {
            guard let cal = store.calendar(withIdentifier: listId) else {
                throw MCPError.notFound("Reminder list not found: \(listId)")
            }
            calendars = [cal]
        }

        let predicate: NSPredicate
        if includeCompleted {
            predicate = store.predicateForReminders(in: calendars)
        } else {
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars
            )
        }

        // Serialize inside the callback to avoid sending non-Sendable types
        // across isolation boundaries. Data is Sendable.
        let isoFormatter = ISO8601DateFormatter()
        let jsonData: Data = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let dicts: [[String: Any]] = (reminders ?? []).map { reminder in
                    var dict: [String: Any] = [
                        "id": reminder.calendarItemIdentifier,
                        "title": reminder.title ?? "",
                        "isCompleted": reminder.isCompleted,
                        "list": reminder.calendar?.title ?? "",
                        "priority": reminder.priority,
                    ]
                    if let dueDate = reminder.dueDateComponents,
                       let date = Calendar.current.date(from: dueDate) {
                        dict["dueDate"] = isoFormatter.string(from: date)
                    }
                    if let completionDate = reminder.completionDate {
                        dict["completionDate"] = isoFormatter.string(from: completionDate)
                    }
                    if let notes = reminder.notes, !notes.isEmpty {
                        dict["notes"] = notes
                    }
                    return dict
                }
                let data = (try? JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
                continuation.resume(returning: data)
            }
        }
        return jsonData
    }

    func createReminder(
        title: String,
        listId: String?,
        dueDate: Date?,
        notes: String?,
        priority: Int?
    ) async throws -> Data {
        guard await requestReminderAccess() else {
            throw MCPError.permissionDenied("Reminders access not granted")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title

        if let listId {
            guard let cal = store.calendar(withIdentifier: listId) else {
                throw MCPError.notFound("Reminder list not found: \(listId)")
            }
            reminder.calendar = cal
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate
            )
        }
        if let notes { reminder.notes = notes }
        if let priority { reminder.priority = priority }

        try store.save(reminder, commit: true)
        markNeedsRefresh()

        let isoFormatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list": reminder.calendar?.title ?? "",
            "created": true,
        ]
        if let dueDate {
            dict["dueDate"] = isoFormatter.string(from: dueDate)
        }
        return try serialize(dict)
    }

    func completeReminder(id: String) async throws -> Data {
        guard await requestReminderAccess() else {
            throw MCPError.permissionDenied("Reminders access not granted")
        }

        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw MCPError.notFound("Reminder not found: \(id)")
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()
        try store.save(reminder, commit: true)
        markNeedsRefresh()

        let isoFormatter = ISO8601DateFormatter()
        let result: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "isCompleted": true,
            "completionDate": isoFormatter.string(from: Date()),
        ]
        return try serialize(result)
    }
}

// MARK: - EKCalendarType description

extension EKCalendarType: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .local: return "local"
        case .calDAV: return "calDAV"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }
}
