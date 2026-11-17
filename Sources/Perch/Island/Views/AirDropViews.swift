import SwiftUI

/// AirDrop's blue, a little lighter toward the edge of its waves.
enum AirDropColor {
    static let deep = Color(red: 0.16, green: 0.55, blue: 1)
    static let light = Color(red: 0.42, green: 0.82, blue: 1)
}

// MARK: - The drop zone

/// The island opened to catch a parcel dragged up to it. Waves spread out of the camera, as if the
/// notch were already looking for devices nearby; held over the island they quicken, the parcel
/// fans out and lifts, and let go it rises into the camera.
struct DropZoneView: View {
    let session: DropSession
    @Environment(IslandModel.self) private var model

    var body: some View {
        let notch = model.geometry.notchSize
        ZStack(alignment: .top) {
            RadarWaves(source: CGPoint(x: 0.5, y: notch.height / 2), isTargeted: session.isTargeted, isLaunching: session.isLaunching)
            VStack(spacing: 0) {
                Color.clear.frame(height: notch.height)
                HStack(spacing: 14) {
                    ParcelStack(icons: session.icons, count: session.count, isLifted: session.isTargeted, isLaunching: session.isLaunching)
                        .frame(width: 58, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.isTargeted ? tr("松手，隔空投送", "Let go to AirDrop") : tr("拖到这里，隔空投送", "Drop here to AirDrop"))
                            .font(.system(size: 13.5, weight: .semibold))
                            .contentTransition(.interpolate)
                        Text(session.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .opacity(session.isLaunching ? 0 : 1)
                    .frame(maxWidth: 190, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .padding(.bottom, 8)
            }
        }
        .foregroundStyle(.white)
        .animation(.smooth(duration: 0.25), value: session.isTargeted)
    }
}

/// Rings rising out of the camera and fading as they spread across the island.
private struct RadarWaves: View {
    /// x as a fraction of the width, y in points from the top.
    let source: CGPoint
    let isTargeted: Bool
    let isLaunching: Bool
    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                let center = CGPoint(x: size.width * source.x, y: source.y)
                let reach = hypot(size.width / 2, size.height - source.y) + 10
                let rings = 3
                // Quicker and brighter with something held over it; one bright burst as it's sent.
                let speed = isLaunching ? 1.4 : isTargeted ? 0.62 : 0.34
                let strength = isLaunching ? 1.0 : isTargeted ? 0.85 : 0.5
                for ring in 0..<rings {
                    let phase = (time * speed + Double(ring) / Double(rings)).truncatingRemainder(dividingBy: 1)
                    let radius = 18 + phase * reach
                    let fade = pow(1 - phase, 1.6) * strength
                    let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    canvas.stroke(circle, with: .color(AirDropColor.light.opacity(fade * 0.35)), lineWidth: 7)
                    canvas.stroke(circle, with: .color(AirDropColor.deep.opacity(fade)), lineWidth: isTargeted ? 1.6 : 1.1)
                }
            }
            .blur(radius: 0.3)
        }
        // A glow pooling under the camera while something is held over it.
        .background {
            RadialGradient(colors: [AirDropColor.deep.opacity(isTargeted ? 0.34 : 0.14), .clear],
                           center: UnitPoint(x: source.x, y: 0), startRadius: 0, endRadius: 170)
        }
        .allowsHitTesting(false)
    }
}

/// What's being dragged, as a little stack of its icons; fanned out while held over the island.
private struct ParcelStack: View {
    let icons: [NSImage]
    let count: Int
    let isLifted: Bool
    let isLaunching: Bool

    var body: some View {
        ZStack {
            ForEach(Array(icons.prefix(3).enumerated()).reversed(), id: \.offset) { index, icon in
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .rotationEffect(.degrees(angle(index)))
                    .offset(x: spread(index), y: index == 0 ? 0 : 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(AirDropColor.deep))
                    .offset(x: 6, y: -4)
            }
        }
        .scaleEffect(isLaunching ? 0.12 : isLifted ? 1.1 : 1)
        .offset(x: isLaunching ? 66 : 0, y: isLaunching ? -58 : isLifted ? -3 : 0)
        .opacity(isLaunching ? 0 : 1)
        .animation(.spring(duration: 0.38, bounce: 0.4), value: isLifted)
    }

    private func angle(_ index: Int) -> Double {
        let fan = isLifted ? 1.6 : 1
        switch index {
        case 1: return -9 * fan
        case 2: return 9 * fan
        default: return 0
        }
    }

