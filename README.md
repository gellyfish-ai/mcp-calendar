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

This triggers the initial TCC request. **The prompt may not appear** — especially if running via SSH or a background process.

**The reliable way to grant permissions:**
1. Run `--setup` once (may or may not show a prompt)
2. Go to **System Settings → Privacy & Security → Calendar** → find `mcp-calendar` → toggle ON
3. Go to **System Settings → Privacy & Security → Reminders** → find `mcp-calendar` → toggle ON

**CRITICAL:** Do NOT rely on running from iTerm or SSH to grant permissions. TCC grants permissions per-binary — running from iTerm grants to iTerm, not to mcp-calendar. Always verify and toggle in System Settings.

**If you rebuild** the binary, macOS may revoke permissions — re-grant in System Settings.

Verify TCC status:
```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access WHERE service = 'kTCCServiceCalendar'"
# auth_value: 0 = denied, 2 = granted
```

### 3. Run

```bash
swift run mcp-calendar
```

The server starts on `http://127.0.0.1:8201` by default.

### 4. Install as launchd daemon (recommended)

Run as a persistent macOS daemon that starts on boot and restarts on crash:

```bash
cat > ~/Library/LaunchAgents/com.gellyfish.mcp-calendar.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gellyfish.mcp-calendar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/gellyfish/Workspace/mcp-calendar/.build/release/mcp-calendar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/gellyfish/Library/Logs/mcp-calendar.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/gellyfish/Library/Logs/mcp-calendar.log</string>
</dict>
</plist>
PLIST

# Load the daemon
launchctl load ~/Library/LaunchAgents/com.gellyfish.mcp-calendar.plist

# Verify it's running
curl -s http://localhost:8201/health
```

Manage the daemon:
```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.gellyfish.mcp-calendar.plist

# Restart (unload + load)
launchctl unload ~/Library/LaunchAgents/com.gellyfish.mcp-calendar.plist
launchctl load ~/Library/LaunchAgents/com.gellyfish.mcp-calendar.plist

# Check logs
tail -f ~/Library/Logs/mcp-calendar.log
```

### 5. Register in Gellyfish gateway

```sql
INSERT INTO mcp_servers (id, name, type, command, args, env)
VALUES ('<uuid>', 'calendar', 'available', 'npx',
  '["-y", "mcp-remote", "http://localhost:8201/sse", "--allow-http"]', '{}');
```

Then assign to profiles that need it via `profile_mcps`.

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
