//
//  MyAgendaApp.swift
//  MyAgenda
//

import SwiftUI
import SwiftData
import UserNotifications
import UIKit

@main
struct MyAgendaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    init() {
        UNUserNotificationCenter.current().delegate = TimerNotificationDelegate.shared
        SyncLog.start()
        HitchLog.start()

        let schema = Schema([Notebook.self, JournalPage.self, TextBox.self, ImageBox.self, ChecklistBox.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        TestInkCleanup.runOnce(in: container.mainContext)
        // Listening before the first keyboard: a text view announces the
        // keyboard before it says it started editing.
        _ = PhoneKeyboardScroll.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}

/// Registers for silent CloudKit pushes so remote changes sync in near real
/// time (the underlying NSPersistentCloudKitContainer imports on push), instead
/// of only when the app returns to the foreground.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("☁️ Registered for remote notifications (APNs token received)")
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // SwiftData/CloudKit imports the change automatically once the push
        // arrives; report new data so iOS keeps delivering pushes promptly.
        print("☁️ Remote notification received (CloudKit push)")
        completionHandler(.newData)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Non-fatal (e.g. a simulator without APNs) — foreground sync still works.
        print("☁️ Failed to register for remote notifications: \(error.localizedDescription)")
    }
}
