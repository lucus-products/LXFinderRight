//
//  FileType.swift
//  Shared
//
//  「新建文件」里的一种文件类型（菜单里的一项）。
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
    /// 两个场景会用到：以后给 FileType 加字段（老 JSON 里没有），以及用户手改
    /// UserDefaults 里的 JSON。硬失败会让整个列表被静默重置成默认值，
    /// 用户配了半天的类型全丢。
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

    /// App Group：主 App 与 Finder 扩展共享配置的唯一通道。
    ///
    /// 两侧都是沙盒进程，直接用 `UserDefaults.standard` 读写的是各自的容器，
    /// 互相看不见。App Group 是官方提供的跨进程共享方式。
    static let appGroupID = "group.com.linx.LXFinderRight"

    /// 存进 App Group UserDefaults 的键，值是 `[FileType]` 的 JSON 字符串。
    static let defaultsKey = "fileTypes"

    /// 共享的 UserDefaults。拿不到时返回 nil（App Group 没配好），调用方各自降级。
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
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
    /// 这里用固定前缀 + 序号拼出跨进程稳定的值。
    private static func defaultID(_ n: Int) -> UUID {
        // 强制解包安全：格式串固定，n 落在 %012d 范围内时一定是合法 UUID 字面量。
        UUID(uuidString: String(format: "1F000000-0000-4000-8000-%012d", n))!
    }

    // MARK: - 读写

    /// 空串和解码失败都退回默认列表。
    ///
    /// 空串代表「首次运行」——`@AppStorage` 的默认值不会写进 UserDefaults，
    /// 所以键不存在时读到的就是 `""`，而 `""` 不是合法 JSON，两种「没有配置」
    /// 的情况天然落在同一个分支。
    ///
    /// 能解出空数组 `[]` 则返回空：那是用户主动把类型删光了，要尊重，
    /// 不能拿默认值盖回去。
    static func types(from json: String) -> [FileType] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([FileType].self, from: data)
        else { return defaultTypes }
        return list
    }

    /// 从共享 UserDefaults 直接读列表。
    static func typesFromSharedDefaults() -> [FileType] {
        types(from: sharedDefaults?.string(forKey: defaultsKey) ?? "")
    }

    /// 菜单里实际要显示的类型：规范化后，保留「启用」且「扩展名非空」的项。
    ///
    /// 扩展名为空的是用户在设置页点了「添加类型」还没填完的草稿，
    /// 拿去建文件会得到一个没有扩展名的文件，不该出现在菜单里。
    static func menuTypes(from json: String) -> [FileType] {
        types(from: json)
            .map { normalize($0) }
            .filter { $0.enabled && !$0.ext.isEmpty }
    }

    /// 编码成存进 UserDefaults 的 JSON。失败返回空串（而非半截 JSON），
    /// 让读取端退回默认值。
    static func encode(_ types: [FileType]) -> String {
        guard let data = try? JSONEncoder().encode(types),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
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
