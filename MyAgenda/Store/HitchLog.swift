//
//  HitchLog.swift
//  MyAgenda
//
//  Debug only. Every turn of the main run loop that took longer than a few
//  frames is printed in the Xcode console, with the memory footprint, so a
//  lag felt on the iPad can be matched with what the app was doing then:
//  SyncLog prints the iCloud steps next to it, and the pen's own work shows
//  as the hitches between them.
//

import Foundation
import QuartzCore

enum HitchLog {
    /// Milliseconds a run loop turn may take before it is reported.
    private static let threshold: Double = 30

    static func start() {
        #if DEBUG
        var began: CFAbsoluteTime = 0
        // After CoreAnimation's own commit observer (order 2 000 000), so the
        // layout and drawing of the frame count in the turn.
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 3_000_000) { _, activity in
            if activity == .afterWaiting {
                began = CFAbsoluteTimeGetCurrent()
            } else if began > 0 {
                let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
                began = 0
                if ms > threshold {
                    print(String(format: "⏱ Blocaj: %.0f ms pe firul principal, memorie %.0f MB", ms, footprintMB()))
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            print(String(format: "⏱ Memorie: %.0f MB", footprintMB()))
        }
        #endif
    }

    /// Runs `body` and, in Debug, reports it when it took longer than a few
    /// milliseconds: the pen's hot spots are wrapped in it, so a hitch can be
    /// put on the operation that caused it.
    @discardableResult
    static func measure<T>(_ label: @autoclosure () -> String, over: Double = 5, _ body: () -> T) -> T {
        #if DEBUG
        let began = CFAbsoluteTimeGetCurrent()
        let result = body()
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        if ms > over { print(String(format: "⏱ %@: %.1f ms", label(), ms)) }
        return result
        #else
        return body()
        #endif
    }

    /// A note in the same log, Debug only.
    static func note(_ text: @autoclosure () -> String) {
        #if DEBUG
        print("⏱ " + text())
        #endif
    }

    /// The app's physical footprint, what the system judges it by.
    private nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
