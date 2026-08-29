import AppKit

/// OSC 9;4 progress hairline. Indeterminate bounce is a CALayer `position.x`
/// animation so it does not drive SwiftUI layout over the Metal surface.
final class SurfaceProgressChrome: NSView {
    static let hairlineHeight: CGFloat = 2

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var animWidth: CGFloat = 0
    private var report: Ghostty.Action.ProgressReport?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        trackLayer.anchorPoint = .zero
        fillLayer.anchorPoint = .zero
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityHidden(true)
        // VoiceOver polls AXUpdatesFrequently instead of waiting on notifications.
        _ = accessibilitySetOverrideValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXUpdatesFrequently"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func setReport(_ report: Ghostty.Action.ProgressReport?) {
        if report == nil || report?.state == .remove {
            self.report = nil
            fillLayer.removeAnimation(forKey: "bounce")
            animWidth = 0
            isHidden = true
            setAccessibilityHidden(true)
            return
        }

        self.report = report
        isHidden = false
        setAccessibilityHidden(false)
        applyAppearance()
    }

    private func applyAppearance() {
        guard let report, !isHidden else { return }
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let color = barColor(report)
        updateAccessibility(report)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isBounce(report) {
            // 25% chunk, 1.2s ease-in-out bounce, track 0.3.
            trackLayer.backgroundColor = cgColor(color.withAlphaComponent(0.3))
            fillLayer.backgroundColor = cgColor(color)
            let barW = w * 0.25
            trackLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)
            fillLayer.bounds = CGRect(x: 0, y: 0, width: barW, height: h)
            fillLayer.position = .zero
            CATransaction.commit()
            if abs(animWidth - w) > 0.5 {
                fillLayer.removeAnimation(forKey: "bounce")
                animWidth = w
            }
            if fillLayer.animation(forKey: "bounce") == nil, w > barW {
                let anim = CABasicAnimation(keyPath: "position.x")
                anim.fromValue = 0
                anim.toValue = w - barW
                anim.duration = 1.2
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fillLayer.add(anim, forKey: "bounce")
            }
        } else {
            fillLayer.removeAnimation(forKey: "bounce")
            animWidth = 0
            trackLayer.backgroundColor = nil
            fillLayer.backgroundColor = cgColor(color)
            let pct: CGFloat
            if let progress = report.progress {
                pct = CGFloat(progress)
            } else if report.state == .pause {
                pct = 100
            } else {
                pct = 0
            }
            let sx = w * pct / 100
            trackLayer.frame = .zero
            fillLayer.frame = CGRect(x: 0, y: 0, width: sx, height: h)
            CATransaction.commit()
        }
    }

    private func isBounce(_ report: Ghostty.Action.ProgressReport) -> Bool {
        if report.state == .remove || report.state == .pause { return false }
        return report.progress == nil
    }

    private func barColor(_ report: Ghostty.Action.ProgressReport) -> NSColor {
        switch report.state {
        case .error: return .systemRed
        case .pause: return .systemOrange
        default: return .controlAccentColor
        }
    }

    private func cgColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }

    private func updateAccessibility(_ report: Ghostty.Action.ProgressReport) {
        let progress = report.progress ?? (report.state == .pause ? 100 : nil)
        switch report.state {
        case .error:
            setAccessibilityLabel("Terminal progress - Error")
        case .pause:
            setAccessibilityLabel("Terminal progress - Paused")
        case .indeterminate:
            setAccessibilityLabel("Terminal progress - In progress")
        default:
            setAccessibilityLabel("Terminal progress")
        }
        if let progress {
            setAccessibilityValue("\(progress) percent complete")
        } else {
            switch report.state {
            case .error:
                setAccessibilityValue("Operation failed")
            case .pause:
                setAccessibilityValue("Operation paused at completion")
            case .indeterminate:
                setAccessibilityValue("Operation in progress")
            default:
                setAccessibilityValue("Indeterminate progress")
            }
        }
    }
}
