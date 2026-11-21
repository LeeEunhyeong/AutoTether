import SwiftUI
import Defaults

@main
struct AutoTetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("AutoTether", id: "main") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @Default(.isEnabled) private var isEnabled

    var body: some View {
        let _ = isEnabled
        Image(systemName: model.menuSymbol)
            .accessibilityLabel("AutoTether")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            #if DEBUG
            DemoMode.install()   // --demo-data: 실제 설정을 건드리지 않는 익명 데모 값 (스크린샷용)
            #endif
            AppModel.shared.start()
            #if DEBUG
            SnapshotRenderer.runIfRequested()
            DebugCLI.runIfRequested()
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.sleep.restoreOnQuit() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
