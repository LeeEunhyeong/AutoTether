import SwiftUI
import Charts
import Defaults

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Default(.isEnabled) private var isEnabled
    @Default(.preventLidSleep) private var preventLidSleep
    @Default(.priority) private var priority
    @Default(.monthlyLimitGB) private var monthlyLimitGB

    var body: some View {
        VStack(spacing: 12) {
            header
            StatusCard()
            devices
            usage
            sleepRow
            footer
        }
        .padding(14)
        .frame(width: 360)
        .tint(Brand.mint)
    }

    // MARK: 헤더 + 마스터 스위치

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("AutoTether").font(.headline)
                Text(isEnabled ? "자동 테더링 켜짐" : "일시 중지됨")
                    .font(.caption)
                    .foregroundStyle(isEnabled ? .green : .secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Toggle("자동 테더링", isOn: $isEnabled.animation(.snappy))
                .toggleStyle(.brandSwitch)
                .modifier(SnapshotGlassAnchor())
                .labelsHidden()
                .controlSize(.large)
        }
    }

    // MARK: 기기 우선순위

    private var devices: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("연결 우선순위").font(.subheadline.weight(.semibold))
                Spacer()
                Button("편집") { open(.devices) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 6) {
                    ForEach(Array(priority.enumerated()), id: \.element.id) { idx, item in
                        DeviceRow(rank: idx + 1, item: item)
                    }
                }
            }
        }
    }

    // MARK: 사용량 요약

    private var usage: some View {
        let _ = model.usage.revision
        let store = model.usage.store
        let cal = Calendar.current
        let today = store?.totals(since: cal.startOfDay(for: .now)).total ?? 0
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? .now
        let month = store?.totals(since: monthStart).total ?? 0
        let week = store?.daily(since: cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now))) ?? []

        return Button { open(.dashboard) } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("테더링 데이터", systemImage: "chart.bar.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Metric(title: "오늘", value: Format.bytes(today))
                        Metric(title: "이번 달", value: Format.bytes(month))
                    }
                    if monthlyLimitGB > 0 {
                        let ratio = min(Double(month) / (monthlyLimitGB * 1e9), 1)
                        ProgressView(value: ratio)
                            .tint(ratio > 0.9 ? .red : ratio > 0.7 ? .orange : .green)
                            .controlSize(.mini)
                    }
                }
                Spacer(minLength: 0)
                Chart(week, id: \.self) { b in
                    BarMark(x: .value("날짜", b.date, unit: .day),
                            y: .value("사용량", Double(b.total)))
                        .foregroundStyle(.green.gradient)
                        .cornerRadius(2)
                }
                .chartXScale(domain: (cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now)) ?? .now)...(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) ?? .now))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 96, height: 44)
                .accessibilityLabel("최근 7일 사용량 막대 그래프")
            }
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: 잠자기 방지

    private var sleepRow: some View {
        HStack(spacing: 10) {
            Image(systemName: preventLidSleep ? "moon.zzz.fill" : "moon.zzz")
                .font(.title3)
                .foregroundStyle(preventLidSleep ? .indigo : .secondary)
                .frame(width: 28)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text("덮개 닫아도 깨어 있기").font(.callout.weight(.medium))
                Text(sleepSubtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("덮개 닫아도 깨어 있기", isOn: $preventLidSleep)
                .toggleStyle(.brandSwitch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(GlassOrSnapshotCard(cornerRadius: 16))
    }

    private var sleepSubtitle: String {
        if !preventLidSleep { return "끄면 macOS 기본 동작" }
        if model.sleep.sleepDisabled { return "활성 — 덮개를 닫아도 작업 계속" }
        return model.sleep.lastReason.map { "대기 중 — \($0)" } ?? "적용 중…"
    }

    // MARK: 하단

    private var footer: some View {
        HStack(spacing: 8) {
            Button { open(.dashboard) } label: { Label("대시보드", systemImage: "chart.bar.xaxis") }
                .keyboardShortcut("d", modifiers: .command)
            Button { open(.settings) } label: { Label("설정", systemImage: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q", modifiers: .command)
                .help("AutoTether 종료 (⌘Q)")
                .accessibilityLabel("AutoTether 종료")
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
    }

    private func open(_ section: AppModel.Section) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}

// MARK: - 상태 카드

struct StatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.engine.status
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(status.tint.gradient)
                    Image(systemName: status.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.rotate, isActive: status.isBusy)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.headline).lineLimit(1)
                    Text(status.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if case .tethered = status {
                Divider().opacity(0.4)
                HStack {
                    SpeedPill(symbol: "arrow.down", value: Format.speed(model.usage.downloadSpeed), tint: .green)
                    SpeedPill(symbol: "arrow.up", value: Format.speed(model.usage.uploadSpeed), tint: .blue)
                    Spacer()
                    Button {
                        Task { await model.engine.returnToWiFi(manual: true) }
                    } label: {
                        Image(systemName: "wifi")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("저장된 Wi-Fi로 복귀")
                    .accessibilityLabel("저장된 Wi-Fi로 복귀")
                    .disabled(model.engine.busy)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Format.bytes(model.usage.sessionRx + model.usage.sessionTx))
                            .font(.callout.monospacedDigit().weight(.semibold))
                        if let start = model.usage.sessionStart {
                            Text(start, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(status.tint.opacity(0.12)), in: .rect(cornerRadius: 18))
        .animation(.snappy, value: status)
    }
}

struct SpeedPill: View {
    let symbol: String
    let value: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(value).font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.12), in: .capsule)
    }
}

// MARK: - 기기 행

struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let rank: Int
    let item: PriorityItem

    var body: some View {
        let device = model.hotspots.device(named: item.name)
        let isCurrent: Bool = {
            if case .tethered(let n) = model.engine.status { return n == item.name }
            return false
        }()
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Circle().fill(isCurrent ? Color.green : Color.secondary.opacity(0.2)))
                .foregroundStyle(isCurrent ? .white : .primary)
            Image(systemName: device?.symbol ?? (item.name.lowercased().contains("ipad") ? "ipad" : "iphone"))
                .font(.title3)
                .frame(width: 22)
                .foregroundStyle(item.enabled ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                    .foregroundStyle(item.enabled ? .primary : .secondary)
                if let device {
                    HStack(spacing: 8) {
                        BatteryLabel(percent: device.battery)
                        Image(systemName: "cellularbars", variableValue: Double(device.signal) / 3.0)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text(item.enabled ? "주변에 없음" : "사용 안 함").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isCurrent {
                Label("연결됨", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("연결") {
                    Task { await model.engine.connectNow(item.name) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(model.engine.busy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(isCurrent ? .green.opacity(0.15) : .clear), in: .rect(cornerRadius: 14))
    }
}

struct BatteryLabel: View {
    let percent: Int
    var body: some View {
        let sym = percent > 87 ? "battery.100" : percent > 62 ? "battery.75" : percent > 37 ? "battery.50" : percent > 12 ? "battery.25" : "battery.0"
        HStack(spacing: 2) {
            Image(systemName: sym).foregroundStyle(percent <= 20 ? .red : .secondary)
            Text("\(percent)%").monospacedDigit()
        }
        .font(.caption2)
    }
}

struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
    }
}

struct AppGlyph: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.84, blue: 0.55), Color(red: 0.05, green: 0.55, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "personalhotspot")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}


/// 스크린샷 렌더링 전용: ImageRenderer는 '글래스보다 앞쪽, 글래스 밖'에 AppKit 뷰가 하나도 없으면 Liquid Glass를 전부 빼고 그림.
/// 글래스 컨테이너 안에 두면 그 컨테이너가 사라지고, 루트 배경에 두면 모든 글래스가 사라짐 (실측) → 헤더의 스위치 뒤에만 둠.
struct SnapshotGlassAnchor: ViewModifier {
    @Environment(\.snapshotRendering) private var snapshot
    func body(content: Content) -> some View {
        if snapshot {
            ZStack {
                Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().opacity(0)
                content
            }
        } else {
            content
        }
    }
}

/// 글래스 카드. 스크린샷 렌더링에서는 마지막 글래스 카드가 통째로 빠지는 ImageRenderer 문제가 있어 같은 모양의 반투명 면으로 대체.
struct GlassOrSnapshotCard: ViewModifier {
    @Environment(\.snapshotRendering) private var snapshot
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if snapshot {
            content.background(Color.white.opacity(0.07), in: .rect(cornerRadius: cornerRadius))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}
