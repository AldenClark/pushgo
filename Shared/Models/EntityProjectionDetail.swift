import Foundation

struct EntityProjectionDetail: Sendable {
    let head: PushMessage?
    let history: [PushMessage]

    var messages: [PushMessage] {
        guard let head else {
            return history
        }
        return ([head] + history.filter { $0.id != head.id }).sorted {
            if $0.receivedAt == $1.receivedAt {
                return $0.id.uuidString > $1.id.uuidString
            }
            return $0.receivedAt > $1.receivedAt
        }
    }
}
