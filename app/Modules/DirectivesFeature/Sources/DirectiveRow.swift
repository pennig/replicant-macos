//
//  DirectiveRow.swift
//  Replicould — Directives feature
//
//  The unified list's row model. Two sources, one view model: custom missions
//  come from the `Directive` table, built-in AMI directives are DERIVED from
//  `Device` rows and never persisted — the server owns that state, so a derived
//  row is structurally incapable of drifting from it.
//
//  Deliberately SwiftUI-free: this is the list's only real logic, and pure
//  logic hanging off a SwiftUI View traps under `swift test`.
//

import DirectiveEngine
import Foundation
import GameModels
import Utils

/// What owns a built-in AMI directive — the engine set it, so the user must not
/// Reconfigure or Clear it out from under the work waiting on it.
public struct DirectiveOwner: Equatable, Sendable {
    /// Which of the two ownerships holds the directive.
    public enum Holder: Equatable, Sendable {
        /// A live custom mission, via `Directive.controllerCode`.
        case mission(id: String)
        /// The device's own `auto:` fleet tag, when no mission row holds it.
        case fleetTag(FleetTag)
    }

    public let holder: Holder
    /// What the badge names: the mission's kind title, or the automation the
    /// tag enrols the device in.
    public let title: String
    /// Where that automation works, when the fleet establishes a site for it.
    public let designation: String?

    public init(holder: Holder, title: String, designation: String? = nil) {
        self.holder = holder
        self.title = title
        self.designation = designation
    }

    /// The row's second line while this owner holds it.
    public var summary: String {
        switch holder {
        case .mission: "driven by \(title)"
        case .fleetTag: "part of the \(title)"
        }
    }

    /// One line naming the owner in a refusal log.
    public var logDescription: String {
        switch holder {
        case let .mission(id): "driven by directive \(id)"
        case let .fleetTag(tag): "part of the \(title), via \(tag)"
        }
    }
}

/// An AMI directive currently in force on a device, projected for the list.
public struct BuiltInDirective: Equatable, Identifiable, Sendable {
    public let deviceCode: String
    public let deviceType: String
    /// The directive's backend name, e.g. `survey_system`.
    public let directive: String
    /// Its in-force configuration, or nil for directives that take none.
    public let config: JSONValue?
    /// The drones this controller is running, with their live status.
    public let controlledDevices: [Device.ControlledDevice]
    /// Set when the engine owns this directive (see `DirectiveOwner`).
    public let drivenBy: DirectiveOwner?
    /// The device's own tags, unfiltered — `DirectiveGroup` needs the most
    /// specific fleet tag, which is not the one `drivenBy` names.
    public let tags: [String]

    public var id: String { deviceCode }

    public init(
        deviceCode: String,
        deviceType: String,
        directive: String,
        config: JSONValue?,
        controlledDevices: [Device.ControlledDevice],
        drivenBy: DirectiveOwner? = nil,
        tags: [String] = []
    ) {
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.directive = directive
        self.config = config
        self.controlledDevices = controlledDevices
        self.drivenBy = drivenBy
        self.tags = tags
    }
}

/// One row of the Directives list — either kind.
public enum DirectiveRow: Equatable, Identifiable, Sendable {
    /// A custom mission's row.
    ///
    /// `haulTarget` is the one piece of a row's display that cannot be read off
    /// the `Directive`: a Haul Run stores no assignment state at all — no
    /// queue, no `roamCentre`, no drained-pile count (spec §6 recomputes the
    /// whole assignment from the census every cycle) — so what it is working
    /// exists only on the tagged controllers' in-force config. `merge` reads it
    /// there. Nil for every other kind, and for a Haul Run with nothing
    /// reachable.
    case custom(Directive, haulTarget: String? = nil)
    case builtIn(BuiltInDirective)

    /// Namespaced so a device code and a directive id can never collide in the
    /// list's selection.
    public var id: String {
        switch self {
        case let .custom(directive, _): "custom:\(directive.id)"
        case let .builtIn(builtIn): "builtin:\(builtIn.deviceCode)"
        }
    }

    /// The device the row is about — the vessel for a mission, the controller
    /// for a built-in directive.
    public var deviceCode: String {
        switch self {
        case let .custom(directive, _): directive.deviceCode
        case let .builtIn(builtIn): builtIn.deviceCode
        }
    }

    /// The row's headline, **without** any designation — see
    /// `headlineDesignation`. Split because a designation must render in a mono
    /// token (house rule) and a single interpolated string forces one font on
    /// the whole line.
    public var headline: String {
        switch self {
        case let .custom(directive, _): directive.kind.title
        case let .builtIn(builtIn): BlueprintPresentation.displayName(builtIn.directive)
        }
    }

