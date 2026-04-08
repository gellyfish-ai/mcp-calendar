# mcp-calendar

MCP server for Apple Calendar and Reminders via EventKit. Swift 6, macOS 14+.

## Architecture

```
Sources/
├── App.swift              # Entry point — Hummingbird HTTP server, routes, --setup flag
├── MCPServer.swift        # MCP protocol — tool definitions, JSON-RPC dispatch
├── EventKitManager.swift  # EventKit actor — all Calendar/Reminders read+write logic
├── SSETransport.swift     # SSE session management (legacy HTTP+SSE transport)
└── Resources/Info.plist   # Bundle info for TCC entitlements
```

- **MCPServer.swift** has two key sections: `toolDefinitions()` (schema) and `callTool()` (dispatch). Every tool appears in both.
- **EventKitManager** is a Swift actor. All methods return `Data` (serialized JSON) to stay Sendable-safe across actor boundaries.
- Transport is HTTP+SSE on port 8201 (configurable via `PORT` env var). SSE at `GET /sse`, messages at `POST /message?sessionId=<id>`.

## Adding a new tool

1. Add the tool definition dict to `toolDefinitions()` in `MCPServer.swift`
2. Add the implementation method to `EventKitManager.swift` (follow existing patterns — request access, return serialized JSON)
3. Add a dispatch `case` in `callTool()` in `MCPServer.swift`
4. Update the tools table in `README.md`

## Development workflow

```bash
# Build release (agents use the release binary)
swift build -c release

# Sign the binary (required for persistent TCC permissions)
# Find your identity: security find-identity -v -p codesigning
codesign --force --sign "<your signing identity>" \
  --identifier "com.gellyfish.mcp-calendar" \
  .build/release/mcp-calendar

# Restart via launchd
launchctl unload ~/Library/LaunchAgents/com.gellyfish.mcp-calendar.plist
launchctl load ~/Library/LaunchAgents/com.gellyfish.mcp-calendar.plist

# Verify it's up
curl -s http://127.0.0.1:8201/health
```

**Code signing matters.** Without it, macOS identifies the binary by hash — every rebuild revokes TCC permissions. With a consistent code signature, TCC grants persist across rebuilds. Always sign after building.

**Critical: MCP clients cache the tool list at connection time.** After restarting the server, any connected MCP client (Claude Code session, agent) must reconnect to discover new/changed tools. This typically means restarting the client session.

**Two-process gotcha:** If both a debug and release binary are running, they'll conflict on the port. Always check `pgrep -fl mcp-calendar` and kill stale processes before starting.

## TCC permissions

EventKit requires macOS TCC (Transparency, Consent, and Control) permissions. After a rebuild, macOS may revoke them.

```bash
# Trigger permission dialogs
.build/release/mcp-calendar --setup

# If dialogs don't appear, grant manually:
# System Settings → Privacy & Security → Calendar → toggle ON
# System Settings → Privacy & Security → Reminders → toggle ON

# Verify TCC status
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access WHERE service = 'kTCCServiceCalendar'"
# auth_value: 0=denied, 2=granted
```

TCC grants permissions per-binary path. Running from iTerm grants to iTerm, not to `mcp-calendar`. Always verify via System Settings.

## Conventions

- Date parameters: ISO 8601 format (`2025-01-01T00:00:00Z`)
- Reminder priorities: 0=none, 1=high, 5=medium, 9=low (matches `EKReminder.priority`)
- Binds to `127.0.0.1` by default — localhost only, no auth
- Errors use `MCPError` enum: `.permissionDenied`, `.notFound`, `.invalidParams`
