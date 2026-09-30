//
//  FinderSync.swift
//  LXFinderRightExtension
//
//  Finder 右键菜单的唯一入口。
//
//  这个进程是**沙盒**的独立进程（不是 Finder 的一部分，也不是主 App 的一部分），
//  由 launchd 按需拉起、允许空闲退出。三个约束由此而来：
//
//  1. `menu(for:)` 是**同步阻塞**调用——它慢，Finder 的右键菜单就卡。所以这里
//     只允许做轻量操作。当前唯一的 I/O 是读那个约 1KB 的配置文件（见下方说明）。
//  2. action 收到的 sender **不是**我们在 menu(for:) 里创建的那个 NSMenuItem 实例，
//     Finder 会复制菜单项，`representedObject` 在这里不可靠。所以上下文一律靠
//     整数 `tag` 传，再映射回自己的状态表。
//  3. 沙盒里不能起子进程、不能随意 NSWorkspace.open。真正写盘的动作见 FileCreator。
//

import Cocoa
import FinderSync
import os

class FinderSync: FIFinderSync {

    private let logger = Logger(subsystem: "com.linx.LXFinderRight", category: "extension")

    /// 构建当前这个菜单时用到的类型列表。
    ///
    /// 菜单项的 `tag` 存的是**这个数组**的下标，所以点击时必须按这里的顺序取，
    /// 不能在 action 里重新读一遍配置——两次读取之间用户可能刚在设置页改了列表，
    /// 下标就会指错项，点「Word」建出个 txt 来。
    private var typesForCurrentMenu: [FileType] = []

    override init() {
        super.init()

        // 监控全盘。
        //
        // 注意 Finder Sync **不跨文件系统边界**：设成 "/" 覆盖不到 /Volumes 下挂载的
        // 外置卷和 .dmg，那些要遍历 mountedVolumeURLs 单独加进来（本期不做）。
        //
        // 另外 `directoryURLs = nil` 不等于「所有目录」，有开发者实测 nil 不生效，
        // 必须显式给路径。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]

        logConfigDiagnostics()

        logger.info("扩展已启动：\(Bundle.main.bundlePath, privacy: .public)")
    }

    /// 启动时自检配置文件能不能读到，把结果写进日志。
    ///
    /// 存在的理由：配置读不到时 `FileTypeStore.load()` 会**静默退回内置默认列表**，
    /// 症状只是「设置页改了但菜单不生效」——用户不会想到是权限或路径问题，
    /// 我们也只能靠这个日志判断到底是路径解析错了还是读被拒了。
    private func logConfigDiagnostics() {
        let url = FileTypeStore.configURL
        let containerHome = NSHomeDirectory()

        logger.info("自检 · 沙盒容器家目录 = \(containerHome, privacy: .public)")
        logger.info("自检 · 解析出的配置路径 = \(url.path, privacy: .public)")

        do {
            let data = try Data(contentsOf: url)
            let types = FileTypeStore.types(from: String(data: data, encoding: .utf8) ?? "")
            logger.info("自检 · 配置读取成功，\(data.count) 字节，解出 \(types.count) 项，首项 = \(types.first?.name ?? "无", privacy: .public)")
        } catch {
            let nsError = error as NSError
            logger.error("自检 · 配置读取失败 domain=\(nsError.domain, privacy: .public) code=\(nsError.code) desc=\(nsError.localizedDescription, privacy: .public) —— 将退回内置默认列表")
        }
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // 本期只做「右键空白处」。右键文件/文件夹（.contextualMenuForItems）返回 nil，
        // 不污染原生菜单。
        guard menuKind == .contextualMenuForContainer else { return nil }

        // 每次都读一遍配置文件（约 1KB，位于本地 ~/Library/Application Support，走页缓存）。
        //
        // 这里是同步阻塞调用，本该避免 I/O。权衡下来仍然直读，因为：
        //   · 1KB 的读 + 解码在几十微秒量级，相比 Finder 本身渲染右键菜单的耗时可忽略
        //   · 缓存进内存就需要一套失效通知机制，否则用户改了设置要重启 Finder 才生效
        //   · 配置文件在本地磁盘、不受云同步影响，不存在网络卷卡住的风险
        // 如果以后配置里出现大对象或需远程读取，再改成「内存缓存 + 变更通知」。
        typesForCurrentMenu = FileTypeStore.menuTypes(FileTypeStore.load())

        let menu = NSMenu(title: "")

        guard !typesForCurrentMenu.isEmpty else {
            // 用户把类型全关掉时给个占位并说明原因。否则菜单里什么都没有，
            // 看着像功能坏了，用户不会想到是自己在设置里全关掉了。
            let placeholder = NSMenuItem(title: "新建文件（未启用任何类型）", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return menu
        }

        // 收进子菜单。类型数量由用户配置，平铺会把右键菜单撑得很长
        // （默认就有 8 个，用户再加几个就不可用了）。
        let parent = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "新建文件")
        for (index, type) in typesForCurrentMenu.enumerated() {
            let item = NSMenuItem(title: "\(type.name)（.\(type.ext)）",
                                  action: #selector(createFile(_:)),
                                  keyEquivalent: "")
            // tag 存的是 typesForCurrentMenu 的下标。不设 target——action 沿响应链
            // 走到本扩展的 principal object，与 Xcode 模板一致。
            item.tag = index
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    // MARK: - 动作

    @IBAction func createFile(_ sender: AnyObject?) {
        // 目录只能在这里取——`targetedURL()` 只在 menu(for:) 内及其 action 内有效，
        // 换个时机调用返回 nil。
        guard let directory = FIFinderSyncController.default().targetedURL() else {
            logger.error("取不到目标目录，放弃创建")
            return
        }

        // 按 tag 取类型。sender 是 Finder 复制出来的副本，只有 tag 可信。
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        guard typesForCurrentMenu.indices.contains(tag) else {
            logger.error("菜单下标 \(tag) 越界，配置可能刚被改过")
            return
        }
        let type = typesForCurrentMenu[tag]

        do {
            let url = try FileCreator.createUntitled(type: type, in: directory)
            logger.info("创建成功：\(url.path, privacy: .public)")
            reveal(url, in: directory)
        } catch {
            logger.error("创建失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 在 Finder 里选中刚创建的文件。
    ///
    /// 走 Launch Services，**不需要**「控制 Finder」的自动化授权。
    /// 先试在已知目录上开窗选中，失败再退回 activateFileViewerSelecting
    /// （没有任何 Finder 窗口时前者可能只把 Finder 唤到前台却不给窗口）。
    private func reveal(_ url: URL, in directory: URL) {
        if !NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
