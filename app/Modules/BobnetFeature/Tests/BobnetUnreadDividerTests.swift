import Foundation
import GameModels
import Testing

@testable import BobnetFeature

@Suite("Bobnet unread divider anchor")
struct BobnetUnreadDividerTests {
    private func messages(ids: [Int]) -> [BobnetMessage] {
        ids.map { id in
            BobnetMessage(
                id: id,
                replicantName: "Vela",
                replicantCode: "RPL-\(id)",
                currentStar: nil,
                channel: "#general",
                message: "m\(id)",
                time: Date(timeIntervalSince1970: TimeInterval(id))
            )
        }
    }

    @Test("a zero marker anchors nothing")
    func zeroMarkerAnchorsNothing() {
        #expect(BobnetUnreadDivider.anchor(in: messages(ids: [1, 2, 3]), marker: 0) == nil)
    }

    @Test("the anchor is the first message past the marker")
    func anchorIsFirstPastMarker() {
        #expect(BobnetUnreadDivider.anchor(in: messages(ids: [1, 2, 3, 4]), marker: 2) == 3)
    }

    @Test("a marker at the newest message anchors nothing")
    func markerAtNewestAnchorsNothing() {
        #expect(BobnetUnreadDivider.anchor(in: messages(ids: [1, 2, 3]), marker: 3) == nil)
    }

    @Test("a marker on a gap anchors the next surviving message")
    func markerOnGapAnchorsNextSurvivor() {
        #expect(BobnetUnreadDivider.anchor(in: messages(ids: [1, 5, 9]), marker: 3) == 5)
    }

    @Test("an empty channel anchors nothing")
    func emptyChannelAnchorsNothing() {
        #expect(BobnetUnreadDivider.anchor(in: [], marker: 7) == nil)
    }
}
