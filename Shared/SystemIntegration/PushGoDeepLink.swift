import Foundation

enum PushGoDeepLink {
    static let scheme = "pushgo"

    static func makeURL(target: PushGoSystemOpenTarget) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "kind", value: target.kind.rawValue),
            URLQueryItem(name: "id", value: target.identifier),
        ]
        return components.url
    }

    static func parse(_ url: URL, source: PushGoSystemOpenTarget.Source = .deepLink) -> PushGoSystemOpenTarget? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == "open"
        else {
            return nil
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }
        )
        guard let kind = PushGoSystemEntityKind(normalizedRawValue: query["kind"]),
              let id = query["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else {
            return nil
        }
        if id == "list" {
            return PushGoSystemOpenTarget.list(kind: kind, source: source)
        }
        return PushGoSystemOpenTarget(kind: kind, identifier: id, source: source)
    }
}
