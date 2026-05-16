import Foundation
import Testing
@testable import PushGoAppleCore

struct ChannelSubscriptionModelTests {
    @Test
    func identityIncludesGatewayAndTrimmedChannelIdForSwiftUILists() {
        let updatedAt = Date(timeIntervalSince1970: 1_742_000_000)
        let first = ChannelSubscription(
            gateway: " https://one.pushgo.dev ",
            channelId: " shared-channel ",
            displayName: "One",
            updatedAt: updatedAt,
            lastSyncedAt: nil
        )
        let second = ChannelSubscription(
            gateway: "https://two.pushgo.dev",
            channelId: "shared-channel",
            displayName: "Two",
            updatedAt: updatedAt,
            lastSyncedAt: nil
        )
        let sameLogicalChannel = ChannelSubscription(
            gateway: "https://one.pushgo.dev",
            channelId: "shared-channel",
            displayName: "Renamed",
            updatedAt: updatedAt.addingTimeInterval(10),
            lastSyncedAt: nil
        )

        #expect(first.id != second.id)
        #expect(first.id == sameLogicalChannel.id)
    }
}