    /// The designation half of the headline — a mission's current target, or nil
    /// (built-in rows name a directive, never a place).
    ///
    /// A general Haul Run's target comes from `haulTarget` rather than the queue:
    /// it has no queue, and this is the run that most needs the designation in a
    /// MONO token (house rule), which is exactly what this half of the headline
    /// renders. The subtitle names the work; this names the place.
    public var headlineDesignation: String? {
        switch self {
        case let .custom(directive, haulTarget):
            guard directive.kind == .haulRun else { return directive.currentTarget }
            // A pinned row names the pile it is pinned to whether or not its
            // ferry has taken the config yet; the subtitle carries that half.
            return HaulRun.pinnedSource(of: directive) ?? haulTarget
        // A built-in row names a directive, not a place — except when its owner
        // works one, which is what tells two installed mines apart.
        case let .builtIn(builtIn): return builtIn.drivenBy?.designation
        }
    }

    /// The whole headline as one string, for `navigationTitle` and
    /// accessibility, where a single `String` is all the API accepts. Anywhere
    /// that can render two runs should use `headline` + `headlineDesignation`.
    public var title: String {
        guard let designation = headlineDesignation else { return headline }
        return "\(headline) → \(designation)"
    }

    /// The theatre owning this row's work — nil for every built-in row (no
    /// theatre concept applies) and for a custom mission never assigned one.
    public var theatreDepot: String? {
        switch self {
        case let .custom(directive, _): directive.theatreDepot
        case .builtIn: nil
        }
    }

    /// "unassigned" rather than nil, so a row with no theatre still reads —
    /// see `filterKeepsUnassignedVisible`.
    public var theatreLabel: String { theatreDepot ?? "unassigned" }

    /// The row's second line: progress for a mission, the controlled-drone count
    /// for a built-in — or, when the engine owns it, the mission driving it.
    ///
    /// Lives here rather than on `DirectiveRowView` because this type is the
    /// list's SwiftUI-free logic (pure logic hanging off a View traps under
    /// `swift test`), which is what makes the continuous-run branch below
    /// testable at all.
    public var subtitle: String? {
        switch self {
        case let .custom(directive, haulTarget):
            // A Haul Run has no queue to count — no `roamCentre`, no `targets`,
            // and deliberately no drained-pile column (spec §9: "a count of
            // drained piles is deliberately not offered… inventing a column to
            // display a number would be the only reason that column existed").
            // So it never reaches either progress readout below; an m/n here
            // would read `0/0` forever, and an idled or mispointed run would be
            // indistinguishable from a working one on the one surface that
            // could tell them apart. Name the work in flight instead; the pile
            // itself renders as `headlineDesignation`, in mono per the house
            // rule.
            if directive.kind == .haulRun {
                // A pinned row always names its pile, so "Nothing reachable"
                // would be false; report whether the ferry has taken it.
                if let pinned = HaulRun.pinnedSource(of: directive) {
                    return haulTarget == pinned ? "Hauling belt inventory" : "Pointing the ferry"
                }
                return haulTarget == nil ? "Nothing reachable" : "Hauling"
            }
            // Restock has no queue to walk either: its `targets` are the DEMAND
            // it is printing against, not a route, and `targetIndex` never
            // advances — so the m/n readout below would sit at "0/7" forever.
            // Say what it is stocking for instead.
            if directive.kind == .restockRun {
                let wanted = directive.targets.count
                return wanted == 0 ? "Stocked" : "Stocking for \(wanted) target\(wanted == 1 ? "" : "s")"
            }
            // A continuous run EXTENDS its queue instead of completing it, so
            // `targetIndex == targets.count` for the whole window between
            // finishing one system and planning the next — and "n/n" reads as a
            // finished run. Count what is done instead. The current target is
            // not repeated here; `headlineDesignation` already renders it.
            if directive.roamCentre != nil {
                switch directive.kind {
                case .salvageRun:
                    let count = directive.targetIndex
                    return "\(count) system\(count == 1 ? "" : "s") drained"
                case .surveyRun, .relayRun:
                    return "\(directive.targetIndex) surveyed"
                case .haulRun, .restockRun, .mineFleetPrint, .mineRun, .eventRun,
                     .eventCourierPrint:
                    // Handled above, or never roams — no queue to walk here.
                    return nil
                }
            }
            let progress = directive.progress
            return "\(progress.completed)/\(progress.total)"
        case let .builtIn(builtIn):
            if let owner = builtIn.drivenBy { return owner.summary }
            let count = builtIn.controlledDevices.count
            return count > 0 ? "\(count) controlled" : nil
        }
    }

