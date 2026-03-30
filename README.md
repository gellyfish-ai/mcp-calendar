# mcp-calendar

MCP server for Apple Calendar and Reminders via EventKit. Exposes calendar and reminder data over the Model Context Protocol (MCP) using SSE transport.

## Requirements

- macOS 14+ (Sonoma or later)
- Swift 6.0+
- Xcode 16+ (or Swift toolchain)

## Setup

### 1. Build

```bash
swift build
```

### 2. Grant Permissions

EventKit requires TCC (Transparency, Consent, and Control) permissions. Run the setup command from Terminal to trigger the permission dialogs:

```bash
swift run mcp-calendar --setup
```

macOS will prompt you to grant Calendar and Reminders access. You can also grant permissions manually in **System Settings > Privacy & Security > Calendar/Reminders**.

**Important:** If you rebuild the binary, macOS may revoke permissions and require re-granting.

### 3. Run

```bash
swift run mcp-calendar
```

The server starts on `http://127.0.0.1:8201` by default.

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `127.0.0.1` | Bind address |
| `PORT` | `8201` | Listen port |

## MCP Transport

Uses legacy HTTP+SSE transport:

- **SSE endpoint:** `GET /sse` - Connect to receive server events
- **Message endpoint:** `POST /message?sessionId=<id>` - Send JSON-RPC messages
- **Health check:** `GET /health`

## Tools

| Tool | Description |
|------|-------------|
| `list_calendars` | List all available calendars |
| `list_events` | List events within a date range |
| `create_event` | Create a calendar event |
| `list_reminder_lists` | List all reminder lists |
| `list_reminders` | List reminders (optionally filtered by list) |
| `create_reminder` | Create a reminder with optional due date |
| `complete_reminder` | Mark a reminder as complete |

## Docker

A Dockerfile and docker-compose.yml are included for reference, but **EventKit requires macOS with TCC permissions**. The Docker build will compile the binary for Linux but it will not have access to Calendar/Reminders data. For production use, run the binary natively on macOS.

## Security

- Binds to `127.0.0.1` by default (localhost only)
- No credentials or tokens in responses
- Designed to run as admin user with gateway connecting via HTTP
- Per MCP-SECURITY.md: Personal Data category MCP

## License

MIT
