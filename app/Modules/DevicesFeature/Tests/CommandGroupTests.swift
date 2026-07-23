import Testing
@testable import DevicesFeature

struct CommandGroupTests {
    @Test func everyExistingVerbMapsToItsApprovedGroup() {
        let expected: [(String, CommandGroup)] = [
            ("travel", .movement), ("recall", .movement), ("deploy", .movement), ("stow", .movement),
            ("start_mining", .tasks), ("retarget", .tasks), ("scan", .tasks),
            ("search", .tasks), ("system_scan", .tasks), ("stellar_census", .tasks),
            ("enqueue_print", .production), ("clear_queue", .production),
            ("set_directive", .control), ("clear_directive", .control), ("adopt", .control),
            ("release", .control), ("launch", .control), ("withdraw", .control), ("assemble", .control),
            ("attach", .carrier), ("detach", .carrier),
            ("collect_resources", .carrier), ("deposit_resources", .carrier),
            ("compact", .modular), ("unfurl", .modular),
            ("activate", .power), ("deactivate", .power),
            ("decommission", .special), ("set_entry_point", .special),
        ]
        for (verb, group) in expected {
            #expect(CommandGroup.group(for: verb) == group, "\(verb) should map to \(group)")
        }
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
        let sections = CommandGroup.sections(for: [.stow, .simple("deploy"), .simple("recall"), .travel])
        #expect(sections == [
            CommandSection(group: .movement, commands: [.travel, .simple("recall"), .simple("deploy"), .stow])
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
