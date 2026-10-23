#!/usr/bin/env python3
"""Run the actual Watch SQLite class on the host, not the GRDB counterpart.

No product storage code is copied or translated: marked declaration ranges are
read from source and compiled verbatim with production models. Only the Watch
sandbox path and Darwin posting are replaced.
This is production-SQLite host evidence, not watchOS/APNs or GUI acceptance.
"""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


def between(source: str, start: str, end: str) -> str:
    if source.count(start) != 1:
        raise ValueError(f"production source boundary changed: {start!r}")
    tail = source.split(start, 1)[1]
    if end not in tail:
        raise ValueError(f"production source boundary changed: {end!r}")
    return tail.split(end, 1)[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-ref", help="read production source from a fixed Git revision for a negative control")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    def read(relative: str) -> str:
        if args.source_ref:
            return subprocess.check_output(["git", "show", f"{args.source_ref}:{relative}"], cwd=repo, text=True)
        return (repo / relative).read_text()

    watch = read("Apps/PushGo-watchOS/LocalDataStore.swift")
    marker = "private final class WatchLocalSQLiteStore {"
    if watch.count(marker) != 1 or not watch.rstrip().endswith("#endif"):
        raise ValueError("Watch SQLite class or outer platform guard changed")
    store = marker + watch.split(marker, 1)[1].rsplit("\n#endif", 1)[0]
    metadata = "struct WatchProvisioningState:" + between(
        watch, "struct WatchProvisioningState:", "\nstruct EntityOpenTarget:"
    )
    models = read("Shared/Models/WatchLightModels.swift").split("\nstruct WatchControlContext:", 1)[0]
    payload = "enum WatchLightPayload:" + between(
        read("Shared/Utilities/WatchLightQuantizer.swift"), "enum WatchLightPayload:", "\nprivate struct WatchLightProfile"
    )
    equality = "extension WatchLightMessage {" + between(
        read("Apps/PushGo-watchOS/WatchLightStoreViewModel.swift"), "extension WatchLightMessage {", "\n}\n"
    ) + "\n}\n"
    freshness = "enum WatchNotificationFreshness {" + between(
        read("Shared/Utilities/WatchNotificationFreshness.swift"),
        "enum WatchNotificationFreshness {", "    static func configuredMinutes"
    ) + "\n}\n"
    support = r'''
import Foundation
import SQLite3
private let watchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum AppConstants {
    static let appGroupIdentifier = "watch-host-lifecycle"
    static let databaseStoreFilename = "watch.sqlite"
    static let messageSyncNotificationName = "watch-host-noop-notification"
    static let defaultServerURL: URL? = nil
    static func appLocalDatabaseDirectory(fileManager: FileManager, appGroupIdentifier: String) throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WATCH_SQLITE_TEST_ROOT"]!)
        let directory = root.appendingPathComponent(appGroupIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
private enum DarwinNotificationPoster { static func post(name: String) {} }
'''
    fixture = (repo / "Tests/Fixtures/watch_sqlite_lifecycle.swift").read_text()
    compilation = "\n".join([support, read("Shared/Models/ServerConfig.swift"), models, payload, metadata, equality, freshness, store, fixture])
    source = output / "watch_sqlite_lifecycle.swift"
    source.write_text(compilation)
    executable = output / "watch_sqlite_lifecycle"
    print(f"production_source_ref={args.source_ref or 'working-tree'}", flush=True)
    print(f"watch_sqlite_class_sha256={hashlib.sha256(store.encode()).hexdigest()}", flush=True)
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors", str(source), "-o", str(executable)]
    print("compile_command=" + " ".join(command), flush=True)
    subprocess.run(command, check=True, cwd=repo)
    with tempfile.TemporaryDirectory(prefix="pushgo-watch-sqlite-") as root:
        subprocess.run([str(executable)], check=True, env={**os.environ, "WATCH_SQLITE_TEST_ROOT": root})


if __name__ == "__main__":
    main()
