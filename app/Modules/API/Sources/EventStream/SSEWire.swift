//
//  SSEWire.swift
//  Replicould — API (event stream)
//
//  The SSE wire protocol, split from the connection loop so it's unit-testable
//  without a socket: `SSELineFramer` turns raw bytes into lines, and
//  `SSEFieldParser` turns lines into actions (a complete event, a retry hint,
//  a comment). `EventStreamClient.live` feeds them byte-by-byte and keeps all
//  connection-level side effects (liveness stamps, backoff resets, cursor
//  advancement) in the loop, where the connection state lives.
//
//  NOTE: the framer exists because Foundation's `AsyncLineSequence` silently
//  drops empty lines (its iterator only yields when its buffer is non-empty),
//  but in SSE the blank line IS the event delimiter — so events would never
//  dispatch. We frame the raw byte stream ourselves, splitting on `\n` and
//  preserving blank lines (stripping a trailing CR for CRLF framing).
//

import Foundation

/// Accumulates bytes into `\n`-terminated lines, preserving empty lines and
/// stripping a trailing CR. Feed it one byte at a time; it returns a line
/// exactly when the byte completed one.
struct SSELineFramer {
    private var buffer: [UInt8] = []

    mutating func consume(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {   // not newline: accumulate
            buffer.append(byte)
            return nil
        }
        // End of a line. Strip a trailing CR (CRLF framing).
        if buffer.last == 0x0D {
            buffer.removeLast()
        }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// What one parsed SSE line asks the connection loop to do.
enum SSELineAction {
    /// Nothing actionable (a field accumulated, a keepalive, or junk).
    case none
    /// A blank line completed an event that carried an `id:` and `data:`.
    case event(StreamedEvent)
    /// A `retry:` hint — the server's requested reconnect delay.
    case retryHint(milliseconds: Int)
    /// A non-keepalive comment, for debug logging.
    case comment(String)
}

/// Accumulates SSE fields (`id:` / `event:` / `data:`) and dispatches the
/// pending event when the blank-line delimiter arrives. An event without an
/// `id:` or without any `data:` is dropped at the delimiter (the id doubles as
/// the resume cursor, so an id-less event couldn't be resumed past anyway).
/// Comments do NOT reset the pending event.
struct SSEFieldParser {
    private var pendingID: String?
    private var pendingEvent: String?
    private var dataLines: [String] = []

    mutating func consume(_ line: String) -> SSELineAction {
        if line.isEmpty {
            // Blank line = dispatch the accumulated event.
            defer {
                pendingID = nil
                pendingEvent = nil
                dataLines.removeAll(keepingCapacity: true)
            }
            if let id = pendingID, !dataLines.isEmpty,
               let data = dataLines.joined(separator: "\n").data(using: .utf8) {
                return .event(StreamedEvent(id: id, eventName: pendingEvent ?? "", raw: data))
            }
            return .none
        } else if line.hasPrefix("id:") {
            pendingID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("event:") {
            pendingEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            // SSE permits multiple `data:` lines per event; join them.
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("retry:") {
            if let ms = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                return .retryHint(milliseconds: ms)
            }
        } else if line.hasPrefix(":") && !line.hasPrefix(": keepalive") {
            return .comment(String(line.dropFirst(1)))
        }
        return .none
    }
}
