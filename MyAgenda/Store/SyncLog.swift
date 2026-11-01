//
//  SyncLog.swift
//  MyAgenda
//
//  What iCloud sync really does, in the Xcode console: every step (setup,
//  sending, receiving) when it starts and ends, a warning when one runs for
//  too long, the actual error when one fails, and what was saved locally.
//  Silent failures are what this exists for: a rejected or stuck step otherwise
//  leaves no trace, and the devices just stop agreeing.
//

import CloudKit
import CoreData
import Foundation
import os

enum SyncLog {
    private nonisolated static let containerID = "iCloud.GrowthCompany.MyAgenda"
    /// Steps that started and have not ended yet.
    private nonisolated static let running = OSAllocatedUnfairLock(initialState: Set<UUID>())
    /// Seconds after which a step still running is reported.
    private nonisolated static let stuckChecks: [Double] = [30, 60, 120, 300]

    /// A local save, which is what makes an export necessary.
    nonisolated static func saved(_ what: String, bytes: Int) {
        print("☁️ Sync: salvat local \(what), \(bytes / 1024) KB")
    }

    /// Call once, before the model container is created.
    nonisolated static func start() {
        #if DEBUG
        print("☁️ Sync: build Debug, mediu CloudKit Development")
        #else
        print("☁️ Sync: build Release, mediu CloudKit Production")
        #endif

        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: nil
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            log(event)
        }

        CKContainer(identifier: containerID).accountStatus { status, error in
            print("☁️ Sync: cont iCloud \(describe(status))\(error.map { " (\($0.localizedDescription))" } ?? "")")
        }
    }

    private nonisolated static func log(_ event: NSPersistentCloudKitContainer.Event) {
        guard let end = event.endDate else {
            print("☁️ Sync: \(name(of: event.type)) pornită")
            watch(event)
            return
        }
        _ = running.withLock { $0.remove(event.identifier) }
        let seconds = String(format: "%.1f", end.timeIntervalSince(event.startDate))
        if event.succeeded {
            print("☁️ Sync: \(name(of: event.type)) reușită, \(seconds) s")
            return
        }
        print("☁️ Sync: \(name(of: event.type)) EȘUATĂ, \(seconds) s")
        if let error = event.error { report(error) }
    }

    /// Reports the step if it is still running later on: a step that hangs
    /// blocks everything queued behind it, and never logs an end.
    private nonisolated static func watch(_ event: NSPersistentCloudKitContainer.Event) {
        let id = event.identifier
        let label = name(of: event.type)
        _ = running.withLock { $0.insert(id) }
        for delay in stuckChecks {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                if running.withLock({ $0.contains(id) }) {
                    print("☁️ Sync: ATENȚIE \(label) rulează de \(Int(delay)) s")
                }
            }
        }
    }

    private nonisolated static func report(_ error: Error) {
        let nsError = error as NSError
        print("☁️ Sync:   eroare \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
        if let hint = hint(for: nsError) { print("☁️ Sync:   \(hint)") }

        // A batch fails as one error holding one error per record.
        guard let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else { return }
        print("☁️ Sync:   \(partial.count) înregistrări afectate; primele:")
        for (item, itemError) in partial.prefix(5) {
            let inner = itemError as NSError
            print("☁️ Sync:   - \(item): \(inner.code) \(inner.localizedDescription)")
            if let hint = hint(for: inner) { print("☁️ Sync:     \(hint)") }
        }
    }

    private nonisolated static func hint(for error: NSError) -> String? {
        // Core Data's "no iCloud account" (NSCloudKitMirroring).
        if error.domain == NSCocoaErrorDomain, error.code == 134400 {
            return "Dispozitivul nu e autentificat în iCloud; nu se sincronizează nimic."
        }
        guard error.domain == CKErrorDomain, let code = CKError.Code(rawValue: error.code) else { return nil }
        switch code {
        case .notAuthenticated:
            return "Dispozitivul nu e autentificat în iCloud."
        case .quotaExceeded:
            return "Spațiul iCloud e plin."
        case .networkUnavailable, .networkFailure:
            return "Problemă de rețea; se reia singur."
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            return "iCloud a cerut o pauză; se reia singur."
        case .invalidArguments, .serverRejectedRequest:
            return "Posibil schemă CloudKit nepublicată pentru câmpurile noi."
        case .changeTokenExpired, .userDeletedZone, .zoneNotFound:
            return "Datele din iCloud s-au schimbat; se resincronizează tot."
        default:
            return nil
        }
    }

    private nonisolated static func name(of type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: return "pregătire"
        case .import: return "primire"
        case .export: return "trimitere"
        @unknown default: return "pas necunoscut"
        }
    }

    private nonisolated static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "disponibil"
        case .noAccount: return "lipsă: nu e autentificat"
        case .restricted: return "restricționat"
        case .temporarilyUnavailable: return "temporar indisponibil"
        case .couldNotDetermine: return "nedeterminat"
        @unknown default: return "necunoscut"
        }
    }
}
