<p align="center"><img src="docs/icon.png" width="128" alt="Perch icon"></p>

<h1 align="center">Perch</h1>

<p align="center">停在屏幕角落的待办小鸟：一枚始终置顶的玻璃胶囊，悬停预览，点击展开。</p>

Perch 是一个轻量的 macOS 原生待办浮窗（SwiftUI + AppKit，无第三方依赖）。设计说明见 [DESIGN.md](DESIGN.md)。

## 功能

- **三种形态**：胶囊 → 悬停预览 → 完整面板，从胶囊所在的角弹性展开；拖动后自动吸附屏幕边缘
- **自然语言输入**：`明天下午3点 写周报 !! #工作`、`下周三 交报告`、`call mom tomorrow 5pm p1`
- **手势**：在任务上触控板向右扫或鼠标向右拖完成，向左推迟到明天；双击编辑，右键更多
- **专注模式**、撤销、闲置淡化、到点通知
- **全局快捷键**可自定义（默认 `⌥ Space`）
- **中文 / English** 界面实时切换；**时区**可选，正确处理夏令时
- **自动更新**：从 GitHub Releases 获取，安装包经 Ed25519 签名校验后才会安装

## 安装

1. 从 [Releases](https://github.com/fancyecho/Perch/releases/latest) 下载 `Perch-x.y.z.zip`，解压后把 `Perch.app` 拖进「应用程序」。
2. Perch 未经 Apple 公证，第一次打开会被系统拦下。任选一种方式放行：
   - 打开「系统设置 → 隐私与安全性」，在下方找到 Perch，点「仍要打开」；或
   - 在终端执行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/Perch.app
     ```
3. 之后的版本会在应用内提示更新（⋯ 菜单 / 设置 → 更新），一键安装并重启。

需要 macOS 26 或更高版本。

## 用法速查

| 操作 | 方式 |
|---|---|
| 唤出 / 收起 | 全局快捷键（设置里点一下再按新组合即可修改） |
| 收起 | `Esc` |
| 切换分组 / 新任务 | `⌘1`–`⌘4` / `⌘N` |
| 日期 | 明天、后天、周五、下周三、10月1日、tomorrow、next fri、10/1 |
| 时间 | 下午3点、晚上8点半、15:30、3pm、2小时后、in 30 min |
| 优先级 | `!` / `!!` / `!!!` 或 `p3` / `p2` / `p1` |
| 标签 | `#工作` |

数据保存在 `~/Library/Application Support/Perch/tasks.json`。

## 从源码构建

需要 Xcode 26+（Swift 6.2）。

```bash
scripts/build.sh release --run
```

```bash
swift test
```

重新生成图标：`swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`

## 发布新版本（维护者）

更新包用 Ed25519 签名，私钥只保存在维护者本机（默认 `~/.config/perch/update_ed25519.key`，**务必备份**，丢失后旧版本将无法验证新的更新），公钥写在 `Resources/Info.plist` 的 `PerchUpdatePublicKey`。

1. 首次：`swift scripts/sign-update.swift --generate`，把输出的公钥填进 Info.plist。
2. 写好 `docs/releases/<版本号>.md`，提交所有改动。
3. 执行：
   ```bash
   scripts/release.sh 0.2.0 --publish
   ```
   脚本会更新版本号、构建、打包 `Perch-0.2.0.zip`、生成签名 `.sig`，并创建 GitHub Release `v0.2.0`。版本号改动会留在工作区，记得随后提交。
