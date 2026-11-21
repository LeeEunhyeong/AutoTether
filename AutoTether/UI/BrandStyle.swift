import SwiftUI

enum Brand {
    static let mint = Color(red: 0.20, green: 0.86, blue: 0.56)
    static let blue = Color(red: 0.04, green: 0.52, blue: 0.96)
    static let gradient = LinearGradient(colors: [mint, Color(red: 0.10, green: 0.72, blue: 0.70)],
                                         startPoint: .leading, endPoint: .trailing)
}

struct BrandSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.labelsVisibility) private var labelsVisibility
    @Environment(\.snapshotRendering) private var snapshot

    private var size: CGSize {
        switch controlSize {
        case .mini: CGSize(width: 26, height: 15)
        case .small: CGSize(width: 32, height: 18)
        case .large, .extraLarge: CGSize(width: 46, height: 26)
        default: CGSize(width: 38, height: 22)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        if snapshot {
            body(configuration)
        } else {
            body(configuration)
                .accessibilityRepresentation {
                    Toggle(isOn: configuration.$isOn) { configuration.label }
                }
        }
    }

    private func body(_ configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            if labelsVisibility != .hidden {
                configuration.label
                Spacer(minLength: 8)
            }
            BrandSwitchTrack(isOn: configuration.$isOn, size: size, enabled: isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct BrandSwitchTrack: View {
    @Binding var isOn: Bool
    let size: CGSize
    let enabled: Bool
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.10), lineWidth: 0.5))
                .shadow(color: isOn ? Brand.mint.opacity(0.45) : .clear, radius: 4)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .padding(2)
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            Capsule().strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 2.5).padding(-3)
        }
        .contentShape(Capsule())
        .onTapGesture(perform: flip)
        .focusable(enabled)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { flip(); return .handled }
        .onKeyPress(.return) { flip(); return .handled }
    }

    private func flip() {
        guard enabled else { return }
        withAnimation(.snappy(duration: 0.22)) { isOn.toggle() }
    }
}

extension ToggleStyle where Self == BrandSwitchStyle {
    static var brandSwitch: BrandSwitchStyle { BrandSwitchStyle() }
}
