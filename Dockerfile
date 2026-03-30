# NOTE: EventKit requires macOS with TCC permissions.
# This Dockerfile builds the Swift binary but it will NOT have access to
# Calendar/Reminders data when run in a Linux container.
# For production use, run the binary natively on macOS.

FROM swift:6.0 AS builder

WORKDIR /app
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources/ Sources/
RUN swift build -c release

FROM swift:6.0-slim
WORKDIR /app
COPY --from=builder /app/.build/release/mcp-calendar .

EXPOSE 8201
ENV HOST=0.0.0.0
ENV PORT=8201

ENTRYPOINT ["./mcp-calendar"]
