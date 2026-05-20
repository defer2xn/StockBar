import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // 不在 Dock 显示
    app.mainMenu = buildMainMenu()        // accessory 应用默认无主菜单，需手动装才能让 ⌘Q 生效
    app.run()
}

/// 构建最简 App 主菜单：仅提供标准退出项。
/// accessory 应用没有系统主菜单，⌘Q 无处投递；状态栏菜单里的退出项只在菜单展开时才响应快捷键，
/// 不是全局快捷键。装上这个主菜单后，窗口聚焦时按 ⌘Q 才能正常退出。
@MainActor
private func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "退出 StockBar",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"   // 默认带 ⌘ 修饰键 → ⌘Q
    )
    appMenuItem.submenu = appMenu

    // 窗口菜单：⌘W 关闭窗口。窗口的 windowShouldClose 只隐藏不退出，
    // 所以 ⌘W 走标准 performClose: 即可"关界面但 App 仍驻留菜单栏"。
    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "窗口")
    windowMenu.addItem(
        withTitle: "关闭窗口",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"   // 默认带 ⌘ 修饰键 → ⌘W
    )
    windowMenuItem.submenu = windowMenu

    return mainMenu
}