    /// Statuses that still hold a controller. `paused` and `needsAttention`
    /// KEEP ownership: the directive is still in force server-side, and a user
    /// resolving a stall expects to find it intact. Only a finished mission
    /// gives the row back.
    static let owningStatuses: Set<DirectiveStatus> = [.running, .needsAttention, .paused]

    /// Merge the two sources into one ordered list. `devices` contributes a row
    /// for each device with a directive in force; `directives` contributes one
    /// per custom mission. A built-in row the engine owns — by a live mission's
    /// `controllerCode`, else by the device's own fleet tag — carries `drivenBy`.
    ///
    /// `devices` also feeds a Haul Run's `haulTarget` — see the `.custom` case.
    /// Both sources are already in hand here, which is why this is the one place
    /// that cross-reference can be made without the row model reaching for the
    /// database.
    public static func merge(devices: [Device], directives: [Directive]) -> [DirectiveRow] {
        let owners: [String: DirectiveOwner] = directives.reduce(into: [:]) { owners, directive in
            guard let controller = directive.controllerCode,
                  owningStatuses.contains(directive.status)
            else { return }
            owners[controller] = DirectiveOwner(
                holder: .mission(id: directive.id),
                title: directive.kind.title
            )
        }
        let custom = directives.map { directive -> DirectiveRow in
            guard directive.kind == .haulRun else { return .custom(directive) }
            if HaulRun.pinnedSource(of: directive) != nil {
                // A pinned row drives its OWN device, and its per-belt tag is
                // worn by nothing — the tag lookup below cannot see its ferry.
                let ferry = devices.first { $0.deviceCode == directive.deviceCode }
                return .custom(
                    directive,
                    haulTarget: ferry.flatMap {
                        HaulRun.drainedPile(of: $0, delivery: HaulRun.deliveryLocation)
                    }
                )
            }
            // Resolved by TAG, exactly as the machine resolves its working set
            // on every evaluation — the row must agree with what the run is
            // actually commanding, and the tag is the operator's opt-in.
            return .custom(
                directive,
                haulTarget: HaulRun.currentHaulTarget(
                    devices: devices,
                    tag: directive.fleetTag.flatMap(FleetTag.init(parsing:)) ?? HaulRun.defaultFleetTag,
                    // The fallback: this row has no `WorldSnapshot` to derive
                    // the live sink from.
                    delivery: HaulRun.deliveryLocation
                )
            )
        }
        // A mine stands where a tagged mining controller is RUNNING one; a
        // fleet still idle at the hub is inventory, not a mine.
        let belts = MineRecipe.installedBelts(
            in: devices.filter { $0.currentDirective?.isEmpty == false }, hub: nil
        )
        let builtIn = devices.compactMap { device -> DirectiveRow? in
            guard let directive = device.currentDirective, !directive.isEmpty else { return nil }
            return .builtIn(
                BuiltInDirective(
                    deviceCode: device.deviceCode,
                    deviceType: device.deviceType,
                    directive: directive,
                    config: device.currentDirectiveConfig,
                    controlledDevices: device.controlledDevices,
                    drivenBy: owners[device.deviceCode] ?? fleetOwner(of: device, belts: belts),
                    tags: device.tags
                )
            )
        }
        return custom + builtIn
    }

    /// The owner of a device the engine drives with no mission row to hold it —
    /// the permanent mine's belt controllers, and every service bot an armed
    /// fleet left standing. Untagging the device is the take-back gesture.
    static func fleetOwner(of device: Device, belts: Set<String>) -> DirectiveOwner? {
        guard let tag = DirectiveGroup.siteBearingTag(in: device.tags) else { return nil }
        // Only a device standing at an installed belt can claim that mine; the
        // ferry lives at the delivery sink, which is nobody's mine.
        let belt = device.location.flatMap { belts.contains($0) ? $0 : nil }
        guard tag.goal == .mine else {
            return DirectiveOwner(holder: .fleetTag(tag), title: automationTitle(tag))
        }
        return DirectiveOwner(
            holder: .fleetTag(tag),
            title: automationTitle(tag),
            designation: tag.scope?.designation.uppercased() ?? belt
        )
    }

    /// The automation a fleet tag enrols a device in, phrased for the row: the
    /// goal reads as the fleet, and a mine is a place rather than a fleet.
    static func automationTitle(_ tag: FleetTag) -> String {
        tag.goal == .mine ? "mine" : "\(tag.goal.rawValue) fleet"
    }
}
