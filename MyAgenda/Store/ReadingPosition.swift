//
//  ReadingPosition.swift
//  MyAgenda
//
//  Where you left off: the open notebook, and the last page in each notebook.
//  Kept in iCloud key-value storage (so another device opens at the same
//  place) and mirrored locally (so it works offline / signed out).
//
//  Following another device is limited to the first moments after the app
//  becomes active, before you have moved yourself — the other device never
//  pulls the page out from under you while you are writing. For the same
//  reason, what this device shows right at activation is not written back
//  until that window has passed, so a fresh launch can't overwrite the
//  position just left on the other device.
//

import Foundation
import Observation

@Observable
final class ReadingPosition {
    static let shared = ReadingPosition()

    /// Bumped when another device's position should be followed.
    private(set) var remoteJump = 0

    @ObservationIgnored private let cloud = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private let local = UserDefaults.standard
    @ObservationIgnored private var activatedAt = Date.now
    @ObservationIgnored private var movedSinceActivation = false
    @ObservationIgnored private var deferred: [String: String] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// How long after activation another device's position is still followed.
    private static let followWindow: TimeInterval = 20
    /// Saves this soon after activation are held back (see the header).
    private static let settleWindow: TimeInterval = 4

    private enum Key {
        static let notebook = "position.notebook"
        static let at = "position.at"
        static func page(_ notebook: UUID) -> String { "position.page.\(notebook.uuidString)" }
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloudChanged() }
        }
        cloud.synchronize()
    }

    // MARK: Reading

    var notebookID: UUID? { uuid(Key.notebook) }

    func pageID(in notebook: UUID) -> UUID? { uuid(Key.page(notebook)) }

    /// Whichever copy was written last wins.
    private func uuid(_ key: String) -> UUID? {
        let cloudIsNewer = cloud.double(forKey: Key.at) >= local.double(forKey: Key.at)
        let raw = cloudIsNewer
            ? (cloud.string(forKey: key) ?? local.string(forKey: key))
            : (local.string(forKey: key) ?? cloud.string(forKey: key))
        return raw.flatMap(UUID.init(uuidString:))
    }

    // MARK: Writing

    func saveNotebook(_ id: UUID) { save([Key.notebook: id.uuidString]) }

    func savePage(_ page: UUID, in notebook: UUID) {
        save([Key.notebook: notebook.uuidString, Key.page(notebook): page.uuidString])
    }

    private func save(_ values: [String: String]) {
        // Nothing new: e.g. the page restored at launch.
        guard values.contains(where: { uuid($0.key)?.uuidString != $0.value }) else { return }
        if Date.now.timeIntervalSince(activatedAt) < Self.settleWindow {
            deferred.merge(values) { _, new in new }
            scheduleFlush()
            return
        }
        movedSinceActivation = true
        write(values)
    }

    private func write(_ values: [String: String]) {
        let now = Date.now.timeIntervalSince1970
        for (key, value) in values {
            cloud.set(value, forKey: key)
            local.set(value, forKey: key)
        }
        cloud.set(now, forKey: Key.at)
        local.set(now, forKey: Key.at)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let delay = max(0, Self.settleWindow - Date.now.timeIntervalSince(activatedAt))
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.deferred.isEmpty else { return }
            let values = self.deferred
            self.deferred = [:]
            self.write(values)
        }
    }

    // MARK: Lifecycle

    func becameActive() {
        activatedAt = .now
        movedSinceActivation = false
        cloud.synchronize()
    }

    private func cloudChanged() {
        guard !movedSinceActivation,
              Date.now.timeIntervalSince(activatedAt) < Self.followWindow else { return }
        // The other device's position replaces whatever this one would have
        // written back at launch.
        deferred = [:]
        flushTask?.cancel()
        local.set(cloud.double(forKey: Key.at), forKey: Key.at)
        remoteJump += 1
    }
}
