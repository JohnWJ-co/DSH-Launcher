import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单元测试宿主启动时不做任何真实副作用（不清理进程、不自动运行）
        if NSClassFromString("XCTestCase") == nil {
            AppModel.shared.boot()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if NSClassFromString("XCTestCase") == nil {
            AppModel.shared.shutdownForTermination()
        }
    }
}
