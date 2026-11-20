import AppKit
import SightlineCore

/// A small, non-interactive overlay used to confirm state changes without
/// stealing focus. Appears near the bottom of the active screen and fades out.
@MainActor
final class HUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var pendingHide: DispatchWorkItem?

    func show(_ text: String, on axRect: CGRect) {
        let panel = ensurePanel()
        guard let label else { return }

        label.stringValue = text
        let textSize = label.intrinsicContentSize
        let width = min(max(textSize.width + 34, 120), 720)
        let height = max(textSize.height + 20, 38)

        let axX = axRect.midX - width / 2
        let axY = axRect.maxY - 96 - height
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let appKit = ScreenSpace.appKitRect(
            fromAX: CGRect(x: axX, y: axY, width: width, height: height),
            primaryHeight: primaryHeight
        )
        panel.setFrame(appKit, display: false)
        label.frame = NSRect(x: 17, y: (height - textSize.height) / 2, width: width - 34, height: textSize.height)

        pendingHide?.cancel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }

        let hide = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: hide)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none

        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        effect.addSubview(label)

        panel.contentView = effect
        self.panel = panel
        self.label = label
        return panel
    }
}
