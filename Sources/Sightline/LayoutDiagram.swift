import SwiftUI
import SightlineCore

/// A true-aspect diagram of the display with the five boards, the ±22° comfort
/// band, and a degree scale underneath. Everything is drawn from the same
/// geometry the window manager uses, so it cannot drift from reality.
struct LayoutDiagram: View {
    let screen: ScreenInfo
    let layout: ScreenLayout
    let geometry: LayoutGeometry
    let metrics: AttentionMetrics?

    private let tickStrip: CGFloat = 26

    private var visibleSlots: [Slot] {
        layout.splitSides
            ? [.center, .leftTop, .leftBottom, .rightTop, .rightBottom]
            : [.center, .leftTop, .rightTop]
    }

    /// Conversion from AX points to diagram points.
    private func scaleX(_ scale: CGFloat) -> CGFloat { scale }

    var body: some View {
        GeometryReader { proxy in
            let available = CGSize(width: proxy.size.width, height: max(proxy.size.height - tickStrip, 60))
            let scale = min(available.width / screen.frame.width, available.height / screen.frame.height)
            let boardSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
            let originX = (proxy.size.width - boardSize.width) / 2
            let pxPerCM = scale * screen.frame.width / max(screen.physicalWidthCM, 1)

            ZStack(alignment: .topLeading) {
                board(scale: scale, pxPerCM: pxPerCM, size: boardSize)
                    .frame(width: boardSize.width, height: boardSize.height, alignment: .topLeading)
                    .offset(x: originX, y: 0)

                tickScale(pxPerCM: pxPerCM, originX: originX, boardHeight: boardSize.height, scale: scale)
            }
        }
    }

    // MARK: - Board

    private func board(scale: CGFloat, pxPerCM: CGFloat, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .frame(width: size.width, height: size.height)

            chrome(scale: scale, size: size)
            comfortBand(pxPerCM: pxPerCM, size: size)

            ForEach(visibleSlots, id: \.rawValue) { slot in
                if let rect = geometry.rect(for: slot) {
                    slotView(slot: slot, rect: local(rect, scale: scale))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// AX rect → board-local rect.
    private func local(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.minX - screen.frame.minX) * scale,
            y: (rect.minY - screen.frame.minY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// Menu bar and Dock, so the boards visibly live inside the usable area.
    private func chrome(scale: CGFloat, size: CGSize) -> some View {
        let menuBar = local(
            CGRect(
                x: screen.frame.minX,
                y: screen.frame.minY,
                width: screen.frame.width,
                height: max(0, screen.usableFrame.minY - screen.frame.minY)
            ),
            scale: scale
        )
        let dock = local(
            CGRect(
                x: screen.frame.minX,
                y: screen.usableFrame.maxY,
                width: screen.frame.width,
                height: max(0, screen.frame.maxY - screen.usableFrame.maxY)
            ),
            scale: scale
        )
        return Path { path in
            if menuBar.height > 0.5 { path.addRect(menuBar) }
            if dock.height > 0.5 { path.addRect(dock) }
        }
        .fill(Color.white.opacity(0.10))
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The band of screen that sits inside the comfortable no-head-turn cone.
    private func comfortBand(pxPerCM: CGFloat, size: CGSize) -> some View {
        let halfWidth = CGFloat(tan(Attention.comfortHalfAngleDeg * .pi / 180) * layout.viewingDistanceCM) * pxPerCM
        let midX = (screen.usableFrame.midX - screen.frame.minX) * (size.width / screen.frame.width)
        let left = max(midX - halfWidth, 0)
        let right = min(midX + halfWidth, size.width)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.06))
                .frame(width: max(right - left, 0), height: size.height)
                .offset(x: left, y: 0)

            ForEach([left, right], id: \.self) { x in
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
            }

            Text("±22°")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .offset(x: min(right + 4, size.width - 30), y: size.height - 18)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func slotView(slot: Slot, rect: CGRect) -> some View {
        let isCenter = slot == .center
        let wide = rect.width > 110

        return VStack(spacing: 2) {
            Text(slot.label)
                .font(.system(size: isCenter ? 15 : 11, weight: .semibold, design: .rounded))
            if wide {
                Text("\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .opacity(0.7)
            }
            if isCenter, wide, rect.height > 90 {
                Text("main attention")
                    .font(.system(size: 9, weight: .regular))
                    .opacity(0.55)
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(Color.white.opacity(isCenter ? 0.95 : 0.8))
        .frame(width: rect.width, height: rect.height)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isCenter ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    isCenter ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.20),
                    lineWidth: isCenter ? 1.5 : 1
                )
        )
        .position(x: rect.midX, y: rect.midY)
    }

    /// Degree ruler below the display. 0° is the screen centre, and the ticks are
    /// placed with the same trigonometry the metrics badge reports.
    private func tickScale(pxPerCM: CGFloat, originX: CGFloat, boardHeight: CGFloat, scale: CGFloat) -> some View {
        let midX = originX + (screen.usableFrame.midX - screen.frame.minX) * scale
        let angles: [Double] = [-35, -22, 0, 22, 35]

        return ZStack(alignment: .topLeading) {
            ForEach(angles, id: \.self) { angle in
                let x = midX + CGFloat(tan(angle * .pi / 180) * layout.viewingDistanceCM) * pxPerCM
                let isComfort = abs(abs(angle) - Attention.comfortHalfAngleDeg) < 0.5
                let isZero = abs(angle) < 0.5

                Path { path in
                    path.move(to: CGPoint(x: x, y: boardHeight + 3))
                    path.addLine(to: CGPoint(x: x, y: boardHeight + (isZero ? 9 : 6)))
                }
                .stroke(Color.secondary.opacity(isZero ? 0.8 : 0.45), lineWidth: 1)

                Text(isZero ? "0°" : "\(Int(angle))°")
                    .font(.system(size: 9, weight: isComfort ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isComfort ? Color.accentColor : Color.secondary)
                    .position(x: x, y: boardHeight + 16)
            }
        }
    }
}
