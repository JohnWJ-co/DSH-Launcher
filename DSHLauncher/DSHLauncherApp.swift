import SwiftUI

@main
struct DSHLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("DSH Launcher") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 620)
        }
    }
}
