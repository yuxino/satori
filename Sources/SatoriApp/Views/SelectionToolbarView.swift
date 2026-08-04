import AppKit

/// A small floating bar shown above a PDF text selection — the Cursor-style
/// "select and ask" entry point. It lives as a direct subview of the PDFView
/// so it can be positioned in the view's coordinate space.
final class SelectionToolbarView: NSView {
    var onExplain: (() -> Void)?
    var onCompose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let explain = makeButton(title: "解释这段", symbol: "sparkles", action: #selector(explainTapped), prominent: true)
        let compose = makeButton(title: "就这段提问", symbol: "bubble.and.pencil", action: #selector(composeTapped), prominent: false)
        let stack = NSStackView(views: [explain, compose])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeButton(title: String, symbol: String, action: Selector, prominent: Bool) -> NSButton {
        let button = NSButton(title: " " + title, target: self, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        if prominent {
            button.bezelStyle = .rounded
            button.bezelColor = NSColor(red: 0.42, green: 0.38, blue: 0.78, alpha: 1)
            button.contentTintColor = .white
        } else {
            button.bezelStyle = .accessoryBarAction
            button.contentTintColor = .labelColor
        }
        return button
    }

    /// A brief scale-and-fade so the bar feels like it grows out of the
    /// selection rather than snapping into place.
    func playAppearance() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "appear")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.94
        scale.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = 0.16
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "appear")
    }

    @objc private func explainTapped() { onExplain?() }
    @objc private func composeTapped() { onCompose?() }
}
