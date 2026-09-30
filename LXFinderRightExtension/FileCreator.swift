//
//  FileCreator.swift
//  LXFinderRightExtension
//
//  在指定目录里创建文件。重名绝不覆盖，自动加序号。
//
//  这个文件是**唯一碰用户文件系统的地方**。后续把写盘搬到 XPC helper 时，
//  只需要替换这一层的实现，菜单侧（FinderSync.swift）不用动。
//

import Foundation
import os

enum FileCreationError: LocalizedError {
    /// 没有该目录的写入权限。
    case noPermission(URL)
    /// 其它写盘失败。
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPermission(let directory):
            return "没有权限在「\(directory.lastPathComponent)」里创建文件。请到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里授权 LXFinderRight。"
        case .writeFailed(let reason):
            return "创建文件失败：\(reason)"
        }
    }
}

enum FileCreator {

    private static let logger = Logger(subsystem: "com.linx.LXFinderRight", category: "fileCreator")

    /// 新建文件的基础名，与 Finder 自己的 ⌘⇧N「新建文件夹」命名习惯保持一致。
    private static let baseName = "未命名"

    /// 内置空白模板的资源名：bundle 里存在 `blank.<扩展名>` 就拷它。
    ///
    /// docx / xlsx / pptx 是 OOXML（zip 包），0 字节的空文件会被 Office 判定为损坏，
    /// 所以随包带了最小可用的空白文档。纯文本类格式空文件本身就是合法的，
    /// 没有对应模板，走空文件分支。
    private static let builtinTemplateName = "blank"

    // MARK: - 命名

    /// 从「未命名.<ext>」开始，找一个当前目录里还没被占用的名字：
    /// 未命名.txt → 未命名 2.txt → 未命名 3.txt …
    ///
    /// 用纯数字递增的 while 循环，不去正则解析目录里已有的文件名——那样既慢又有解析歧义
    /// （用户可能自己建过「未命名 99.txt」或者「未命名abc.txt」）。
    /// 序号前有一个空格，跟 Finder 原生行为一致。
    static func availableDefaultName(ext: String, in directory: URL) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = "\(baseName)\(suffix)"
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(baseName) \(n)\(suffix)"
            n += 1
        }
        return candidate
    }

    // MARK: - 创建

    /// 建一个「未命名.<ext>」文件，重名自动加序号。
    ///
    /// 从菜单点击到这里没有任何确认机会，所以**绝不能覆盖**：
    /// `availableDefaultName` 负责避开已存在的名字，写盘 API 本身再兜底一层
    /// （`Data.write` 用 `.withoutOverwriting`，`copyItem` 撞名会直接抛错）。
    @discardableResult
    static func createUntitled(type: FileType, in directory: URL) throws -> URL {
        let ext = FileTypeStore.normalizeExtension(type.ext)
        let name = availableDefaultName(ext: ext, in: directory)
        return try create(named: name, type: type, in: directory)
    }

    /// 在 `directory` 下创建名为 `fileName` 的文件。
    @discardableResult
    static func create(named fileName: String, type: FileType, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        do {
            try writeContent(for: type, to: url)
        } catch {
            throw translate(error, directory: directory)
        }
        logger.info("已创建：\(url.path, privacy: .public)")
        return url
    }

    /// 三级降级地写入内容：
    ///   1. 用户指定的自定义模板
    ///   2. 随包的内置空白模板（目前只有 docx / xlsx / pptx）
    ///   3. 零字节空文件（纯文本类空文件即合法）
    private static func writeContent(for type: FileType, to url: URL) throws {
        let ext = FileTypeStore.normalizeExtension(type.ext)

        if let path = type.templatePath, !path.isEmpty {
            let source = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: url)
                return
            }
            // 模板文件被移走或删掉了。**不报错**，退回空文件——否则这个类型会直接
            // 变成不可用，而用户多半只是整理过一次文件夹，完全想不到是这个原因。
            logger.warning("自定义模板不存在，退回空文件：\(path, privacy: .public)")
        }

        // 扩展名先归一化再查模板：用户在设置里可能填成 ".MD" / " MD "，
        // 而 bundle 里的资源名是固定的小写 blank.docx。
        if let blank = Bundle.main.url(forResource: builtinTemplateName, withExtension: ext) {
            try FileManager.default.copyItem(at: blank, to: url)
            return
        }

        // 用会抛错的 Data.write 而不是只返回 Bool 的 FileManager.createFile(atPath:contents:)——
        // 后者在权限被拒时拿不到失败原因，错误提示只能写成没用的「失败」，
        // 而权限恰恰是唯一有明确补救动作（去系统设置授权）的情况。
        try Data().write(to: url, options: .withoutOverwriting)
    }

    // MARK: - 错误翻译

    /// 把 Foundation 的写盘错误翻译成面向用户的错误。
    ///
    /// 权限单独成一类——它是唯一有明确补救动作的情况。注意沙盒拒绝
    /// （临时豁免没生效）和 TCC 拒绝（用户没授权桌面/文稿）在这里都会
    /// 落到 NSFileWriteNoPermissionError，但两者的补救方式完全不同：
    /// 前者是开发期配置问题，后者要引导用户去授权。所以日志里把原始错误也打出来。
    private static func translate(_ error: Error, directory: URL) -> Error {
        let nsError = error as NSError
        logger.error("写盘失败 domain=\(nsError.domain, privacy: .public) code=\(nsError.code) dir=\(directory.path, privacy: .public) desc=\(nsError.localizedDescription, privacy: .public)")

        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError {
            return FileCreationError.noPermission(directory)
        }
        return FileCreationError.writeFailed(nsError.localizedDescription)
    }
}
