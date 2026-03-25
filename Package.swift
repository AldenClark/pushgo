// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PushGoAppleCoreTests",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PushGoAppleCore",
            targets: ["PushGoAppleCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.6.0"),
    ],
    targets: [
        .target(
            name: "PushGoAppleCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Shared",
            sources: [
                "Models/AppError.swift",
                "Models/MessageFilter.swift",
                "Models/PushMessage.swift",
                "Models/PushMessageSummary.swift",
                "Models/ServerConfig.swift",
                "Models/WatchLightModels.swift",
                "Repositories/LocalDataStore.swift",
                "Repositories/MessageSearchIndex.swift",
                "Repositories/SwiftDataModels.swift",
                "Services/NotificationHandling.swift",
                "Services/PrivateWakeupPullCoordinator.swift",
                "Services/PushRegistrationService.swift",
                "Utilities/AnyCodable.swift",
                "Utilities/AppConstants.swift",
                "Utilities/ChannelNameValidator.swift",
                "Utilities/ChannelPasswordValidator.swift",
                "Utilities/KeychainStore.swift",
                "Utilities/LocalizationProvider.swift",
                "Utilities/ManualNotificationKeyValidator.swift",
                "Utilities/NotificationPayloadSemantics.swift",
                "Utilities/PrivateWakeupAckSemantics.swift",
                "Utilities/ProjectionSemantics.swift",
                "Utilities/PushGoMarkdownCore.swift",
                "Utilities/SharedImageCache.swift",
                "Utilities/PushRegistrationSemantics.swift",
                "Utilities/SearchQuerySemantics.swift",
                "Utilities/UserInfoSanitizer.swift",
                "Utilities/WatchLightQuantizer.swift",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-strict-concurrency=complete",
                    "-warnings-as-errors",
                ])
            ]
        ),
        .testTarget(
            name: "PushGoAppleCoreTests",
            dependencies: ["PushGoAppleCore"],
            path: "Tests/PushGoAppleCoreTests"
        ),
    ]
)
