import Foundation
import Hummingbird
import EventKit

@main
struct MCPCalendarApp {
    static func main() async throws {
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8201") ?? 8201
        let host = ProcessInfo.processInfo.environment["HOST"] ?? "127.0.0.1"

        // Handle --setup flag for TCC permission requests
        if CommandLine.arguments.contains("--setup") {
            print("Requesting Calendar and Reminders permissions...")
            let manager = EventKitManager.shared
            let calAccess = await manager.requestCalendarAccess()
            let remAccess = await manager.requestReminderAccess()
            print("Calendar access: \(calAccess ? "granted" : "denied")")
            print("Reminders access: \(remAccess ? "granted" : "denied")")
            if calAccess && remAccess {
                print("All permissions granted. You can now run the server.")
            } else {
                print("Some permissions denied. Grant them in System Settings > Privacy & Security.")
            }
            return
        }

        let mcpServer = MCPServer()
        let transport = SSETransport(mcpServer: mcpServer)

        let router = Router()
        transport.registerRoutes(router: router)

        // Health check
        router.get("/health") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: .init(string: "ok")))
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )

        print("MCP Calendar server starting on \(host):\(port)")
        print("SSE endpoint: http://\(host):\(port)/sse")
        print("Message endpoint: http://\(host):\(port)/message")
        print("Run with --setup to request Calendar/Reminders permissions")

        try await app.runService()
    }
}
