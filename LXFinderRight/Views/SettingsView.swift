//
//  SettingsView.swift
//  LXFinderRight
//
//  「新建文件」的类型列表管理。
//

import AppKit
import SwiftUI

struct SettingsView: View {

    /// 本地编辑态。不每敲一个字符就写一次文件——那样既费 I/O，扩展侧也会在你打字的
    /// 中途读到半成品配置。所以本地编辑、防抖写回。
    @State private var types: [FileType] = []
    /// 防抖任务：连续输入时只保留最后一次写回。
    @State private var saveTask: Task<Void, Never>?
    /// 最近一次「已同步」的 JSON，用来区分「用户改了」和「onAppear 刚装载」。
    @State private var lastSyncedJSON = ""
    /// 写盘失败提示。配置写不进去必须让用户看见，否则会表现成「设置改了但没生效」。
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("新建文件类型") {
                Text("勾选 = 出现在 Finder 右键菜单里；上下顺序即菜单顺序。扩展名为空的不会出现在菜单里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if types.isEmpty {
                    Text("还没有任何类型。点下面的「添加类型」新增，或「恢复默认」。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($types) { $type in
                        row(for: $type)
                    }
                }

                HStack {
                    Button("添加类型") {
                        types.append(FileType(name: "新类型", ext: ""))
                    }
                    Button("恢复默认") {
                        types = FileTypeStore.defaultTypes
                    }
                }
            }

            Section {
                Text("内置的 docx / xlsx / pptx 会创建可直接双击打开的空白文档；其它格式创建空文件。也可以为某个类型指定自己的模板文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("配置文件：\(FileTypeStore.configURL.path)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        // 用单参数版本：双参数（old/new）的 onChange 要 macOS 14+，本工程最低支持 13。
        .onChange(of: types) { newValue in scheduleSave(newValue) }
        .onDisappear { saveNow() }
        .onAppear {
            types = FileTypeStore.load()
            // 把当前值记成「已同步」。不记的话，`onAppear` 的装载会触发 `onChange`，
            // 于是「只是打开了一下窗口」就会把当前值固化写回文件。
            lastSyncedJSON = encoded(types)
        }
        .alert("配置保存失败", isPresented: .constant(saveError != nil)) {
            Button("好") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - 行

    private func row(for type: Binding<FileType>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: type.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("是否出现在菜单里")

            // 标题用 labelsHidden 藏掉：Form 里 TextField 会把标题渲染成左侧标签，
            // 而表格化的行要求「勾选框 + 输入框 + 按钮」都待在同一横线上。
            TextField("显示名", text: type.name, prompt: Text("显示名"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("显示名")

            TextField("扩展名", text: type.ext, prompt: Text("md"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 64)
                .accessibilityLabel("扩展名")

            templateButton(for: type)
            rowButtons(type.wrappedValue)
        }
    }

    /// 模板选择按钮。选了模板就换成带省略号的图标，没选是空心——一眼看出哪些类型用了自定义模板。
    private func templateButton(for type: Binding<FileType>) -> some View {
        let hasTemplate = !(type.wrappedValue.templatePath ?? "").isEmpty
        return Button {
            chooseTemplate(for: type)
        } label: {
            Image(systemName: hasTemplate ? "doc.badge.ellipsis" : "doc")
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(hasTemplate
              ? "自定义模板：\(type.wrappedValue.templatePath ?? "")\n（点按可重选）"
              : "选用自定义模板文件（不选则创建空白文件）")
        .accessibilityLabel("选择模板")
    }

    @ViewBuilder
    private func rowButtons(_ type: FileType) -> some View {
        // 按钮组整体右对齐，各行位置一致。
        HStack(spacing: 4) {
            Button { move(type.id, by: -1) } label: {
                Image(systemName: "arrow.up").frame(width: 12, height: 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(types.first?.id == type.id)
            .help("上移")
            .accessibilityLabel("上移")

            Button { move(type.id, by: 1) } label: {
                Image(systemName: "arrow.down").frame(width: 12, height: 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(types.last?.id == type.id)
            .help("下移")
            .accessibilityLabel("下移")

            Button { remove(type.id) } label: {
                Image(systemName: "trash").frame(width: 12, height: 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("删除")
            .accessibilityLabel("删除")
        }
    }

    // MARK: - 模板选择

    private func chooseTemplate(for type: Binding<FileType>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择用作「\(type.wrappedValue.name)」模板的文件"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        type.wrappedValue.templatePath = url.path
    }

    // MARK: - 增删排序
    //
    // 三者都按 id 定位而不是记下标：`ForEach($types)` 里行内改元素时，
    // SwiftUI 内部仍持有按下标的绑定，按 id 找更稳；按下标删元素还有已知的越界崩溃。

    private func move(_ id: UUID, by offset: Int) {
        guard let index = types.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard types.indices.contains(target) else { return }
        types.swapAt(index, target)
    }

    private func remove(_ id: UUID) {
        types.removeAll { $0.id == id }
    }

    // MARK: - 写回

    /// 规范化的 JSON。装填哨兵与写回**必须都走这个函数**——两侧口径不一致的话
    /// 哨兵比对会永远判成「变了」，一打开设置页就把当前值写回文件。
    private func encoded(_ list: [FileType]) -> String {
        FileTypeStore.encode(list.map { FileTypeStore.normalize($0) })
    }

    private func scheduleSave(_ newValue: [FileType]) {
        let json = encoded(newValue)
        // 值没实际变化就直接返回。这个比对不是性能优化，是必需的：
        // `onAppear` 装载列表也会触发 `onChange`。
        guard json != lastSyncedJSON else { return }

        saveTask?.cancel()
        saveTask = Task {
            // 防抖：连续输入时只保留最后一次，避免每敲一个字符就写一次文件。
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit(newValue, json: json)
        }
    }

    /// 立即写回。窗口关闭时兜底，避免丢掉最后 400ms 内的输入。
    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let json = encoded(types)
        guard json != lastSyncedJSON else { return }
        commit(types, json: json)
    }

    private func commit(_ list: [FileType], json: String) {
        do {
            try FileTypeStore.save(list.map { FileTypeStore.normalize($0) })
            lastSyncedJSON = json
        } catch {
            // 不更新哨兵：这样用户下次改动时还会再试一次，而不是以为已经存好了。
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView()
}
