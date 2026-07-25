import GameServices
import Testing
@testable import DevicesFeature

struct CommandGroupTests {
    @Test func everyExistingVerbMapsToItsApprovedGroup() {
        let expected: [(String, CommandGroup)] = [
            ("travel", .movement), ("recall", .movement), ("deploy", .movement), ("stow", .movement),
            ("start_mining", .tasks), ("retarget", .tasks), ("scan", .tasks),
            ("search", .tasks), ("system_scan", .tasks), ("stellar_census", .tasks), ("repair", .tasks),
            ("enqueue_print", .production), ("clear_queue", .production),
            ("set_directive", .control), ("clear_directive", .control), ("adopt", .control),
            ("release", .control), ("launch", .control), ("withdraw", .control), ("assemble", .control),
            ("attach", .carrier), ("detach", .carrier), ("configure", .carrier),
            ("collect_resources", .carrier), ("deposit_resources", .carrier),
            ("compact", .modular), ("unfurl", .modular),
            ("activate", .power), ("deactivate", .power), ("message", .power),
            ("decommission", .special), ("replicate", .special), ("set_entry_point", .special), ("change_owner", .special),
        ]
        for (verb, group) in expected {
            #expect(CommandGroup.group(for: verb) == group, "\(verb) should map to \(group)")
        }
    }

    /// The taxonomy and the dispatchable universe must be the same set: every
    /// verb the grid can construct has a home group, and every verb the
    /// taxonomy orders is actually constructible. Catches both a new command
    /// landing without a group (it would silently fall to Special) and a
    /// taxonomy entry going stale when a verb is removed.
    @Test func taxonomyExactlyCoversTheDispatchableUniverse() {
        let structured = [
            "travel", "start_mining", "retarget", "system_scan", "scan",
            "stellar_census", "enqueue_print", "stow", "set_directive",
            "adopt", "release", "attach", "detach",
            "collect_resources", "deposit_resources",
            "configure", "message", "repair", "replicate", "change_owner",
        ]
        let universe = Set(structured).union(CommandClient.supportedSimpleCommands)
        let taxonomy = Set(CommandGroup.allCases.flatMap(\.commandOrder))
        #expect(taxonomy == universe)
    }

    @Test func unknownVerbFallsBackToSpecial() {
        #expect(CommandGroup.group(for: "frobnicate") == .special)
    }

    @Test func sectionsKeepStableGroupOrderAndOmitEmptyGroups() {
        let sections = CommandGroup.sections(for: [.simple("deactivate"), .travel, .simple("decommission")])
        #expect(sections == [
            CommandSection(group: .movement, commands: [.travel]),
            CommandSection(group: .power, commands: [.simple("deactivate")]),
            CommandSection(group: .special, commands: [.simple("decommission")]),
        ])
    }

    @Test func withinGroupOrderFollowsTaxonomyNotInputOrder() {
        let sections = CommandGroup.sections(for: [.stow(targets: []), .simple("deploy"), .simple("recall"), .travel])
        #expect(sections == [
            CommandSection(group: .movement, commands: [.travel, .simple("recall"), .simple("deploy"), .stow(targets: [])])
        ])
    }

    @Test func unknownVerbsSortAfterKnownOnesPreservingInputOrder() {
        let sections = CommandGroup.sections(for: [.simple("zzz"), .simple("aaa"), .simple("decommission")])
        #expect(sections == [
            CommandSection(group: .special, commands: [.simple("decommission"), .simple("zzz"), .simple("aaa")])
        ])
    }

    @Test func emptyInputYieldsNoSections() {
        #expect(CommandGroup.sections(for: []).isEmpty)
    }
}
