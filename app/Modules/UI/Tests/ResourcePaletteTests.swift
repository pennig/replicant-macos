import SwiftUI
import Testing
@testable import UI

@Suite struct ResourcePaletteTests {
    @Test func everyResourceKeyResolvesToItsOwnToken() {
        let keys = ["structural", "conductive", "silicates", "carbon", "rares", "volatiles"]
        let colors = keys.map { Color.rcResource($0) }
        #expect(Set(colors.map(\.description)).count == keys.count)
    }

    @Test func anUnknownKeyFallsBackToTheMutedInk() {
        #expect(Color.rcResource("unobtainium").description == Color.rcTextTertiary.description)
    }
}
