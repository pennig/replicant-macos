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
    /// "ami_mining_controller" → "Ami Mining Controller".
    public static func displayName(_ deviceType: String) -> String {
        deviceType
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Humanizes a print time in seconds — e.g. 1800 → "30 min", 28800 → "8 hr",
    /// 4800 → "1 hr 20 min". Tuned for build durations (minutes–hours), unlike
    /// `Duration.apiCallReadout` which targets sub-second API timings.
    public static func printTimeText(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, zeroValueUnits: .hide)
        )
    }
}
