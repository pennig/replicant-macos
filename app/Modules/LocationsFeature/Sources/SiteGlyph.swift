import SwiftUI
import UniverseModels
import UI

/// The SF Symbol standing in for a site that has no rendered geometry.
enum SiteGlyph {
    static func symbolName(for site: SpecialSite) -> String {
        if site.objectType == "incoming_asteroid" { return "exclamationmark.triangle" }
        switch site.kind {
        case .megastructure:                      return "building.2"
        case .object, .lagrange, .kuiper, .oort:  return "shippingbox"
        }
    }
}

/// A site's symbol at portrait size, in the header's chrome.
struct SiteGlyphPortrait: View {
    let site: SpecialSite

    private var isThreat: Bool { site.objectType == "incoming_asteroid" }

    var body: some View {
        Image(systemName: SiteGlyph.symbolName(for: site))
            .font(.system(size: IconSize.display, weight: .regular))
            .foregroundStyle(isThreat ? .rcDanger : .rcTextSecondary)
    }
}
