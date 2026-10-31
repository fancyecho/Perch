import PerchLine
import SwiftUI

/// Where Settings finds the screenshot line, while it's on.
enum LineHost {
    static var controller: () -> LineController? = { nil }
}

/// Settings › Line: the screenshot line, adapted from Tendedero, with the choices its own menu had.
struct LinePane: View {
    @AppStorage(Pref.lineEnabled) private var enabled = true
    /// The line keeps its settings itself; this redraws the page after one changes.
    @State private var revision = 0

    var body: some View {
        let line = enabled ? LineHost.controller() : nil
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    SettingLabel(tr("截图晾衣绳", "Screenshot line"),
                                 tr("截下的图挂在屏幕顶部的绳子上：点一下复制，按住标记，拖进 App 或文件夹。绳子分成左右两段，中间留给灵动岛和胶囊。",
                                    "Screenshots hang on a line along the top of the screen: click to copy, hold to mark up, drag into an app or folder. The line is two, either side of the island and the capsule."))
                }
            } footer: {
                Text(tr("改编自 Alejandro Buján 的开源项目 Tendedero（MIT 许可）。", "Adapted from Tendedero by Alejandro Buján (MIT License)."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let line {
                Section(tr("截图", "Screenshots")) {
                    Toggle(isOn: binding(line, \.handlesScreenshots)) {
                        SettingLabel(tr("接管截图", "Handle screenshots"),
                                     tr("截图即刻挂上绳，不再出现浮动缩略图，也不会堆到桌面；改的是「⌘⇧5 › 选项」里的两项，关掉或退出 Perch 时还原。",
                                        "Screenshots hang at once, with no floating thumbnail and nothing left on the Desktop. This changes two settings under ⌘⇧5 › Options, put back when turned off or Perch quits."))
                    }
                    Toggle(isOn: binding(line, \.hangsCopiedImages)) {
                        SettingLabel(tr("挂上复制的图片", "Hang copied images"),
                                     tr("复制的图片也挂上绳；和文字一起复制的、密码管理器标为私密的不会。",
                                        "Images you copy hang too; nothing copied with text, or marked private by a password manager."))
                    }
                    LabeledContent(tr("同时监视的文件夹", "Also watch folders")) {
                        Button(tr("添加…", "Add…")) {
                            line.addWatchedFolder()
                            revision += 1
                        }
                        .disabled(line.watchedFolders.count >= 3)
                    }
                    ForEach(line.watchedFolders, id: \.self) { folder in
                        LabeledContent(FileManager.default.displayName(atPath: folder.path)) {
                            Button(tr("停止监视", "Stop Watching")) {
                                line.stopWatching(folder)
                                revision += 1
                            }
                        }
                    }
                    Button(tr("打开截图文件夹", "Open Screenshots Folder")) { line.openScreenshotsFolder() }
                }

                Section(tr("放下晾衣绳", "Bring the line down")) {
                    Toggle(isOn: staticBinding(get: { LineController.opensFromMenuBar }, set: { LineController.opensFromMenuBar = $0 })) {
                        SettingLabel(tr("指针顶到屏幕上沿时", "When the pointer reaches the top edge"),
                                     tr("屏幕顶部正中留给灵动岛和胶囊，在其他位置把指针移到最上方并稍停，或停在灵动岛两侧的菜单栏。",
                                        "The middle of the top belongs to the island and the capsule: push against the top edge anywhere else, or rest beside the island in the menu bar."))
                    }
                    Toggle(tr("有新截图挂上时", "When something new hangs"),
                           isOn: staticBinding(get: { LineController.peeksAtNew }, set: { LineController.peeksAtNew = $0 }))
                    Toggle(isOn: binding(line, \.showsOverFullScreen)) {
                        SettingLabel(tr("在全屏 App 上", "Over full screen apps"),
                                     tr("关掉后，全屏看视频、放幻灯片时晾衣绳不会自己放下，只能用快捷键或菜单打开。",
                                        "Off, the line stays up over full screen videos and presentations, unless opened with the shortcut or the menu."))
                    }
                    LabeledContent(tr("快捷键", "Shortcut")) {
                        HStack(spacing: 8) {
                            Text(line.shortcutText)
                                .monospaced()
                                .foregroundStyle(.secondary)
                            Button(tr("更改…", "Change…")) { line.recordShortcut() }
                        }
                    }
                }

                Section(tr("外观", "Look")) {
                    Picker(tr("大小", "Size"), selection: binding(line, \.sizeIndex)) {
                        Text(tr("小", "Small")).tag(0)
                        Text(tr("中", "Medium")).tag(1)
                        Text(tr("大", "Large")).tag(2)
                    }
                    Picker(tr("绳上保留", "Keep on line"), selection: binding(line, \.keepCount)) {
                        Text(tr("放得下的数量", "As many as fit")).tag(Int?.none)
                        ForEach(LineController.keepChoices, id: \.self) { n in
                            Text(tr("\(n) 张", "\(n) photos")).tag(Int?.some(n))
                        }
                    }
                    Toggle(tr("声音", "Sounds"), isOn: binding(line, \.playsSounds))
                }
            }
        }
        .id(revision)
        // The shortcut is recorded in a window of the line's own; show it once that closes.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in revision += 1 }
    }

    private func binding<Value>(_ line: LineController, _ keyPath: ReferenceWritableKeyPath<LineController, Value>) -> Binding<Value> {
        Binding(get: { line[keyPath: keyPath] }, set: {
            line[keyPath: keyPath] = $0
            revision += 1
        })
    }

    private func staticBinding(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: {
            set($0)
            revision += 1
        })
    }
}
