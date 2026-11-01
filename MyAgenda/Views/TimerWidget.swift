//
//  TimerWidget.swift
//  MyAgenda
//
//  A work-interval timer plus a floating, draggable Liquid Glass widget.
//

import SwiftUI
import UIKit
import UserNotifications
import ActivityKit
import AudioToolbox
import AVFoundation
import Observation

/// Presents the completion notification (with sound) even while the app is in
/// the foreground.
final class TimerNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TimerNotificationDelegate()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

final class TimerAlarmPlayer {
    static let shared = TimerAlarmPlayer()

    private var player: AVAudioPlayer?

    func play() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: Self.alarmData())
            player.numberOfLoops = 0
            player.volume = 1
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            AudioServicesPlaySystemSound(1005)
        }
    }

    /// A gentle iOS-notification-style tri-tone (marimba-like notes) rendered as
    /// PCM so it can play through AVAudioPlayer at the media volume.
    private static func alarmData() -> Data {
        let sampleRate = 44_100
        let duration = 1.1
        let sampleCount = Int(Double(sampleRate) * duration)
        var pcm = Data()
        pcm.reserveCapacity(sampleCount * 2)

        // Ascending three-note chime (G5, C6, E6), each a struck marimba note.
        let notes: [(freq: Double, start: Double)] = [
            (783.99, 0.00),
            (1046.50, 0.16),
            (1318.51, 0.32),
        ]

        for sample in 0..<sampleCount {
            let t = Double(sample) / Double(sampleRate)
            var value = 0.0
            for note in notes where t >= note.start {
                let local = t - note.start
                // Fast attack, exponential decay → a soft "ding".
                let attack = min(1, local / 0.006)
                let decay = exp(-local * 7.5)
                let fundamental = sin(2 * .pi * note.freq * local)
                let partial = sin(2 * .pi * note.freq * 4 * local) * 0.2 * exp(-local * 14)
                value += (fundamental + partial) * attack * decay * 0.7
            }
            let clamped = max(-1, min(1, value))
            var out = Int16(clamped * Double(Int16.max))
            withUnsafeBytes(of: &out) { pcm.append(contentsOf: $0) }
        }

        var data = Data()
        appendString("RIFF", to: &data)
        appendUInt32(UInt32(36 + pcm.count), to: &data)
        appendString("WAVEfmt ", to: &data)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        appendUInt32(UInt32(sampleRate * 2), to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        appendString("data", to: &data)
        appendUInt32(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private static func appendString(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

@Observable
final class WorkTimer {
    var durationMinutes: Int = 25
    var remaining: TimeInterval = 25 * 60
    var isRunning = false

    // Wall-clock target so the countdown stays accurate across lock/background.
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let notifID = "workTimer.finished"
    @ObservationIgnored private var activity: Activity<TimerActivityAttributes>?

    static let presets = [5, 10, 15, 25, 45, 60]

    var displayString: String {
        let s = max(0, Int(remaining.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var progress: Double {
        let total = Double(durationMinutes * 60)
        return total > 0 ? min(max(1 - remaining / total, 0), 1) : 0
    }

    func setMinutes(_ minutes: Int) {
        pause()
        durationMinutes = minutes
        remaining = TimeInterval(minutes * 60)
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        if remaining <= 0 { remaining = TimeInterval(durationMinutes * 60) }
        requestAuthorization()
        let end = Date().addingTimeInterval(remaining)
        endDate = end
        isRunning = true
        scheduleNotification(after: remaining)
        startLiveActivity(endDate: end)
        startTicker()
    }

    func pause() {
        if isRunning { remaining = max(0, endDate?.timeIntervalSinceNow ?? remaining) }
        isRunning = false
        endDate = nil
        ticker?.cancel(); ticker = nil
        cancelNotification()
        endLiveActivity()
    }

    func reset() {
        pause()
        remaining = TimeInterval(durationMinutes * 60)
    }

    /// Recompute remaining after returning from background / a locked screen.
    func refresh() {
        guard isRunning, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 { complete() }
    }

    // MARK: - Private

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                self.refresh()
                if !self.isRunning { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func complete() {
        isRunning = false
        endDate = nil
        ticker?.cancel(); ticker = nil
        remaining = 0
        cancelNotification()
        // Foreground: play a sound + haptic directly. (While locked/backgrounded
        // the scheduled local notification produces the sound.)
        TimerAlarmPlayer.shared.play()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        endLiveActivity()
    }

    // MARK: - Live Activity

    private func startLiveActivity(endDate: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endLiveActivity()
        let attributes = TimerActivityAttributes(durationMinutes: durationMinutes)
        let state = TimerActivityAttributes.ContentState(endDate: endDate, isRunning: true)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: endDate),
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    private func endLiveActivity() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleNotification(after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Timer terminat"
        content.body = "Intervalul de \(durationMinutes) min s-a încheiat."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: notifID, content: content, trigger: trigger)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notifID])
        center.add(request) { _ in }
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notifID])
    }
}

struct TimerWidget: View {
    @Bindable var timer: WorkTimer
    var onClose: () -> Void

    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: timer.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)

            Text(timer.displayString)
                .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        // Tap = play/pause, short press = options. One gesture, press first:
        // as two separate ones the tap held the press back well past its time.
        .gesture(
            LongPressGesture(minimumDuration: 0.25)
                .onEnded { _ in
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showOptions = true
                }
                .exclusively(before: TapGesture().onEnded { timer.toggle() })
        )
        .popover(isPresented: $showOptions) {
            TimerOptions(timer: timer, onClose: {
                showOptions = false
                onClose()
            })
        }
    }
}

private struct TimerOptions: View {
    @Bindable var timer: WorkTimer
    var onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 66), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Interval de lucru").font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WorkTimer.presets, id: \.self) { minutes in
                    let selected = timer.durationMinutes == minutes
                    Button {
                        timer.setMinutes(minutes)
                    } label: {
                        Text("\(minutes) min")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selected ? Color.accentColor : Color(.tertiarySystemFill),
                                        in: Capsule())
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Stepper(value: Binding(get: { timer.durationMinutes },
                                   set: { timer.setMinutes($0) }),
                    in: 1...180) {
                Text("Personalizat: \(timer.durationMinutes) min")
                    .font(.subheadline)
            }

            Divider()

            HStack {
                Button { timer.reset() } label: {
                    Label("Resetează", systemImage: "arrow.counterclockwise")
                }
                Spacer()
                Button(role: .destructive) { onClose() } label: {
                    Label("Închide", systemImage: "xmark")
                }
            }
            .font(.subheadline)
        }
        .padding(18)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }
}
