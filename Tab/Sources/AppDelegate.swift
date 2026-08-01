import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchConfiguration = TabLaunchConfiguration(
        arguments: ProcessInfo.processInfo.arguments
    )
    private var panelController: NotchPanelController?
    private var currentExpression: TabExpression = .neutral
    private var expressionDemoTimer: Timer?
    private var screenContextLogController: ScreenContextLogWindowController?
    private var screenContextCoordinator: ScreenContextCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenConfigurationChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        currentExpression = launchConfiguration.initialExpression
        refreshPlacement()
        panelController?.setExpression(currentExpression, animated: false)

        if launchConfiguration.cyclesExpressions {
            startExpressionDemo()
        }
        if launchConfiguration.showsScreenContextLog {
            showScreenContextLog()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.hide()
        expressionDemoTimer?.invalidate()
        screenContextCoordinator?.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func screenConfigurationChanged(_ notification: Notification) {
        refreshPlacement()
    }

    private func refreshPlacement() {
        guard let placement = NotchLayout.placement(in: NSScreen.screens) else {
            panelController?.hide()
            return
        }

        if panelController == nil {
            panelController = NotchPanelController(frame: placement.panelFrame)
            panelController?.onExpressionChange = { [weak self] expression in
                self?.currentExpression = expression
            }
            panelController?.setExpression(currentExpression, animated: false)
        }
        panelController?.show(at: placement.panelFrame)
    }

    private func startExpressionDemo() {
        let timer = Timer(timeInterval: 2.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.currentExpression = self.currentExpression.next
            self.panelController?.setExpression(self.currentExpression, animated: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        expressionDemoTimer = timer
    }

    private func showScreenContextLog() {
        let logController = ScreenContextLogWindowController()
        let coordinator = ScreenContextCoordinator(logWindow: logController)
        logController.onCaptureToggle = { [weak coordinator] shouldCapture in
            if shouldCapture {
                coordinator?.start()
            } else {
                coordinator?.stop()
            }
        }
        logController.onLunaConfigurationChange = { [weak coordinator] apiKey in
            coordinator?.configureLuna(apiKey: apiKey)
        }
        logController.onFocusGoalChange = { [weak coordinator] goal in
            coordinator?.configureFocusGoal(goal)
        }
        logController.onClose = { [weak coordinator] in
            coordinator?.stop()
        }
        screenContextLogController = logController
        screenContextCoordinator = coordinator
        logController.showBesideMainScreen()
    }
}
