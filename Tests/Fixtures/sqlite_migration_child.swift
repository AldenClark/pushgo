import Darwin
import Foundation
@testable import PushGoAppleCore

private final class BarrierFileManager: FileManager, @unchecked Sendable {
    let role: String
    let targetMain: URL
    let firstSourceMain: URL
    let controlDirectory: URL
    private var pausedAtTarget = false

    init(role: String, targetMain: URL, firstSourceMain: URL, controlDirectory: URL) {
        self.role = role
        self.targetMain = targetMain
        self.firstSourceMain = firstSourceMain
        self.controlDirectory = controlDirectory
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        let exists = super.fileExists(atPath: path)
        if (role == "first" || role == "second"),
           !pausedAtTarget, path == targetMain.path, !exists
        {
            pausedAtTarget = true
            signal("\(role)-target-absent")
            waitFor("release-\(role)-target")
        }
        return exists
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try super.moveItem(at: sourceURL, to: destinationURL)
        if role == "first", sourceURL == firstSourceMain, destinationURL == targetMain {
            signal("first-main-moved")
            waitFor("release-first-main")
        }
    }

    private func signal(_ name: String) {
        let url = controlDirectory.appendingPathComponent(name)
        do {
            try Data().write(to: url)
        } catch {
            fatalError("migration fixture could not signal \(name): \(error)")
        }
    }

    private func waitFor(_ name: String) {
        let url = controlDirectory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(25)
        while !super.fileExists(atPath: url.path) {
            if name == "release-first-main", role == "first",
               super.fileExists(atPath: controlDirectory.appendingPathComponent("kill-first-main").path)
            {
                _ = Darwin.kill(Darwin.getpid(), SIGKILL)
            }
            if Date() >= deadline {
                fatalError("migration fixture timed out waiting for \(name)")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

@main
private enum MigrationChild {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { Darwin._exit(31) }
        if arguments[1] == "probe-lock" {
            let descriptor = Darwin.open(arguments[2], O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { Darwin._exit(32) }
            defer { Darwin.close(descriptor) }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                _ = flock(descriptor, LOCK_UN)
                Darwin._exit(0)
            }
            Darwin._exit(errno == EWOULDBLOCK ? 20 : 33)
        }

        guard arguments[1] == "migrate", arguments.count == 7 else { Darwin._exit(34) }
        let role = arguments[2]
        let group = arguments[3]
        let targetMain = URL(fileURLWithPath: arguments[4])
        let firstSourceMain = URL(fileURLWithPath: arguments[5])
        let controlDirectory = URL(fileURLWithPath: arguments[6], isDirectory: true)
        let manager = BarrierFileManager(
            role: role,
            targetMain: targetMain,
            firstSourceMain: firstSourceMain,
            controlDirectory: controlDirectory
        )
        do {
            try Data(String(Darwin.getpid()).utf8)
                .write(to: controlDirectory.appendingPathComponent("\(role)-started"))
            _ = try AppConstants.appLocalDatabaseDirectory(
                fileManager: manager,
                appGroupIdentifier: group
            )
            try Data().write(to: controlDirectory.appendingPathComponent("\(role)-done"))
        } catch {
            let text = String(describing: error)
            try? Data(text.utf8).write(to: controlDirectory.appendingPathComponent("\(role)-error"))
            Darwin._exit(35)
        }
    }
}
