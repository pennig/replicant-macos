//
//  SSEWireTests.swift
//  Replicould — API
//
//  The SSE wire protocol (V3.10 item 15 / S10): line framing over raw bytes
//  (blank lines are the event delimiter Foundation's AsyncLineSequence drops),
//  and field parsing — id/event/data accumulation, blank-line dispatch, retry
//  hints, keepalives vs comments.
//

import Foundation
import Testing
@testable import API

@Suite struct SSEWireTests {

    /// Feed a raw wire string through framer + parser, collecting the actions.
    private func run(_ wire: String) -> [SSELineAction] {
        var framer = SSELineFramer()
        var parser = SSEFieldParser()
        var actions: [SSELineAction] = []
        for byte in Array(wire.utf8) {
            if let line = framer.consume(byte) {
                actions.append(parser.consume(line))
            }
        }
        return actions
    }

    private func events(in actions: [SSELineAction]) -> [StreamedEvent] {
        actions.compactMap { if case .event(let e) = $0 { return e } else { return nil } }
    }

    @Test func completeFrameDispatchesOnTheBlankLine() {
        let actions = run("id: 1749-0\nevent: mining.started\ndata: {\"a\":1}\n\n")
        let dispatched = events(in: actions)
        #expect(dispatched.count == 1)
        #expect(dispatched.first?.id == "1749-0")
        #expect(dispatched.first?.eventName == "mining.started")
        #expect(dispatched.first.map { String(decoding: $0.raw, as: UTF8.self) } == "{\"a\":1}")
        // Nothing dispatches before the delimiter.
        if case .event = actions[0] { Issue.record("id line must not dispatch") }
    }

    @Test func crlfFramingIsEquivalentToLF() {
        let lf = events(in: run("id: 5-1\nevent: e\ndata: {}\n\n"))
        let crlf = events(in: run("id: 5-1\r\nevent: e\r\ndata: {}\r\n\r\n"))
        #expect(lf.count == 1 && crlf.count == 1)
        #expect(lf.first?.id == crlf.first?.id)
        #expect(lf.first.map(\.raw) == crlf.first.map(\.raw))
    }

    @Test func multipleDataLinesJoinWithNewlines() {
        let dispatched = events(in: run("id: 2-0\ndata: line one\ndata: line two\n\n"))
        #expect(dispatched.first.map { String(decoding: $0.raw, as: UTF8.self) } == "line one\nline two")
    }

    @Test func eventWithoutAnIDIsDroppedAtTheDelimiter() {
        // The id doubles as the resume cursor; an id-less event can't be resumed past.
        let actions = run("event: mystery\ndata: {}\n\n")
        #expect(events(in: actions).isEmpty)
    }

    @Test func eventWithoutDataIsDroppedAtTheDelimiter() {
        let actions = run("id: 3-0\nevent: hollow\n\n")
        #expect(events(in: actions).isEmpty)
    }

    @Test func delimiterResetsStateBetweenEvents() {
        // The dropped id-less first frame must not bleed its data into the second.
        let dispatched = events(in: run("data: orphan\n\nid: 4-0\nevent: real\ndata: {\"b\":2}\n\n"))
        #expect(dispatched.count == 1)
        #expect(dispatched.first?.id == "4-0")
        #expect(dispatched.first.map { String(decoding: $0.raw, as: UTF8.self) } == "{\"b\":2}")
    }

    @Test func staleIDNeverResurrectsIntoALaterFrame() {
        // The delimiter clears pendingID/pendingEvent too, not just the data —
        // an id-less second frame must drop, never recycle the first frame's id.
        let dispatched = events(in: run("id: 1-0\nevent: e\ndata: a\n\ndata: b\n\n"))
        #expect(dispatched.count == 1)
        #expect(dispatched.first?.id == "1-0")
        #expect(dispatched.first.map { String(decoding: $0.raw, as: UTF8.self) } == "a")
    }

    @Test func commentsDoNotResetThePendingEvent() {
        let actions = run("id: 6-0\n: heartbeat note\ndata: {}\n\n")
        let dispatched = events(in: actions)
        #expect(dispatched.first?.id == "6-0")
        #expect(actions.contains { if case .comment(" heartbeat note") = $0 { return true } else { return false } })
    }

    @Test func keepalivesAreSilentButJunkCommentsSurface() {
        let keepalive = run(": keepalive\n: keepalive-extra\n")
        #expect(keepalive.allSatisfy { if case .none = $0 { return true } else { return false } })
        let junk = run(": junk\n")
        #expect(junk.contains { if case .comment(" junk") = $0 { return true } else { return false } })
    }

    @Test func retryHintParsesAndGarbageIsIgnored() {
        let actions = run("retry: 5000\nretry: soon\n")
        #expect(actions.contains { if case .retryHint(milliseconds: 5000) = $0 { return true } else { return false } })
        // The malformed hint produces no action.
        #expect(actions.filter { if case .retryHint = $0 { return true } else { return false } }.count == 1)
    }

    // Deliberate divergence from the SSE spec (which strips only a single
    // leading space from a field value) — full whitespace trimming is
    // preserved from the pre-extraction parser; the server never sends
    // whitespace-significant payloads (data is always JSON).
    @Test func fieldValuesAreWhitespaceTrimmed() {
        let dispatched = events(in: run("id:   7-0  \nevent:   spaced.name \ndata:   {\"c\":3}  \n\n"))
        #expect(dispatched.first?.id == "7-0")
        #expect(dispatched.first?.eventName == "spaced.name")
        #expect(dispatched.first.map { String(decoding: $0.raw, as: UTF8.self) } == "{\"c\":3}")
    }

    @Test func unknownLinesAreIgnoredWithoutDisturbingTheFrame() {
        let dispatched = events(in: run("id: 8-0\nnonsense line\ndata: {}\n\n"))
        #expect(dispatched.count == 1)
        #expect(dispatched.first?.id == "8-0")
    }
}
