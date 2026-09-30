//
//  FileType.swift
//  Shared
//
//  「新建文件」里的一种文件类型（菜单里的一项），以及它的持久化。
//
//  这个文件同时编进主 App（设置页增删改）和 Finder 扩展（渲染菜单）两个 target，
//  所以不能 import AppKit 之外有副作用的东西，也不能依赖任一侧的运行时状态。
//

import Foundation

struct FileType: Codable, Identifiable, Hashable {

    /// 稳定标识：SwiftUI 列表身份、上下移动与删除都靠它。
    let id: UUID
    /// 菜单与设置页里显示的名字，如「Word 文档」。
    var name: String
    /// 扩展名，不含点，如 "docx"。
    var ext: String
    /// 是否出现在菜单里。
    var enabled: Bool
    /// 用户指定的模板文件路径（绝对路径）。nil 表示走内置模板或空文件。
    var templatePath: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, ext, enabled, templatePath
    }

    init(id: UUID = UUID(),
         name: String,
         ext: String,
         enabled: Bool = true,
         templatePath: String? = nil) {
        self.id = id
        self.name = name
        self.ext = ext
        self.enabled = enabled
        self.templatePath = templatePath
    }

    /// 宽容解码：单个字段缺失或类型不对时退回默认值，而不是让整份配置解码失败。
    ///
    /// 两个场景会用到：以后给 FileType 加字段（老 JSON 里没有），以及用户手改配置文件。
    /// 硬失败会让整个列表被静默重置成默认值，用户配了半天的类型全丢。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        ext = (try? container.decode(String.self, forKey: .ext)) ?? ""
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        // templatePath 是新增字段——老配置里没有，解出来是 nil，正好是「用内置模板」。
        templatePath = try? container.decode(String.self, forKey: .templatePath)
    }
}

enum FileTypeStore {

    /// 配置文件相对家目录的路径。
    ///
    /// 为什么不用 App Group：App Group 是「能力」（capability），必须由 provisioning
    /// profile 背书。自动签名生成的是开发用 profile，会**绑定设备 UUID**（只认本机）
    /// 且**7 天过期**——装到别人机器上跑不起来，发出去的包很快变砖。
    /// 改用一个共享文件后，两个 target 都不需要任何 capability，分发干净。
    static let configRelativePath = "Library/Application Support/LXFinderRight/fileTypes.json"

    /// 真实家目录。
    ///
    /// **不能用 `FileManager.urls(for:in:)` 或 `NSHomeDirectory()`**：Finder 扩展是沙盒
    /// 进程，这两个 API 在它里面返回的是沙盒容器路径（`~/Library/Containers/.../Data`），
    /// 而主 App 是非沙盒的，同一个 API 返回真实家目录。两边解析出不同的路径，
    /// 配置文件就永远对不上——而且不报错，只表现成「改了设置没反应」。
    ///
    /// `getpwuid` 查的是系统账户数据库，不受沙盒影响，两边必然一致。
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// 配置文件位置。主 App 与 Finder 扩展读写的是同一个文件。
    static var configURL: URL {
        realHomeDirectory.appendingPathComponent(configRelativePath)
    }

    // MARK: - 默认列表

    /// 内置默认列表，顺序即菜单顺序。
    ///
    /// 不含 `.doc` / `.xls` / `.ppt`：这几个是 OLE2 二进制格式，没法合成出最小可用的
    /// 空白文件，留在默认列表里只会得到一个双击报损坏的菜单项。用户想要可以自己加。
    static let defaultTypes: [FileType] = [
        FileType(id: defaultID(1), name: "Markdown", ext: "md"),
        FileType(id: defaultID(2), name: "文本文件", ext: "txt"),
        FileType(id: defaultID(3), name: "JSON", ext: "json"),
        FileType(id: defaultID(4), name: "YAML", ext: "yml"),
        FileType(id: defaultID(5), name: "HTML", ext: "html"),
        FileType(id: defaultID(6), name: "Word 文档", ext: "docx"),
        FileType(id: defaultID(7), name: "Excel 工作簿", ext: "xlsx"),
        FileType(id: defaultID(8), name: "PowerPoint 演示文稿", ext: "pptx"),
    ]

    /// 生成内置类型的固定 id。
    ///
    /// 不能写成 `UUID()`：默认列表会被反复解码去做 SwiftUI 的 ForEach 身份比对，
    /// 每次现生成新 id 会让列表身份抖动，导致绑定串行、动画错乱。
    private static func defaultID(_ n: Int) -> UUID {
        // 强制解包安全：格式串固定，n 落在 %012d 范围内时一定是合法 UUID 字面量。
        UUID(uuidString: String(format: "1F000000-0000-4000-8000-%012d", n))!
    }

    // MARK: - 解码

    /// 空内容和解码失败都退回默认列表。
    ///
    /// 「文件不存在」代表首次运行；「能解出空数组 `[]`」代表用户主动把类型删光了，
    /// 这个要尊重，不能拿默认值盖回去。
    static func types(from json: String) -> [FileType] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([FileType].self, from: data)
        else { return defaultTypes }
        return list
    }

    /// 从配置文件读。文件不存在或读不出来则返回默认列表，**不抛错**——
    /// 首次运行时文件本来就不存在；扩展侧更是任何时候都必须能渲染出菜单，
    /// 不能因为配置读不到就整个菜单消失。
    static func load() -> [FileType] {
        guard let data = try? Data(contentsOf: configURL) else { return defaultTypes }
        guard let list = try? JSONDecoder().decode([FileType].self, from: data) else {
            return defaultTypes
        }
        return list
    }

    /// 菜单里实际要显示的类型：规范化后，保留「启用」且「扩展名非空」的项。
    ///
    /// 扩展名为空的是用户在设置页点了「添加类型」还没填完的草稿，
    /// 拿去建文件会得到一个没有扩展名的文件，不该出现在菜单里。
    static func menuTypes(_ list: [FileType]) -> [FileType] {
        list.map { normalize($0) }.filter { $0.enabled && !$0.ext.isEmpty }
    }

    // MARK: - 编码与保存

    /// 编码成写进配置文件的 JSON。失败返回空串（而非半截 JSON）。
    static func encode(_ list: [FileType]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }

    /// 写回配置文件。原子写入，避免扩展读到写了一半的半截 JSON。
    static func save(_ list: [FileType]) throws {
        let url = configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(list)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 规范化

    /// 规范化一条类型：显示名去首尾空白；扩展名去空白、去首尾的点和转小写。
    ///
    /// 只在保存与建文件时调用，**不要**放进输入框的 binding setter——中文输入法
    /// 有拼音候选的 marked text 阶段，在 setter 里改写字符串会打断输入法合成、光标乱跳。
    static func normalize(_ type: FileType) -> FileType {
        var result = type
        result.name = type.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.ext = normalizeExtension(type.ext)
        return result
    }

    /// 规范化扩展名：去空白、去首尾的点和转小写。
    /// 用户在设置页很容易填成「.MD」「 md 」，统一在这里收干净，调用方不必各自处理。
    static func normalizeExtension(_ ext: String) -> String {
        ext.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
