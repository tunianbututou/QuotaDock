import AppKit

@MainActor final class AppShell: NSObject, NSApplicationDelegate {
    private var widget: WidgetHost?
    private var menuBar: StatusBarHost?

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        // 先定外观，再建窗口：否则首帧会按系统外观画一次再跳变
        ThemeCenter.shared.configure(Preferences.shared.themeMode)
        ThemeCenter.shared.trackSystemTheme()

        let panel = WidgetHost()
        widget = panel
        menuBar = StatusBarHost(widget: panel)
        PreferencesHost.shared.widget = panel

        if Preferences.shared.showWidget {
            panel.show()
        }

        Task { await QuotaStream.shared.warmUp() }

        // 本 App 是菜单栏常驻（accessory），点自己窗口时系统不一定立刻把它激活：
        // 窗口就会停在「未激活」的灰标题栏上，看着像坏了，而且第一次点击可能被吃掉。
        // 这里在事件分发前补一次激活，点一下就回到前台。
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            return event
        }

        #if SNAPTEST
        // 自检构建：启动后立即跑贴边判定并落盘，然后退出
        if true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let report = panel.selfTestSnap()
                let target = (NSTemporaryDirectory() as NSString)
                    .appendingPathComponent("quotadock-selftest.txt")
                try? report.write(toFile: target, atomically: true, encoding: .utf8)
                PreferencesHost.shared.widget = panel
                PreferencesHost.shared.show()
                let info = "settings visible=\(PreferencesHost.shared.debugVisible) frame=\(PreferencesHost.shared.debugFrame)\n"
                if let handle = FileHandle(forWritingAtPath: target) {
                    handle.seekToEndOfFile()
                    handle.write(info.data(using: .utf8)!)
                    handle.closeFile()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        widget?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前把内置 codex helper 一起收掉，别留孤儿进程
        QuotaStream.shared.shutdown()
    }
}

private var signalSources: [DispatchSourceSignal] = []

/// 同一时刻只允许一份实例。
/// 双击两次 / 开机项 + 手动启动同时发生时会起两个进程，两个悬浮窗叠在一起
/// 看起来就像"面板上多了一层"，而且两边各自轮询，多花一份额度查询。
private func yieldToRunningCopy() -> Bool {
    guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else { return false }
    let siblings = NSRunningApplication
        .runningApplications(withBundleIdentifier: identifier)
        .filter { $0.processIdentifier != getpid() }
    guard let alive = siblings.first else { return false }
    alive.activate(options: [.activateAllWindows])
    return true
}

MainActor.assumeIsolated {
    if yieldToRunningCopy() { exit(0) }

    let application = NSApplication.shared
    let delegate = AppShell()
    application.delegate = delegate

    // 被 kill -TERM（脚本/系统重启）收掉时也走一遍清理
    _ = signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            QuotaStream.shared.shutdown()
            NSApplication.shared.terminate(nil)
        }
    }
    source.resume()
    signalSources.append(source)

    application.run()
}
