//
//  BlueprintPresentation.swift
//  Replicould — Blueprints feature
//
//  View-side helpers that map backend strings to display: a device-type glyph
//  and human name (covering the full blueprint catalog, including types with no
//  deployed instances yet), and a human-readable print-time readout.
//

import Foundation

enum BlueprintPresentation {
    /// "ami_mining_controller" → "Ami Mining Controller".
    static func displayName(_ deviceType: String) -> String {
        deviceType
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// An SF Symbol for a device type. Covers every type the blueprint catalog
    /// lists, falling back to the generic device glyph.
    static func symbol(for deviceType: String) -> String {
        switch deviceType {
        case "heaven_vessel":            return "paperplane"
        case "autofactory":              return "building.2"
        case "system_hub":               return "circle.circle"
        case "compute_core":             return "memorychip"
        case "empty_replicant_matrix",
             "matrix_container":         return "square.grid.2x2"
        case "ftl_beacon":               return "antenna.radiowaves.left.and.right"
        case "ftl_relay":                return "dot.radiowaves.left.and.right"
        case "mining_drone":             return "hammer"
        case "survey_drone":             return "scope"
        case "maintenance_drone":        return "wrench.and.screwdriver"
        case "cargo_freighter",
             "transport_drone",
             "transport_hauler":         return "shippingbox"
        case "ami_mining_controller",
             "ami_survey_controller",
             "ami_transport_controller": return "cpu"
        default:                         return "circle.hexagongrid"
        }
    }

    /// Humanizes a print time in seconds — e.g. 1800 → "30 min", 28800 → "8 hr",
    /// 4800 → "1 hr 20 min". Tuned for build durations (minutes–hours), unlike
    /// `Duration.apiCallReadout` which targets sub-second API timings.
    static func printTimeText(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, zeroValueUnits: .hide)
        )
    }
}
