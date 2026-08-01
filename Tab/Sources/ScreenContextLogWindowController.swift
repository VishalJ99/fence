import AppKit

final class ScreenContextLogWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let statusLabel = NSTextField(labelWithString: "Capture is off")
    private let privacyLabel = NSTextField(
        wrappingLabelWithString: "Capture and OCR processing stay local. While Luna is on, Tab sends bounded app/window metadata and recognized text first, then a low-detail image only when needed."
    )
    private let startButton = NSButton(title: "Start screen context", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let focusGoalField = NSTextField()
    private let keyField = NSSecureTextField()
    private let lunaSwitch = NSSwitch()
    private let lunaLabel = NSTextField(labelWithString: "Use Luna for changed context")
    private let textView = NSTextView()
    private var captureIsRunning = false

    var onCaptureToggle: ((Bool) -> Void)?
    var onLunaConfigurationChange: ((String?) -> Void)?
    var onFocusGoalChange: ((String?) -> Void)?
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tab — Live Screen Context"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 390, height: 420)
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showBesideMainScreen() {
        guard let window else { return }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            window.setFrameOrigin(
                CGPoint(
                    x: visible.maxX - window.frame.width - 18,
                    y: visible.maxY - window.frame.height - 18
                )
            )
        }
        showWindow(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func setStatus(_ message: String) {
        performOnMain { [weak self] in
            self?.statusLabel.stringValue = message
        }
    }

    func setCaptureRunning(_ running: Bool) {
        performOnMain { [weak self] in
            guard let self else { return }
            captureIsRunning = running
            startButton.title = running ? "Stop screen context" : "Start screen context"
        }
    }

    func append(_ message: String) {
        performOnMain { [weak self] in
            guard let self else { return }
            let existing = textView.string
            let combined = existing.isEmpty ? message : "\(existing)\n\n\(message)"
            textView.string = String(combined.suffix(40_000))
            textView.scrollToEndOfDocument(nil)
        }
    }

    func clearCredential() {
        performOnMain { [weak self] in
            guard let self else { return }
            keyField.stringValue = ""
            lunaSwitch.state = .off
            updateLunaControlState()
            onLunaConfigurationChange?(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        captureIsRunning = false
        keyField.stringValue = ""
        focusGoalField.stringValue = ""
        lunaSwitch.state = .off
        onLunaConfigurationChange?(nil)
        onFocusGoalChange?(nil)
        onClose?()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === keyField {
            updateLunaControlState()
            publishLunaConfiguration()
        } else if field === focusGoalField {
            publishFocusGoal()
        }
    }

    private func configureContent(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Live screen context")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        privacyLabel.font = .systemFont(ofSize: 12)
        privacyLabel.textColor = .secondaryLabelColor
        privacyLabel.maximumNumberOfLines = 3

        startButton.target = self
        startButton.action = #selector(toggleCapture(_:))
        startButton.bezelStyle = .rounded

        clearButton.target = self
        clearButton.action = #selector(clearLog(_:))
        clearButton.bezelStyle = .rounded

        focusGoalField.placeholderString = "Current focus goal — optional"
        focusGoalField.delegate = self
        focusGoalField.setAccessibilityLabel("Current focus goal")

        keyField.placeholderString = "OpenRouter key — optional, memory only"
        keyField.delegate = self
        keyField.setAccessibilityLabel("OpenRouter API key")

        lunaSwitch.target = self
        lunaSwitch.action = #selector(toggleLuna(_:))
        lunaSwitch.state = .off
        lunaSwitch.isEnabled = false
        lunaLabel.textColor = .secondaryLabelColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = CGSize(width: 10, height: 10)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.string = "Ready. Start screen context to request Tab's Screen Recording permission."

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        let buttonRow = NSStackView(views: [startButton, clearButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let lunaRow = NSStackView(views: [lunaSwitch, lunaLabel])
        lunaRow.orientation = .horizontal
        lunaRow.spacing = 8
        lunaRow.alignment = .centerY

        let stack = NSStackView(views: [
            titleLabel,
            statusLabel,
            privacyLabel,
            buttonRow,
            focusGoalField,
            keyField,
            lunaRow,
            scrollView
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        keyField.translatesAutoresizingMaskIntoConstraints = false
        focusGoalField.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            focusGoalField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    private func updateLunaControlState() {
        let hasKey = !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        lunaSwitch.isEnabled = hasKey
        lunaLabel.textColor = hasKey ? .labelColor : .secondaryLabelColor
        if !hasKey {
            lunaSwitch.state = .off
        }
    }

    private func publishLunaConfiguration() {
        let trimmedKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabledKey = lunaSwitch.state == .on && !trimmedKey.isEmpty ? trimmedKey : nil
        onLunaConfigurationChange?(enabledKey)
    }

    private func publishFocusGoal() {
        let value = focusGoalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onFocusGoalChange?(value.isEmpty ? nil : value)
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    @objc private func toggleCapture(_ sender: NSButton) {
        captureIsRunning.toggle()
        sender.title = captureIsRunning ? "Stop screen context" : "Start screen context"
        onCaptureToggle?(captureIsRunning)
    }

    @objc private func clearLog(_ sender: NSButton) {
        textView.string = ""
    }

    @objc private func toggleLuna(_ sender: NSSwitch) {
        publishLunaConfiguration()
    }
}
