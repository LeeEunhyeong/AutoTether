import SwiftUI

/// 앱 브랜드 색 (아이콘 그라데이션과 같은 계열)
enum Brand {
    static let mint = Color(red: 0.20, green: 0.86, blue: 0.56)
    static let blue = Color(red: 0.04, green: 0.52, blue: 0.96)
    static let gradient = LinearGradient(colors: [mint, Color(red: 0.10, green: 0.72, blue: 0.70)],
                                         startPoint: .leading, endPoint: .trailing)
}

/// 켜짐이 브랜드 색으로 분명하게 보이는 스위치.
/// 시스템 스위치는 메뉴바 패널처럼 키 윈도가 아닌 곳에서 '비활성' 회색으로 그려져 켜짐/꺼짐이 색으로 구분되지 않음.
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
            body(configuration)   // 스크린샷: 접근성 대체 뷰(AppKit 토글)를 만들지 않음 — 글래스 렌더링을 깨뜨림
        } else {
            body(configuration)
                // VoiceOver·키보드 접근성은 시스템 토글과 동일하게
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
            track(isOn: configuration.isOn)
                .onTapGesture {
                    guard isEnabled else { return }
                    withAnimation(.snappy(duration: 0.22)) { configuration.isOn.toggle() }
                }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func track(isOn: Bool) -> some View {
        let s = size
        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.10), lineWidth: 0.5))
                .shadow(color: isOn ? Brand.mint.opacity(0.45) : .clear, radius: 4)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .padding(2)
        }
        .frame(width: s.width, height: s.height)
        .contentShape(Capsule())
    }
}

extension ToggleStyle where Self == BrandSwitchStyle {
    static var brandSwitch: BrandSwitchStyle { BrandSwitchStyle() }
}
