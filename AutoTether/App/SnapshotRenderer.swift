#if DEBUG
import SwiftUI
import AppKit

/// README 스크린샷용 익명 데모 값. 사용자 설정(UserDefaults)에 쓰지 않고 비영속 인자 도메인에만 넣음.
enum DemoMode {
    static var isActive: Bool { CommandLine.arguments.contains("--demo-data") }
    static let ssid = "Home Wi-Fi"
    static let devices = [
        HotspotDevice(id: "demo-iphone", name: "iPhone", model: "iPhone17,2", battery: 82, signal: 3),
        HotspotDevice(id: "demo-ipad", name: "iPad", model: "iPad13,17", battery: 64, signal: 2),
    ]

    static func install() {
        guard isActive else { return }
        let items = devices.map { PriorityItem(name: $0.name) }
            .compactMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["priority"] = items
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}

/// 디버그용: `AutoTether --snapshot <dir>` → 주요 화면을 PNG로 저장하고 종료 (화면 녹화 권한 불필요)
@MainActor
enum SnapshotRenderer {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func runIfRequested() {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))   // 기기 탐색/샘플 대기
            let model = AppModel.shared
            if DemoMode.isActive { model.engine.overrideStatusForDemo(.wifi(DemoMode.ssid)) }
            await render(MenuBarView().environment(model), size: NSSize(width: 360, height: 640), name: "menubar", dir: dir, fit: true)
            await render(DashboardContent().environment(model), size: NSSize(width: 860, height: 1300), name: "dashboard", dir: dir, fit: true)
            for section in AppModel.Section.allCases {
                model.section = section
                await renderWindow(MainWindow().environment(model), size: NSSize(width: 1000, height: 760), name: "window-\(section.rawValue)", dir: dir, fit: false)
            }
            NSApp.terminate(nil)
        }
    }

    private static func render<V: View>(_ view: V, size: NSSize, name: String, dir: URL, fit: Bool) async {
        try? await Task.sleep(for: .seconds(0.5))
        let content = view
            .frame(width: size.width, height: fit ? nil : size.height)
            .environment(\.snapshotRendering, true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appending(path: "\(name).png"))
        }
    }

    private static func renderWindow<V: View>(_ view: V, size: NSSize, name: String, dir: URL, fit: Bool) async {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .init(x: 80, y: 80), size: size),
                              styleMask: fit ? [.borderless] : [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        if fit {
            let fitting = hosting.fittingSize
            window.setContentSize(NSSize(width: size.width, height: fitting.height))
        }
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        let bounds = hosting.bounds
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) {
            hosting.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appending(path: "\(name).png"))
            }
        }
        window.orderOut(nil)
    }
}
#endif
