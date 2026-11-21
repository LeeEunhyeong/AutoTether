import SwiftUI
import Charts
import Defaults
import LaunchAtLogin

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<AppModel.Section?>(
            get: { model.section },
            set: { if let v = $0 { model.section = v } }
        )
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: selection) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                MiniStatus().padding(10)
            }
        } detail: {
            Group {
                switch model.section {
                case .dashboard: DashboardView()
                case .devices: DevicesView()
                case .settings: SettingsView()
                case .activity: ActivityView()
                }
            }
            .frame(minWidth: 640, minHeight: 560)
            .toggleStyle(.brandSwitch)   // 모든 스위치를 브랜드 색으로 (체크박스는 개별 지정 유지)
        }
        .tint(Brand.mint)
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

struct MiniStatus: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let s = model.engine.status
        HStack(spacing: 8) {
            Image(systemName: s.symbol).foregroundStyle(s.tint)
            Text(s.title).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: - 대시보드

struct DashboardView: View {
    var body: some View {
        ScrollView { DashboardContent() }
    }
}

struct DashboardContent: View {
    @Environment(AppModel.self) private var model
    @Default(.monthlyLimitGB) private var monthlyLimitGB
    @State private var period: Period = .week

    enum Period: String, CaseIterable, Identifiable {
        case today = "오늘", week = "7일", month = "30일", all = "전체"
        var id: String { rawValue }
        var since: Date? {
            let cal = Calendar.current
            let today = cal.startOfDay(for: .now)
            switch self {
            case .today: return today
            case .week: return cal.date(byAdding: .day, value: -6, to: today)
            case .month: return cal.date(byAdding: .day, value: -29, to: today)
            case .all: return nil
            }
        }
    }

    var body: some View {
        let _ = model.usage.revision
        let store = model.usage.store
        let since = period.since
        let totals = store?.totals(since: since) ?? UsageTotals()
        let buckets = period == .today ? (store?.hourly(since: since) ?? []) : (store?.daily(since: since) ?? [])
        let devices = store?.byDevice(since: since) ?? []
        let sessions = store?.sessions(limit: 12) ?? []
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? .now
        let monthTotal = store?.totals(since: monthStart).total ?? 0

        VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("데이터 사용량").font(.largeTitle.bold())
                        Text("개인용 핫스팟(테더링)으로 사용한 데이터만 집계합니다").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("기간", selection: $period.animation(.snappy)) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    .modifier(SnapshotSegmentFallback(selection: period.rawValue, options: Period.allCases.map(\.rawValue)))
                }

                StatusCard()

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    KPITile(title: "총 사용량", value: Format.bytes(totals.total), symbol: "sum", tint: .green)
                    KPITile(title: "다운로드", value: Format.bytes(totals.rx), symbol: "arrow.down.circle.fill", tint: .teal)
                    KPITile(title: "업로드", value: Format.bytes(totals.tx), symbol: "arrow.up.circle.fill", tint: .blue)
                    KPITile(title: "테더링 시간", value: Format.duration(totals.seconds), symbol: "clock.fill", tint: .orange)
                }

                Card(title: period == .today ? "시간대별 사용량" : "일별 사용량", symbol: "chart.bar.fill") {
                    if buckets.isEmpty {
                        EmptyChart()
                    } else {
                        let unit = ChartUnit.pick(maxBytes: Dictionary(grouping: buckets, by: \.date).values.map { $0.reduce(0) { $0 + $1.total } }.max() ?? 0)   // 기기별로 쌓인 막대의 최댓값 기준
                        Chart(buckets, id: \.self) { b in
                            BarMark(x: .value("시간", b.date, unit: period == .today ? .hour : .day),
                                    y: .value(unit.label, Double(b.total) / unit.divisor))
                                .foregroundStyle(by: .value("기기", b.device))
                                .cornerRadius(3)
                        }
                        .chartForegroundStyleScale(domain: DeviceColors.domain(buckets.map(\.device)), range: DeviceColors.palette)
                        .chartYAxisLabel(unit.label)
                        .accessibilityLabel("\(period == .today ? "시간대별" : "일별") 사용량 차트, 단위 \(unit.label)")
                        .chartLegend(position: .top, alignment: .leading)
                        .frame(height: 220)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card(title: "기기별", symbol: "chart.pie.fill") {
                        if devices.isEmpty {
                            EmptyChart(height: 160)
                        } else {
                            HStack(spacing: 16) {
                                Chart(devices, id: \.device) { d in
                                    SectorMark(angle: .value("사용량", d.total), innerRadius: .ratio(0.62), angularInset: 2)
                                        .foregroundStyle(by: .value("기기", d.device))
                                        .cornerRadius(4)
                                }
                                .chartForegroundStyleScale(domain: DeviceColors.domain(devices.map(\.device)), range: DeviceColors.palette)
                                .chartLegend(.hidden)
                                .frame(width: 150, height: 150)
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(devices, id: \.device) { d in
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(d.device).font(.callout.weight(.medium))
                                            Text(Format.bytes(d.total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    Card(title: "이번 달", symbol: "calendar") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(Format.bytes(monthTotal)).font(.system(size: 30, weight: .bold).monospacedDigit())
                            if monthlyLimitGB > 0 {
                                let ratio = min(Double(monthTotal) / (monthlyLimitGB * 1e9), 1)
                                Gauge(value: ratio) {
                                    Text("월 한도")
                                } currentValueLabel: {
                                    Text("\(Int(ratio * 100))%")
                                } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("\(Int(monthlyLimitGB))GB") }
                                .tint(Gradient(colors: [.green, .yellow, .red]))
                            } else {
                                Text("설정에서 월 데이터 한도를 지정하면 진행률이 표시됩니다")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 260)
                }
                .fixedSize(horizontal: false, vertical: true)   // 두 카드 높이를 같게

                Card(title: "최근 테더링 세션", symbol: "list.bullet.rectangle") {
                    if sessions.isEmpty {
                        Text("아직 기록이 없습니다").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(sessions) { s in
                                HStack {
                                    Image(systemName: s.device.lowercased().contains("ipad") ? "ipad" : "iphone").frame(width: 20)
                                    Text(s.device).font(.callout.weight(.medium))
                                    Text(s.start.formatted(.dateTime.month().day().hour().minute()))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Format.duration(s.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(Format.bytes(s.total)).font(.callout.monospacedDigit().weight(.semibold))
                                        .frame(width: 90, alignment: .trailing)
                                }
                                .padding(.vertical, 7)
                                if s.id != sessions.last?.id { Divider().opacity(0.4) }
                            }
                        }
                    }
                }
            }
            .padding(24)
    }
}

/// 기기별 색을 우선순위 순서로 고정
enum DeviceColors {
    static let palette: [Color] = [.green, .blue, .orange, .purple, .pink, .teal, .yellow]
    static func domain(_ names: [String]) -> [String] {
        let order = Defaults[.priority].map(\.name)
        let unique = Array(Set(names))
        return unique.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
    }
}

struct KPITile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint.gradient)
            Text(value).font(.title2.weight(.bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .rect(cornerRadius: 18))
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// 스크린샷 렌더링(ImageRenderer)은 AppKit 컨트롤을 그리지 못함 → 스크린샷일 때만 SwiftUI로 그린 모양으로 대체
struct SnapshotRenderingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var snapshotRendering: Bool {
        get { self[SnapshotRenderingKey.self] }
        set { self[SnapshotRenderingKey.self] = newValue }
    }
}

struct SnapshotSegmentFallback: ViewModifier {
    @Environment(\.snapshotRendering) private var snapshot
    let selection: String
    let options: [String]
    func body(content: Content) -> some View {
        if snapshot {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { o in
                    Text(o).font(.callout.weight(o == selection ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(o == selection ? Color.white.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 8))
            .frame(width: 260)
        } else {
            content
        }
    }
}

/// 차트 Y축 단위를 데이터 크기에 맞춰 선택 (카드의 GB 표기와 어긋나지 않도록)
struct ChartUnit {
    let label: String
    let divisor: Double
    static func pick(maxBytes: Int64) -> ChartUnit {
        switch maxBytes {
        case 1_000_000_000...: ChartUnit(label: "GB", divisor: 1e9)
        case 1_000_000...: ChartUnit(label: "MB", divisor: 1e6)
        default: ChartUnit(label: "KB", divisor: 1e3)
        }
    }
}

struct EmptyChart: View {
    var height: CGFloat = 200
    var body: some View {
        ContentUnavailableView("아직 데이터가 없어요", systemImage: "chart.bar",
                               description: Text("핫스팟으로 연결되면 사용량이 여기에 쌓입니다"))
            .frame(height: height)
    }
}

// MARK: - 기기 우선순위

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @Default(.priority) private var priority
    @Default(.pinnedBSSIDs) private var pinned
    @Default(.hotspotWPA3) private var wpa3
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                ForEach($priority) { $item in
                    let idx = priority.firstIndex(where: { $0.id == item.id }) ?? 0
                    let device = model.hotspots.device(named: item.name)
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Text("\(idx + 1)").font(.headline.monospacedDigit()).frame(width: 18)
                        Image(systemName: device?.symbol ?? (item.name.lowercased().contains("ipad") ? "ipad" : "iphone"))
                            .font(.title2).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.body.weight(.medium))
                            if let device {
                                HStack(spacing: 8) {
                                    Label("주변에 있음", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                                    BatteryLabel(percent: device.battery)
                                    Text(device.model).foregroundStyle(.tertiary)
                                }
                                .font(.caption)
                            } else {
                                Text("현재 주변에서 보이지 않음").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(idx == 0)
                            .help("우선순위 올리기").accessibilityLabel("\(item.name) 우선순위 올리기")
                        Button { move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(idx == priority.count - 1)
                            .help("우선순위 내리기").accessibilityLabel("\(item.name) 우선순위 내리기")
                        Toggle("WPA2 허용", isOn: Binding(
                            get: { wpa3[item.name] == false },
                            set: { allow in
                                if allow { wpa3[item.name] = false } else { wpa3[item.name] = nil }
                            }))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("이 기기가 WPA3를 지원하지 않을 때만 켜세요. 켜면 같은 이름의 가짜 WPA2 AP에 비밀번호가 노출될 위험이 생깁니다.")
                        Toggle("사용", isOn: $item.enabled).labelsHidden()
                            .accessibilityLabel("\(item.name) 자동 연결 사용")
                        Button(role: .destructive) { priority.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "trash")
                        }
                        .help("목록에서 삭제").accessibilityLabel("\(item.name) 삭제")
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 4)
                }
                .onMove { priority.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("연결 우선순위")
            } footer: {
                Text("Wi-Fi가 끊기면 위에서부터 순서대로 핫스팟을 켜고 연결합니다. 드래그하거나 화살표로 순서를 바꾸세요.")
            }

            Section("주변에서 발견된 기기 (같은 Apple ID)") {
                if model.hotspots.devices.isEmpty {
                    Text(model.hotspots.isAvailable ? "찾는 중… (블루투스가 켜져 있어야 합니다)" : "Instant Hotspot API를 사용할 수 없음")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.hotspots.devices) { d in
                    HStack {
                        Image(systemName: d.symbol).frame(width: 24)
                        Text(d.name)
                        BatteryLabel(percent: d.battery)
                        Spacer()
                        if priority.contains(where: { $0.name == d.name }) {
                            Text("목록에 있음").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("우선순위에 추가") { priority.append(PriorityItem(name: d.name)) }
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("핫스팟 이름 (예: 내 iPhone)", text: $newName)
                        .onSubmit(add)
                    Button("추가", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !pinned.isEmpty || !wpa3.isEmpty {
                    Button("핫스팟 보안 기록 초기화 (WPA2 허용 \(wpa3.values.filter { !$0 }.count)개 포함)", role: .destructive) {
                        pinned = [:]
                        wpa3 = [:]
                    }
                }
            } header: {
                Text("직접 추가")
            } footer: {
                Text("기기 이름은 핫스팟 Wi-Fi 이름(SSID)과 같아야 합니다. 주변에서 발견되지 않는 기기는 macOS에 저장된 Wi-Fi 프로필로만 연결합니다. 자동 연결은 WPA3(SAE)로만 합니다 (같은 이름의 가짜 WPA2 AP가 비밀번호를 빼내는 공격 방지). WPA3를 지원하지 않는 기기만 'WPA2 허용'을 켜세요.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("기기 우선순위")
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 32,   // Wi-Fi SSID 최대 32바이트
              !priority.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        priority.append(PriorityItem(name: name))
        newName = ""
    }

    private func move(_ item: PriorityItem, by delta: Int) {
        guard let i = priority.firstIndex(where: { $0.id == item.id }) else { return }
        let j = i + delta
        guard priority.indices.contains(j) else { return }
        withAnimation(.snappy) { priority.swapAt(i, j) }
    }
}

// MARK: - 설정

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Default(.isEnabled) private var isEnabled
    @Default(.returnToWiFi) private var returnToWiFi
    @Default(.leaveDeadWiFi) private var leaveDeadWiFi
    @Default(.notifyOnSwitch) private var notifyOnSwitch
    @Default(.preventLidSleep) private var preventLidSleep
    @Default(.lidSleepOnlyWhileTethered) private var onlyWhileTethered
    @Default(.lidSleepBatteryFloor) private var batteryFloor
    @Default(.monthlyLimitGB) private var monthlyLimitGB
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("일반") {
                LaunchAtLogin.Toggle("로그인 시 자동 실행")
                Toggle("전환 시 알림 보내기", isOn: $notifyOnSwitch)
            }

            Section {
                Toggle("자동 테더링", isOn: $isEnabled)
                Toggle("인터넷이 안 되는 Wi-Fi에서도 핫스팟으로 전환", isOn: $leaveDeadWiFi)
                Toggle("저장된 Wi-Fi가 다시 잡히면 자동 복귀", isOn: $returnToWiFi)
            } header: {
                Text("자동 전환")
            } footer: {
                Text("Wi-Fi 연결이 약 10초간 끊기거나, 연결돼 있어도 30초간 인터넷이 안 되면 우선순위대로 핫스팟에 연결합니다. 핫스팟 사용 중에는 2분마다 저장된 Wi-Fi를 찾아 데이터를 아낍니다.")
            }

            Section {
                Toggle("덮개를 닫아도 잠자기하지 않기", isOn: $preventLidSleep)
                Toggle("테더링 중일 때만 적용", isOn: $onlyWhileTethered).disabled(!preventLidSleep)
                Picker("배터리 보호", selection: $batteryFloor) {
                    Text("사용 안 함").tag(0)
                    ForEach([10, 15, 20, 30], id: \.self) { Text("배터리 \($0)% 이하에서 자동 해제").tag($0) }
                }
                .disabled(!preventLidSleep)
                LabeledContent("현재 시스템 상태") {
                    Text(model.sleep.sleepDisabled ? "잠자기 비활성 (깨어 있음)" : "macOS 기본")
                        .foregroundStyle(model.sleep.sleepDisabled ? .indigo : .secondary)
                }
                LabeledContent("권한 헬퍼") {
                    HStack {
                        switch model.sleep.helperState {
                        case .ready:
                            Label("승인됨 · 서명 확인", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Button("제거") { Task { await model.sleep.uninstallHelper() } }
                        case .needsApproval:
                            Label("승인 필요", systemImage: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                            Button("시스템 설정 열기") { model.sleep.requestApproval() }
                        case .unavailable:
                            Label("응답 없음", systemImage: "xmark.shield").foregroundStyle(.red)
                            Button("다시 확인") { Task { await model.sleep.refreshHelperStatus() } }
                        case .notInstalled:
                            Text("미설치 (처음 켤 때 승인 요청)").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("잠자기 방지")
            } footer: {
                Text("macOS는 외부 모니터 없이 덮개를 닫으면 항상 잠자기합니다. 이 옵션은 `pmset disablesleep`으로 이를 막고, 앱을 끄면 원래대로 되돌립니다. 처음 켤 때 시스템 설정 › 로그인 항목에서 AutoTether 헬퍼를 한 번 허용해야 합니다(서명이 확인된 이 앱만 사용 가능). 가방 속에서 과열되지 않도록 주의하세요.")
            }

            Section("데이터") {
                LabeledContent("월 데이터 한도") {
                    HStack {
                        TextField("월 데이터 한도", value: Binding(get: { monthlyLimitGB }, set: { monthlyLimitGB = max(0, min($0, 100_000)) }), format: .number, prompt: Text("0"))
                            .labelsHidden()   // Form 안에서는 제목이 라벨로 한 번 더 표시되므로 숨김
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("GB · 0이면 사용 안 함").foregroundStyle(.secondary)
                    }
                }
                Button("사용량 기록 초기화…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("모든 사용량 기록을 삭제할까요?", isPresented: $confirmReset) {
                        Button("삭제", role: .destructive) { model.usage.resetAll() }
                    }
            }

            Section {
                LabeledContent("위치 서비스") {
                    HStack {
                        Text(model.location.statusText).foregroundStyle(model.location.isAuthorized ? .green : .orange)
                        if !model.location.isAuthorized { Button("권한 요청") { model.location.request() } }
                    }
                }
                LabeledContent("Instant Hotspot") {
                    Text(model.hotspots.isAvailable ? "사용 가능" : "사용 불가").foregroundStyle(model.hotspots.isAvailable ? .green : .red)
                }
            } header: {
                Text("권한")
            } footer: {
                Text("위치 권한은 주변 Wi-Fi 이름을 읽어 저장된 Wi-Fi로 자동 복귀하는 데만 사용됩니다.")
            }

            Section("정보") {
                LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                LabeledContent("오픈소스") {
                    Text("Defaults · LaunchAtLogin · GRDB · mac-auto-hotspot · Stats")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("설정")
    }
}

// MARK: - 활동 기록

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.activity.entries) { e in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon(e.level)).foregroundStyle(color(e.level))
                Text(e.date.formatted(.dateTime.hour().minute().second()))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(e.message).textSelection(.enabled)
            }
        }
        .overlay {
            if model.activity.entries.isEmpty {
                ContentUnavailableView("기록 없음", systemImage: "clock")
            }
        }
        .toolbar {
            Button { NSWorkspace.shared.open(model.activity.fileURL) } label: {
                Label("로그 파일 열기", systemImage: "doc.text")
            }
            Button { Task { await model.engine.checkNow() } } label: {
                Label("지금 확인", systemImage: "arrow.clockwise")
            }
        }
        .navigationTitle("활동 기록")
    }

    private func icon(_ l: ActivityLog.Level) -> String {
        switch l {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ l: ActivityLog.Level) -> Color {
        switch l {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
