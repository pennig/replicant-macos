//
//  FleetMembership.swift
//  Replicould — DirectiveEngine
//
//  Which theatre's fleet a device is in, for every goal that fields one.
//

import GameModels

/// The one membership rule: an explicit scoped tag outranks location, and
/// location decides only for a device wearing no scoped tag for that goal.
public enum FleetMembership {
    public static func belongs(
        _ device: Device, to theatre: Theatre, goal: FleetTag.Goal, resolver: TheatreResolver
    ) -> Bool {
        belongs(device, toDepot: theatre.depot, goal: goal, resolver: resolver)
    }

    /// `belongs` for a caller holding a depot alone — a directive row's
    /// `theatreDepot` stamp may name a depot the registry does not recognise.
    public static func belongs(
        _ device: Device, toDepot depot: String, goal: FleetTag.Goal, resolver: TheatreResolver
    ) -> Bool {
        device.scopedTag(for: goal).map { $0.scope?.designation == depot.lowercased() }
            ?? (device.carries(FleetTag(goal: goal), policy: .exact)
                && resolver.owningTheatre(of: device, goal: goal)?.depot == depot)
    }
}
