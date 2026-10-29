import Foundation

/// A one-shot timer the status item re-arms after every render, for the moment
/// the earliest countdown caption on screen changes text. A countdown therefore
/// costs one wake-up a minute while it is shown and none otherwise, and the
/// callback reads the clock itself, so a late fire (sleep, a stalled run loop)
/// repairs itself on the next render.
@MainActor
final class CountdownTicker {
    /// Past the boundary, so the callback never lands a hair early and finds
    /// the caption unchanged.
    static let settle: TimeInterval = 0.1
    static let tolerance: TimeInterval = 0.5

    private let onTick: () -> Void
    private var timer: Timer?

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    /// Fires once at `date`, replacing any fire still pending; nil stops it.
    func arm(at date: Date?) {
        timer?.invalidate()
        timer = nil
        guard let date else { return }
        let timer = Timer(fire: date.addingTimeInterval(Self.settle), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        timer.tolerance = Self.tolerance
        // Common modes, so the caption keeps counting while a menu tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        arm(at: nil)
    }

    var isArmed: Bool { timer?.isValid ?? false }
}
