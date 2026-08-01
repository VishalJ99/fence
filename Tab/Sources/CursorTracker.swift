import AppKit

final class CursorTracker {
    private weak var eyesView: EyesView?
    private let metrics: EyeMetrics
    private var timer: Timer?
    private var lastSampleTime: TimeInterval?
    private var smoother = ExponentialPointSmoother()

    init(eyesView: EyesView, metrics: EyeMetrics = .compact) {
        self.eyesView = eyesView
        self.metrics = metrics
    }

    deinit {
        stop()
    }

    func start() {
        guard timer == nil else { return }
        sampleCursor()

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.sampleCursor()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSampleTime = nil
        smoother.reset()
    }

    private func sampleCursor() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastSampleTime.map { now - $0 } ?? 0
        lastSampleTime = now

        let location = smoother.update(
            target: NSEvent.mouseLocation,
            deltaTime: elapsed,
            timeConstant: metrics.smoothingTimeConstant
        )
        eyesView?.cursorLocation = location
    }
}
