//
//  BlueprintPresentation.swift
//  Replicould — GameModels (shared domain display helpers)
//
//  View-side helpers that map backend strings to display: a device-type glyph
//  and human name (covering the full blueprint catalog, including types with no
//  deployed instances yet), and a human-readable print-time readout.
//

import Foundation

public enum BlueprintPresentation {
    /// "mining_drone" → "Mining Drone". Certain tokens render as all-caps forms
    /// rather than title case: "heaven_vessel" → "HEAVEN Vessel", "ftl_beacon" →
    /// "FTL Beacon", "ami_mining_controller" → "AMI Mining Controller".
    public static func displayName(_ deviceType: String) -> String {
        deviceType
            .split(separator: "_")
            .map { token -> String in
                specialCasings[token.lowercased()]
                    ?? token.prefix(1).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Backend device-type tokens that render as fixed all-caps forms instead of
    /// plain title case.
    private static let specialCasings: [String: String] = [
        "heaven": "HEAVEN",
        "ftl": "FTL",
        "ami": "AMI",
    ]

    /// Humanizes a print time in seconds — e.g. 1800 → "30 min", 28800 → "8 hr",
    /// 4800 → "1 hr 20 min". Tuned for build durations (minutes–hours), unlike
    /// `Duration.apiCallReadout` which targets sub-second API timings.
    public static func printTimeText(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, zeroValueUnits: .hide)
        )
    }

    /// Splits a print time into large-number / small-unit components for the
    /// Print Time lockup — e.g. 28800 → `[(8, "hr")]`, 4800 → `[(1, "hr"), (20,
    /// "min")]`. Always yields at least one component (a bare `0 min`) so the
    /// lockup never renders empty.
    public static func printTimeComponents(_ seconds: Int) -> [(value: Int, unit: String)] {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        var components: [(value: Int, unit: String)] = []
        if hours > 0 { components.append((hours, "hr")) }
        if minutes > 0 { components.append((minutes, "min")) }
        if components.isEmpty { components.append((0, "min")) }
        return components
    }
}
