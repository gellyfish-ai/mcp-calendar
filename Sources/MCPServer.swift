import Foundation

// MARK: - Errors

enum MCPError: Error, CustomStringConvertible {
    case permissionDenied(String)
    case notFound(String)
    case invalidParams(String)

    var description: String {
        switch self {
        case .permissionDenied(let msg): return msg
        case .notFound(let msg): return msg
        case .invalidParams(let msg): return msg
        }
    }
}

// MARK: - JSON-RPC Types

struct JSONRPCRequest {
    let id: Any?
    let method: String
    let params: [String: Any]?

    init?(json: [String: Any]) {
        self.method = json["method"] as? String ?? ""
        self.id = json["id"]
        self.params = json["params"] as? [String: Any]
    }
}

// MARK: - MCP Server

final class MCPServer: @unchecked Sendable {
    private let serverInfo: [String: String] = [
        "name": "mcp-calendar",
        "version": "1.0.0",
    ]

    func handleMessage(_ data: Data) async -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = JSONRPCRequest(json: json) else {
            return jsonRPCError(id: nil, code: -32700, message: "Parse error")
        }

        // Notifications have no id — no response needed
        if request.id == nil {
            return nil
        }

        let result: Any
        do {
            result = try await dispatch(request)
        } catch let error as MCPError {
            return jsonRPCToolError(id: request.id, message: error.description)
        } catch {
            return jsonRPCToolError(id: request.id, message: error.localizedDescription)
        }

