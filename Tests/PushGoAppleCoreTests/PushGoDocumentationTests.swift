import Foundation
import Testing
@testable import PushGoAppleCore

struct PushGoDocumentationTests {
    @Test
    func documentationPagesResolveToExactOfficialHTTPSDestinations() {
        let pages: [(PushGoDocumentationPage, String)] = [
            (.gettingStarted, "/guides/getting-started/"),
            (.messageAPI, "/reference/api-message/"),
            (.eventAPI, "/reference/api-event/"),
            (.thingAPI, "/reference/api-thing/"),
            (.e2ee, "/reference/e2ee/"),
            (.selfHosting, "/guides/self-hosting/"),
        ]

        for (page, path) in pages {
            let english = AppConstants.documentationURL(page, locale: Locale(identifier: "en_US"))
            #expect(english.absoluteString == "https://pushgo.dev\(path)")
            #expect(english.scheme == "https")
            #expect(english.host == "pushgo.dev")

            let chinese = AppConstants.documentationURL(page, locale: Locale(identifier: "zh_Hans_CN"))
            #expect(chinese.absoluteString == "https://pushgo.dev/zh\(path)")
            #expect(chinese.scheme == "https")
            #expect(chinese.host == "pushgo.dev")
        }
    }
}
