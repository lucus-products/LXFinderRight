//
//  LXFinderRightApp.swift
//  LXFinderRight
//
//  主 App。这里只做一件事：管理「新建文件」的类型列表。
//
//  真正干活的是 Finder 扩展（LXFinderRightExtension），它由 Finder 按需拉起，
//  不依赖主 App 是否在运行。两边通过 App Group 共享那份类型配置。
//

import SwiftUI

@main
struct LXFinderRightApp: App {
    var body: some Scene {
        WindowGroup("LXFinderRight") {
            SettingsView()
        }
        // 窗口按内容自适应，但没有内容时也要有个合适的初始尺寸。
        .defaultSize(width: 620, height: 480)
        .windowResizability(.contentMinSize)
    }
}