        return jsonRPCResult(id: request.id, result: result)
    }

    private func dispatch(_ request: JSONRPCRequest) async throws -> Any {
        switch request.method {
        case "initialize":
            return [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false],
                ],
                "serverInfo": serverInfo,
            ] as [String: Any]

        case "ping":
            return [:] as [String: Any]

        case "tools/list":
            return ["tools": toolDefinitions()]

        case "tools/call":
            guard let params = request.params,
                  let toolName = params["name"] as? String else {
                throw MCPError.invalidParams("Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return try await callTool(name: toolName, arguments: arguments)

        default:
            return jsonRPCErrorDict(code: -32601, message: "Method not found: \(request.method)")
        }
    }

    // MARK: - Tool Definitions

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "list_calendars",
                "description": "List all available calendars",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "list_events",
                "description": "List calendar events within a date range",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "startDate": ["type": "string", "description": "Start date in ISO 8601 format (e.g. 2025-01-01T00:00:00Z)"],
                        "endDate": ["type": "string", "description": "End date in ISO 8601 format (e.g. 2025-01-31T23:59:59Z)"],
                        "calendarId": ["type": "string", "description": "Optional calendar ID to filter by"],
                    ] as [String: Any],
                    "required": ["startDate", "endDate"],
                ] as [String: Any],
            ],
            [
                "name": "create_event",
                "description": "Create a new calendar event",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Event title"],
                        "startDate": ["type": "string", "description": "Start date/time in ISO 8601 format"],
                        "endDate": ["type": "string", "description": "End date/time in ISO 8601 format"],
                        "calendarId": ["type": "string", "description": "Calendar ID (uses default if omitted)"],
                        "isAllDay": ["type": "boolean", "description": "Whether this is an all-day event"],
                        "location": ["type": "string", "description": "Event location"],
                        "notes": ["type": "string", "description": "Event notes"],
                        "alarmMinutes": ["type": "integer", "description": "Alarm before event in minutes"],
                    ] as [String: Any],
                    "required": ["title", "startDate", "endDate"],
                ] as [String: Any],
            ],
            [
                "name": "list_reminder_lists",
                "description": "List all available reminder lists",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "list_reminders",
                "description": "List reminders, optionally filtered by list",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "listId": ["type": "string", "description": "Optional reminder list ID to filter by"],
                        "includeCompleted": ["type": "boolean", "description": "Include completed reminders (default: false)"],
                    ] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "create_reminder",
                "description": "Create a new reminder",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Reminder title"],
                        "listId": ["type": "string", "description": "Reminder list ID (uses default if omitted)"],
                        "dueDate": ["type": "string", "description": "Due date in ISO 8601 format"],
                        "notes": ["type": "string", "description": "Reminder notes"],
                        "priority": ["type": "integer", "description": "Priority (0=none, 1=high, 5=medium, 9=low)"],
                    ] as [String: Any],
                    "required": ["title"],
                ] as [String: Any],
            ],
            [
                "name": "complete_reminder",
                "description": "Mark a reminder as complete",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Reminder ID to mark as complete"],
                    ] as [String: Any],
                    "required": ["id"],
                ] as [String: Any],
            ],
        ]
    }

    // MARK: - Tool Dispatch

    private func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let manager = EventKitManager.shared
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        func parseDate(_ value: Any?, name: String) throws -> Date {
            guard let str = value as? String else {
                throw MCPError.invalidParams("Missing required parameter: \(name)")
            }
            if let date = formatter.date(from: str) { return date }
            if let date = fallbackFormatter.date(from: str) { return date }
            throw MCPError.invalidParams("Invalid date format for \(name): \(str). Use ISO 8601.")
        }

        switch name {
        case "list_calendars":
            let calendars = try await manager.listCalendars()
            return toolResult(calendars)

        case "list_events":
            let start = try parseDate(arguments["startDate"], name: "startDate")
            let end = try parseDate(arguments["endDate"], name: "endDate")
            let calId = arguments["calendarId"] as? String
            let events = try await manager.listEvents(startDate: start, endDate: end, calendarId: calId)
            return toolResult(events)

        case "create_event":
            let title = arguments["title"] as? String ?? ""
            let start = try parseDate(arguments["startDate"], name: "startDate")
            let end = try parseDate(arguments["endDate"], name: "endDate")
            let result = try await manager.createEvent(
                title: title,
                startDate: start,
                endDate: end,
                calendarId: arguments["calendarId"] as? String,
                isAllDay: arguments["isAllDay"] as? Bool ?? false,
                location: arguments["location"] as? String,
                notes: arguments["notes"] as? String,
                alarmMinutes: arguments["alarmMinutes"] as? Int
            )
            return toolResult(result)

        case "list_reminder_lists":
            let lists = try await manager.listReminderLists()
            return toolResult(lists)

        case "list_reminders":
            let reminders = try await manager.listReminders(
                listId: arguments["listId"] as? String,
                includeCompleted: arguments["includeCompleted"] as? Bool ?? false
            )
            return toolResult(reminders)

        case "create_reminder":
            guard let title = arguments["title"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: title")
            }
            var dueDate: Date? = nil
            if let dueDateStr = arguments["dueDate"] as? String {
                dueDate = formatter.date(from: dueDateStr) ?? fallbackFormatter.date(from: dueDateStr)
                if dueDate == nil {
                    throw MCPError.invalidParams("Invalid date format for dueDate")
                }
            }
            let result = try await manager.createReminder(
                title: title,
                listId: arguments["listId"] as? String,
                dueDate: dueDate,
                notes: arguments["notes"] as? String,
                priority: arguments["priority"] as? Int
            )
            return toolResult(result)

        case "complete_reminder":
            guard let id = arguments["id"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: id")
            }
            let result = try await manager.completeReminder(id: id)
            return toolResult(result)

        default:
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
    }

    // MARK: - Response Helpers

    private func toolResult(_ jsonData: Data) -> [String: Any] {
        let text = String(data: jsonData, encoding: .utf8) ?? "{}"
        return [
            "content": [["type": "text", "text": text]],
            "isError": false,
        ]
    }

    private func jsonRPCResult(id: Any?, result: Any) -> Data {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func jsonRPCError(id: Any?, code: Int, message: String) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func jsonRPCToolError(id: Any?, message: String) -> Data {
        let result: [String: Any] = [
            "content": [["type": "text", "text": message]],
            "isError": true,
        ]
        return jsonRPCResult(id: id, result: result)
    }

    private func jsonRPCErrorDict(code: Int, message: String) -> [String: Any] {
        // This is returned as a protocol-level error
        ["__jsonrpc_error__": true, "code": code, "message": message]
    }
}
