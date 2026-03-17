//
//  CommandScheduler.swift
//  Biosense
//
//  Replaces nested DispatchQueue.main.asyncAfter chains with a declarative
//  command sequence. Each step has a delay and an action closure. The sequence
//  can be cancelled (e.g. when a workout starts mid-sync).
//

import Foundation

/// A cancellable sequence of delayed commands.
///
/// Usage:
/// ```
/// let scheduler = CommandScheduler()
/// scheduler.run([
///     .init(delay: 0.0) { self.syncSleep(dayOffset: 0) },
///     .init(delay: 0.6) { self.getHeartRateLog(dayOffset: 0) { _ in } },
///     .init(delay: 1.2) { self.getHeartRateLog(dayOffset: 1) { _ in } },
/// ], cancelIf: { self.isWorkoutActive })
/// ```
final class CommandScheduler {

    struct Step {
        /// Delay from the start of the sequence (absolute offset, not relative).
        let delay: TimeInterval
        /// Action to execute. Return `false` to skip remaining steps.
        let action: () -> Void

        init(delay: TimeInterval, action: @escaping () -> Void) {
            self.delay = delay
            self.action = action
        }
    }

    private var workItems: [DispatchWorkItem] = []

    /// Schedule a sequence of steps on the main queue.
    ///
    /// - Parameters:
    ///   - steps: Array of `Step` with absolute delay offsets and action closures.
    ///   - cancelIf: Optional predicate checked before each step. If it returns
    ///     `true`, the step (and all remaining) are skipped.
    func run(_ steps: [Step], cancelIf: (() -> Bool)? = nil) {
        cancel()  // Cancel any previously scheduled sequence.

        for step in steps {
            let item = DispatchWorkItem { [weak self] in
                guard self != nil else { return }
                if let cancelIf, cancelIf() { return }
                step.action()
            }
            workItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay, execute: item)
        }
    }

    /// Cancel all pending steps.
    func cancel() {
        for item in workItems {
            item.cancel()
        }
        workItems.removeAll()
    }

    deinit {
        cancel()
    }
}
