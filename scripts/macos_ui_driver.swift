#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private enum DriverError: Error, CustomStringConvertible {
    case usage(String)
    case timeout(String)
    case accessibility(String)

    var description: String {
        switch self {
        case let .usage(message), let .timeout(message), let .accessibility(message):
            return message
        }
    }
}

private struct ElementSnapshot: Encodable {
    let role: String
    let identifier: String
    let title: String
    let value: String
}

private func attribute(_ name: CFString, of element: AXUIElement) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

private func stringAttribute(_ name: CFString, of element: AXUIElement) -> String {
    attribute(name, of: element) as? String ?? ""
}

private func elementAttribute(_ name: CFString, of element: AXUIElement) -> AXUIElement? {
    guard let value = attribute(name, of: element),
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func valueAttribute(_ name: CFString, of element: AXUIElement) -> AXValue? {
    guard let value = attribute(name, of: element),
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    return unsafeBitCast(value, to: AXValue.self)
}

private func children(of element: AXUIElement) -> [AXUIElement] {
    attribute(kAXChildrenAttribute as CFString, of: element) as? [AXUIElement] ?? []
}

private func descendants(of root: AXUIElement, limit: Int = 8_000) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue = children(of: root)
    while !queue.isEmpty && result.count < limit {
        let element = queue.removeFirst()
        result.append(element)
        queue.append(contentsOf: children(of: element))
    }
    return result
}

private func applications(bundleIdentifier: String) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { !$0.isTerminated }
}

private func appElement(bundleIdentifier: String) -> AXUIElement? {
    guard let app = applications(bundleIdentifier: bundleIdentifier).first else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}

private func element(
    bundleIdentifier: String,
    matching predicate: (AXUIElement) -> Bool
) -> AXUIElement? {
    guard let root = appElement(bundleIdentifier: bundleIdentifier) else { return nil }
    return descendants(of: root).first(where: predicate)
}

private func wait(
    timeout: TimeInterval,
    poll: TimeInterval = 0.15,
    operation: () throws -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if try operation() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(poll))
    } while Date() < deadline
    throw DriverError.timeout("timed out after \(timeout) seconds")
}

private func press(_ element: AXUIElement) -> Bool {
    if
        let positionValue = valueAttribute(kAXPositionAttribute as CFString, of: element),
        let sizeValue = valueAttribute(kAXSizeAttribute as CFString, of: element)
    {
        var position = CGPoint.zero
        var size = CGSize.zero
        if AXValueGetValue(positionValue, .cgPoint, &position),
           AXValueGetValue(sizeValue, .cgSize, &size),
           size.width > 0,
           size.height > 0 {
            let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
            if
                let down = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseDown,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ),
                let up = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseUp,
                    mouseCursorPosition: point,
                    mouseButton: .left
                )
            {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                return true
            }
        }
    }

    var candidate: AXUIElement? = element
    for _ in 0..<5 {
        guard let current = candidate else { break }
        if AXUIElementPerformAction(current, kAXPressAction as CFString) == .success { return true }
        candidate = elementAttribute(kAXParentAttribute as CFString, of: current)
    }
    return false
}

private func valueMatches(_ element: AXUIElement, candidates: Set<String>) -> Bool {
    let values = [
        stringAttribute(kAXTitleAttribute as CFString, of: element),
        stringAttribute(kAXDescriptionAttribute as CFString, of: element),
        stringAttribute(kAXValueAttribute as CFString, of: element),
    ]
    return values.contains(where: candidates.contains)
}

private func requireArguments(_ count: Int, _ usage: String) throws {
    guard CommandLine.arguments.count == count else { throw DriverError.usage(usage) }
}

private func snapshots(bundleIdentifier: String) -> [ElementSnapshot] {
    guard let root = appElement(bundleIdentifier: bundleIdentifier) else { return [] }
    return descendants(of: root).compactMap { element in
        let snapshot = ElementSnapshot(
            role: stringAttribute(kAXRoleAttribute as CFString, of: element),
            identifier: stringAttribute(kAXIdentifierAttribute as CFString, of: element),
            title: stringAttribute(kAXTitleAttribute as CFString, of: element),
            value: stringAttribute(kAXValueAttribute as CFString, of: element)
        )
        return snapshot.identifier.isEmpty && snapshot.title.isEmpty && snapshot.value.isEmpty
            ? nil
            : snapshot
    }
}