    private func spread(_ index: Int) -> CGFloat {
        let fan: CGFloat = isLifted ? 1.7 : 1
        switch index {
        case 1: return -6 * fan
        case 2: return 6 * fan
        default: return 0
        }
    }
}

// MARK: - Beside the notch

/// How a parcel is getting on, beside the notch: the waves keep going while it's on its way.
struct AirDropWings: View {
    let status: AirDropStatus

    var body: some View {
        WingsLayout {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [AirDropColor.light, AirDropColor.deep], startPoint: .top, endPoint: .bottom))
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: isSending)
                    // Once it's over, the waves stand still at full strength rather than mid-pulse.
                    .symbolEffectsRemoved(!isSending)
                    .frame(minWidth: 18)
                Text(tr("隔空投送", "AirDrop"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
        } trailing: {
            Group {
                switch status {
                case .sending(let label):
                    Text(label)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .sent(let count):
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AirDropColor.light)
                            .symbolEffect(.bounce, value: count)
                        Text(count > 1 ? tr("已送出 \(count) 个", "\(count) sent") : tr("已送出", "Sent"))
                    }
                case .failed:
                    Text(tr("没有送出", "Not sent"))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
    }

    private var isSending: Bool {
        if case .sending = status { return true }
        return false
    }
}

// MARK: - The open island with nothing playing

/// A row of quick things to do, where the player would be: AirDrop some files or what was just
/// copied, start focusing, bring the screenshot line down.
struct QuickShelf: View {
    @Environment(IslandModel.self) private var model
    @Environment(FocusController.self) private var focus
    /// Judged from the clipboard's types alone; it's only read once sent.
    @State private var clipboard: ShareParcel.Kind?

    var body: some View {
        HStack(spacing: 0) {
            ShelfTile(symbol: "dot.radiowaves.up.forward", title: tr("隔空投送", "AirDrop"), tint: AirDropColor.deep,
                      help: tr("选择文件隔空投送。也可以直接把文件、图片或链接拖到刘海。", "Choose files to AirDrop. Or drag files, images or links straight onto the notch.")) {
                model.shareHandler?(.chooseFiles)
            }
            ShelfTile(symbol: clipboardSymbol, title: clipboardTitle, tint: Color(red: 0.2, green: 0.78, blue: 0.72),
                      help: clipboard == nil ? tr("复制文件、图片或链接后，可以在这里隔空投送", "Copy a file, image or link to AirDrop it from here") : tr("把刚复制的内容隔空投送到附近的设备", "AirDrop what you just copied to a device nearby"),
                      isEnabled: clipboard != nil) {
                model.shareHandler?(.clipboard)
            }
            ShelfTile(symbol: "moon.fill", title: tr("专注", "Focus"), tint: Color(red: 0.45, green: 0.42, blue: 1),
                      help: tr("模糊所有屏幕，开始专注", "Blur every screen and start focusing")) {
                focus.startSession()
            }
            if LineHost.controller() != nil {
                ShelfTile(symbol: "photo.on.rectangle.angled", title: tr("晾衣绳", "Line"), tint: Color(red: 1, green: 0.62, blue: 0.3),
                          help: tr("放下或收起截图晾衣绳", "Bring the screenshot line down or put it away")) {
                    LineHost.controller()?.toggleLine()
                }
            }
        }
        .task { clipboard = await ShareParcel.peekClipboard() }
    }

    private var clipboardSymbol: String {
        switch clipboard {
        case .link: "link"
        case .image: "photo"
        case .files: "doc.on.doc"
        case nil: "doc.on.clipboard"
        }
    }

    private var clipboardTitle: String {
        switch clipboard {
        case .link: tr("投送链接", "Send Link")
        case .image: tr("投送图片", "Send Image")
        case .files: tr("投送文件", "Send Files")
        case nil: tr("剪贴板", "Clipboard")
        }
    }
}

/// A round button with its name under it; it lights up in its own color under the pointer, the way
/// Control Center's do when switched on.
private struct ShelfTile: View {
    let symbol: String
    let title: String
    let tint: Color
    let help: String
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(lit ? .white : (isEnabled ? tint : .white.opacity(0.3)))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(lit ? tint : Color.white.opacity(0.09)))
                    .shadow(color: lit ? tint.opacity(0.55) : .clear, radius: 8)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(isEnabled ? (hovering ? 0.9 : 0.55) : 0.3))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(help)
    }

    private var lit: Bool { hovering && isEnabled }
}
