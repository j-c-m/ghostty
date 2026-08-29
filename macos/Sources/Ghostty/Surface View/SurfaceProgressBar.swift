import SwiftUI

/// OSC 9;4 progress using system `ProgressView`.
struct SurfaceProgressBar: View {
    let report: Ghostty.Action.ProgressReport

    private var color: Color {
        switch report.state {
        case .error: return .red
        case .pause: return .orange
        default: return .accentColor
        }
    }

    private var progress: UInt8? {
        if let v = report.progress { return v }
        if report.state == .pause { return 100 }
        return nil
    }

    private var accessibilityLabel: String {
        switch report.state {
        case .error: return "Terminal progress - Error"
        case .pause: return "Terminal progress - Paused"
        case .indeterminate: return "Terminal progress - In progress"
        default: return "Terminal progress"
        }
    }

    private var accessibilityValue: String {
        if let progress {
            return "\(progress) percent complete"
        } else {
            switch report.state {
            case .error: return "Operation failed"
            case .pause: return "Operation paused at completion"
            case .indeterminate: return "Operation in progress"
            default: return "Indeterminate progress"
            }
        }
    }

    var body: some View {
        Group {
            if let progress {
                ProgressView(value: Double(progress), total: 100)
                    .progressViewStyle(.linear)
                    .tint(color)
                    .animation(.easeInOut(duration: 0.2), value: progress)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(color)
            }
        }
        .scaleEffect(x: 1, y: 0.5, anchor: .center)
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}
