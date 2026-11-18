import AppKit
import QuartzCore

final class VoiceDraftPanel: NSPanel {
    enum Phase {
        case preparing, listening, confirming

        var title: String {
            switch self {
            case .preparing: return "正在准备听写…"
            case .listening: return "正在听写"
            case .confirming: return "正在确认…"
            }
        }

        var symbol: String {
            switch self {
            case .preparing, .listening: return "waveform"
            case .confirming: return "text.bubble"
            }
        }
    }

    private static let cornerRadius: CGFloat = 24
    private static let shadowMargin: CGFloat = 36

    private let status = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let placeholder = NSTextField(labelWithString: "识别的文字会显示在这里")
    let editor: VoiceDraftTextView

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        let surfaceSize = NSSize(width: 444, height: 118)
        let margin = Self.shadowMargin
        let size = NSSize(width: surfaceSize.width + 2 * margin, height: surfaceSize.height + 2 * margin)
        editor = VoiceDraftTextView(frame: .zero)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "语音草稿"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // Use a soft shadow under the surface to avoid the window server's hard outline.
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let surface = Self.surface(containing: makeBody(), size: surfaceSize)
        contentView = Self.addShadow(behind: surface, size: size)
        setPhase(.preparing)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 52 - margin))
        } else {
            center()
        }

        initialFirstResponder = editor
    }

    func setPhase(_ phase: Phase) {
        status.stringValue = phase.title
        statusIcon.image = NSImage(systemSymbolName: phase.symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = phase == .listening ? .systemRed : .secondaryLabelColor
    }

    private func makeBody() -> NSView {
        status.font = .systemFont(ofSize: 13, weight: .semibold)
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

        let statusGroup = NSStackView(views: [statusIcon, status])
        statusGroup.spacing = 8
        statusGroup.alignment = .centerY

        let actions = NSStackView(views: [
            Self.keyHint("↑", label: "确认", accessibilityLabel: "按 UP 确认"),
            Self.keyHint("OK", label: "长按取消", accessibilityLabel: "长按 OK 取消"),
        ])
        actions.spacing = 13
        actions.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [statusGroup, spacer, actions])
        header.alignment = .centerY
        header.spacing = 0

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = editor
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .systemFont(ofSize: 17)
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.setAccessibilityLabel("语音草稿正文")

        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = .secondaryLabelColor
        placeholder.isSelectable = false
        let writingArea = NSView()
        for view in [placeholder, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            writingArea.addSubview(view)
        }
        editor.onContentChanged = { [weak editor, weak placeholder] in
            guard let editor else { return }
            placeholder?.isHidden = !editor.string.isEmpty || editor.hasMarkedText()
        }

        let body = NSView()
        for view in [header, writingArea] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: body.topAnchor, constant: 15),
            header.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 19),
            header.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -19),
            writingArea.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            writingArea.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            writingArea.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            writingArea.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -13),
            scroll.topAnchor.constraint(equalTo: writingArea.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: writingArea.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: writingArea.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: writingArea.bottomAnchor),
            placeholder.topAnchor.constraint(equalTo: writingArea.topAnchor, constant: 5),
            placeholder.leadingAnchor.constraint(equalTo: writingArea.leadingAnchor),
        ])
        return body
    }

    private static func surface(containing body: NSView, size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = body
            return glass
        }
        #endif

        let material = NSVisualEffectView(frame: frame)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        body.frame = frame
        body.autoresizingMask = [.width, .height]
        material.addSubview(body)
        return material
    }

    private static func addShadow(behind surface: NSView, size: NSSize) -> NSView {
        let bounds = NSRect(origin: .zero, size: size)
        let surfaceFrame = bounds.insetBy(dx: shadowMargin, dy: shadowMargin)
        let shape = CGPath(roundedRect: surfaceFrame, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                           transform: nil)
        let shadow = CAShapeLayer()
        shadow.frame = bounds
        shadow.path = shape
        shadow.fillColor = NSColor.black.cgColor
        shadow.shadowPath = shape
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.20
        shadow.shadowRadius = 12
        shadow.shadowOffset = CGSize(width: 0, height: -6)

        // Keep the shadow outside the glass so it cannot darken the backdrop inside.
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(shape)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = outside
        mask.fillRule = .evenOdd
        let shadowHost = CALayer()
        shadowHost.frame = bounds
        shadowHost.mask = mask
        shadowHost.addSublayer(shadow)

        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.addSublayer(shadowHost)
        surface.frame = surfaceFrame
        container.addSubview(surface)
        return container
    }

    private static func keyHint(_ key: String, label: String, accessibilityLabel: String) -> NSView {
        let cap = DraftKeyCap(key: key)
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .labelColor
        let hint = NSStackView(views: [cap, title])
        hint.alignment = .centerY
        hint.spacing = 5
        hint.setAccessibilityElement(true)
        hint.setAccessibilityRole(.staticText)
        hint.setAccessibilityLabel(accessibilityLabel)
        return hint
    }
}

final class VoiceDraftTextView: NSTextView {
    var onContentChanged: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        onContentChanged?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onContentChanged?()
    }
}

private final class DraftKeyCap: NSView {
    private let title: NSTextField

    init(key: String) {
        title = NSTextField(labelWithString: key)
        super.init(frame: .zero)
        title.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: key == "OK" ? 25 : 20),
            heightAnchor.constraint(equalToConstant: 19),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.withAlphaComponent(0.34).setFill()
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.stroke()
    }
}