private func run() throws {
    guard CommandLine.arguments.count >= 2 else {
        throw DriverError.usage("usage: macos_ui_driver.swift <command> ...")
    }
    let command = CommandLine.arguments[1]
    switch command {
    case "count":
        try requireArguments(3, "count <bundle-id>")
        print(applications(bundleIdentifier: CommandLine.arguments[2]).count)

    case "terminate":
        try requireArguments(3, "terminate <bundle-id>")
        for app in applications(bundleIdentifier: CommandLine.arguments[2]) { _ = app.terminate() }

    case "wait-identifier":
        try requireArguments(5, "wait-identifier <bundle-id> <identifier> <timeout>")
        let bundleID = CommandLine.arguments[2]
        let identifier = CommandLine.arguments[3]
        let timeout = TimeInterval(CommandLine.arguments[4]) ?? 0
        do {
            try wait(timeout: timeout) {
                element(bundleIdentifier: bundleID) {
                    stringAttribute(kAXIdentifierAttribute as CFString, of: $0) == identifier
                } != nil
            }
        } catch {
            throw DriverError.timeout("identifier \(identifier) did not appear: \(error)")
        }

    case "wait-text":
        try requireArguments(5, "wait-text <bundle-id> <exact-text> <timeout>")
        let bundleID = CommandLine.arguments[2]
        let text = CommandLine.arguments[3]
        let timeout = TimeInterval(CommandLine.arguments[4]) ?? 0
        do {
            try wait(timeout: timeout) {
                element(bundleIdentifier: bundleID) { valueMatches($0, candidates: [text]) } != nil
            }
        } catch {
            throw DriverError.timeout("text \(text) did not appear: \(error)")
        }

    case "click-identifier":
        try requireArguments(5, "click-identifier <bundle-id> <identifier> <timeout>")
        let bundleID = CommandLine.arguments[2]
        let identifier = CommandLine.arguments[3]
        let timeout = TimeInterval(CommandLine.arguments[4]) ?? 0
        try wait(timeout: timeout) {
            guard let target = element(bundleIdentifier: bundleID, matching: {
                stringAttribute(kAXIdentifierAttribute as CFString, of: $0) == identifier
            }) else { return false }
            return press(target)
        }

    case "click-title":
        guard CommandLine.arguments.count >= 5 else {
            throw DriverError.usage("click-title <bundle-id> <timeout> <title> [title ...]")
        }
        let bundleID = CommandLine.arguments[2]
        let timeout = TimeInterval(CommandLine.arguments[3]) ?? 0
        let titles = Set(CommandLine.arguments.dropFirst(4))
        var pressedTitle = ""
        try wait(timeout: timeout) {
            guard let target = element(bundleIdentifier: bundleID, matching: {
                stringAttribute(kAXRoleAttribute as CFString, of: $0) == (kAXButtonRole as String)
                    && valueMatches($0, candidates: titles)
            }) else { return false }
            guard press(target) else { return false }
            pressedTitle = [
                stringAttribute(kAXTitleAttribute as CFString, of: target),
                stringAttribute(kAXDescriptionAttribute as CFString, of: target),
                stringAttribute(kAXValueAttribute as CFString, of: target),
            ].first(where: titles.contains) ?? "matched"
            return true
        }
        print(pressedTitle)

    case "wait-installed-relaunch":
        try requireArguments(
            7,
            "wait-installed-relaunch <bundle-id> <app-path> <expected-version> <old-pid> <timeout>"
        )
        let bundleID = CommandLine.arguments[2]
        let appPath = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
        let expectedVersion = CommandLine.arguments[4]
        let oldPID = pid_t(CommandLine.arguments[5]) ?? 0
        let timeout = TimeInterval(CommandLine.arguments[6]) ?? 0
        var newPID: pid_t = 0
        try wait(timeout: timeout, poll: 0.2) {
            if let relaunch = element(bundleIdentifier: bundleID, matching: {
                stringAttribute(kAXRoleAttribute as CFString, of: $0) == (kAXButtonRole as String)
                    && valueMatches(
                        $0,
                        candidates: ["Install and Relaunch", "安装并重新启动", "安裝並重新啟動"]
                    )
            }) {
                _ = press(relaunch)
            }
            let infoURL = appPath.appendingPathComponent("Contents/Info.plist")
            guard
                let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
                info["CFBundleShortVersionString"] as? String == expectedVersion
            else { return false }
            guard let app = applications(bundleIdentifier: bundleID).first(where: {
                $0.processIdentifier != oldPID && $0.bundleURL?.standardizedFileURL == appPath
            }) else { return false }
            newPID = app.processIdentifier
            return true
        }
        print(newPID)

    case "dump":
        try requireArguments(3, "dump <bundle-id>")
        let data = try JSONEncoder().encode(snapshots(bundleIdentifier: CommandLine.arguments[2]))
        print(String(decoding: data, as: UTF8.self))

    default:
        throw DriverError.usage("unsupported command: \(command)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("macos_ui_driver: \(error)\n".utf8))
    exit(1)
}
