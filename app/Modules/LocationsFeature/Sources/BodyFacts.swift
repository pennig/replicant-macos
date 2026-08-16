import Foundation
import UniverseModels

/// One promoted key/value row in a location header's info group.
public struct BodyFact: Equatable, Sendable {
    public let label: String
    public let value: String
    public let mono: Bool

    public init(label: String, value: String, mono: Bool = false) {
        self.label = label
        self.value = value
        self.mono = mono
    }
}

/// The facts a location detail header promotes beside its 128pt portrait, at most
/// five per subject. A row whose value is absent is dropped rather than shown empty.
public enum BodyFacts {
    public static func rows(star: SystemStar) -> [BodyFact] {
        var out = [BodyFact(label: "Class", value: star.stellarClass ?? "—")]
        out.append(BodyFact(label: "Color", value: star.color?.capitalized ?? "—"))
        if let age = star.ageMy { out.append(BodyFact(label: "Age", value: String(format: "%.0f My", age))) }
        if let bonus = star.miningBonusPct, bonus != 0 {
            out.append(BodyFact(label: "Mining bonus", value: "+\(Int(bonus))%"))
        }
        if let d = star.distanceFromSol {
            out.append(BodyFact(label: "From Sol", value: String(format: "%.1f ly", d)))
        }
        return out
    }

    public static func rows(planet: Planet) -> [BodyFact] {
        var out = [BodyFact(
            label: "Type",
            value: (planet.type ?? "—") + (planet.typeEstimated ? " (est.)" : "")
        )]
        if let au = planet.orbitalDistanceAu {
            out.append(BodyFact(label: "Orbit", value: String(format: "%.2f AU", au)))
        }
        out.append(BodyFact(label: "Habitable zone", value: planet.inHabitableZone ? "Yes" : "No"))
        if let life = planet.lifeStage, life != "none" {
            out.append(BodyFact(label: "Life", value: life.capitalized))
        }
        if let n = planet.moonCount { out.append(BodyFact(label: "Moons", value: "\(n)")) }
        return out
    }

    public static func rows(moon: Moon) -> [BodyFact] {
        var out = [BodyFact(label: "Type", value: moon.type ?? "—")]
        guard let p = moon.physical else { return out }
        if let r = p.radiusEarth { out.append(BodyFact(label: "Radius", value: String(format: "%.2f R⊕", r))) }
        if let g = p.surfaceGravity { out.append(BodyFact(label: "Gravity", value: String(format: "%.2f g", g))) }
        if let t = p.surfaceTempC { out.append(BodyFact(label: "Surface", value: String(format: "%.0f °C", t))) }
        if let a = p.atmosphere { out.append(BodyFact(label: "Atmosphere", value: a.capitalized)) }
        return out
    }

    public static func rows(belt: Belt) -> [BodyFact] {
        var out: [BodyFact] = []
        if let d = belt.density { out.append(BodyFact(label: "Density", value: d.capitalized)) }
        if let inner = belt.innerRadiusAu, let outer = belt.outerRadiusAu {
            out.append(BodyFact(label: "Radius", value: String(format: "%.1f–%.1f AU", inner, outer)))
        }
        return out
    }

    public static func rows(site: SpecialSite) -> [BodyFact] {
        var out = [BodyFact(label: "Type", value: humanised(site.objectType ?? site.kind.rawValue))]
        if let status = site.status { out.append(BodyFact(label: "Status", value: humanised(status))) }
        if let stage = site.stage { out.append(BodyFact(label: "Stage", value: humanised(stage))) }
        if let au = site.orbitalDistanceAu {
            out.append(BodyFact(label: "Orbit", value: String(format: "%.2f AU", au)))
        }
        if let deadline = site.deadline {
            out.append(BodyFact(label: "Deadline", value: deadline, mono: true))
        }
        return out
    }

    public static func rows(lagrangePoint n: Int, parent: Planet, site: SpecialSite?) -> [BodyFact] {
        var out = [
            BodyFact(label: "Point", value: "L\(n)"),
            BodyFact(label: "Stability", value: (n == 4 || n == 5) ? "Stable" : "Unstable"),
            BodyFact(label: "Parent", value: parent.designation, mono: true),
        ]
        if let au = site?.orbitalDistanceAu ?? parent.orbitalDistanceAu {
            out.append(BodyFact(label: "Orbit", value: String(format: "%.2f AU", au)))
        }
        return out
    }

    private static func humanised(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
