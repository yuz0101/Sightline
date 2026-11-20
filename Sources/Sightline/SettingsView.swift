import SwiftUI
import SightlineCore

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var onArrange: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.trusted { permissionCard }
                    if !model.unavailable.isEmpty { conflictCard }
                    screenCard
                    layoutCard
                    quickMenuCard
                    shortcutsCard
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        // Pin the root to the window: a ScrollView that reports its content
        // height as its ideal size makes the whole view taller than the
        // window, and AppKit then maps clicks to the wrong rows.
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sightline")
                    .font(.system(size: 20, weight: .semibold))
                Text("Attention-weighted boards for a wide display")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let screen = model.screen {
                Label(
                    "\(screen.name) · \(Int(screen.physicalWidthCM.rounded())) cm wide",
                    systemImage: "display"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.trusted ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.trusted ? "Accessibility access granted" : "Accessibility access required")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reveal settings folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: model.preferencesPath))
            }
            .font(.system(size: 11))
            Button("Arrange now") { onArrange?() }
                .font(.system(size: 11, weight: .medium))
                .disabled(onArrange == nil)
            Button("Apply to all displays") { model.applyToAllDisplays() }
                .font(.system(size: 11))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Cards

    private var permissionCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 7) {
                    Text("Accessibility access is required")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Sightline needs permission to move and resize other apps' windows. It reads window geometry only — never window contents.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Open System Settings") { Accessibility.openSystemSettings() }
                        Button("Check Again") { model.refreshTrust() }
                    }
                    Text("Enable Sightline in Privacy & Security → Accessibility, then press Check Again.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var conflictCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .foregroundStyle(.orange)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Some shortcuts are already taken")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Another app — often Rectangle or Magnet — holds these combinations. Quit or rebind it, then relaunch Sightline.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.unavailable.map(\.shortcut).joined(separator: "   "))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var screenCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    "Screen",
                    detail: "Live preview at true aspect. Dashed lines mark the ±22° comfortable scan, measured from \(Int(model.viewingDistanceCM)) cm."
                )
                if let screen = model.screen, let geometry = model.geometry {
                    LayoutDiagram(
                        screen: screen,
                        layout: model.layout,
                        geometry: geometry,
                        metrics: model.metrics
                    )
                    .frame(height: 330)
                    metricsRow(screen: screen, geometry: geometry)
                } else {
                    Text("No display detected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var quickMenuCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    "Quick menu",
                    detail: "Arrange without leaving what you are doing — right-click the desktop, or ⌥-right-click anywhere."
                )
                Toggle("Menu on ⌥-right-click, anywhere", isOn: $model.quickMenuEnabled)
                    .font(.system(size: 12))
                Toggle("Also open on a plain right-click of the desktop", isOn: $model.quickMenuOnDesktopRightClick)
                    .font(.system(size: 12))
                    .disabled(!model.quickMenuEnabled)
            }
        }
    }

    private var layoutCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    "Proportions",
                    detail: "The centre board is the attention target; the side boards are deliberately narrow so they never pull focus."
                )

                HStack(spacing: 8) {
                    ForEach(LayoutPreset.all, id: \.id) { preset in
                        PresetChip(
                            preset: preset,
                            halfAngle: model.halfAngle(forCenterFraction: preset.centerFraction),
                            selected: abs(preset.centerFraction - model.centerFraction) < 0.005
                        ) {
                            model.apply(preset: preset)
                        }
                    }
                }

                sliderRow(
                    title: "Centre width",
                    value: $model.centerFraction,
                    range: 0.40...0.70,
                    step: 0.005,
                    readout: "\(Int((model.centerFraction * 100).rounded()))%"
                )

                sliderRow(
                    title: "Viewing distance",
                    value: $model.viewingDistanceCM,
                    range: 50...90,
                    step: 1,
                    readout: "\(Int(model.viewingDistanceCM.rounded())) cm"
                )

                Divider()

                Toggle("Split each side board into two equal panes", isOn: $model.splitSides)
                    .font(.system(size: 12))
                Toggle("Keep boards clear of the Dock (follows it when it moves)", isOn: $model.avoidDock)
                    .font(.system(size: 12))
                Toggle("Snap windows when dragging them between boards", isOn: $model.dragSnapEnabled)
                    .font(.system(size: 12))

                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcutsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    "Keyboard",
                    detail: "Global shortcuts — they work while any app is focused, no menu-bar trip required."
                )
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(76), alignment: .trailing),
                        GridItem(.flexible(), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(shortcutActions, id: \.rawValue) { action in
                        Text(action.shortcut)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(action.title)
                            .font(.system(size: 11))
                    }
                }
                Text("Also in the menu bar: save and restore arrangements, fill screen, centre at current size, and per-preset layouts.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Pieces

    private var shortcutActions: [HotKeyAction] {
        [
            .placeCenter, .placeLeftTop, .placeLeftBottom, .placeRightTop, .placeRightBottom,
            .hopLeft, .hopRight, .hopUp, .hopDown,
            .cycleForward, .cycleBackward, .stageFocused,
            .toggleSplit, .nudgeNarrower, .nudgeWider,
            .presetPrevious, .presetNext, .openSettings,
        ]
    }

    private var footnote: String {
        guard let metrics = model.metrics, let screen = model.screen else {
            return "Angles are estimated from the display's physical width and your viewing distance."
        }
        let angle = String(format: "%.1f", metrics.centerHalfAngleDeg)
        let size = String(
            format: "%.1f × %.1f cm",
            Double(screen.physicalWidthCM) * model.centerFraction,
            Double(screen.physicalWidthCM) * model.centerFraction * (screen.usableFrame.height / screen.usableFrame.width)
        )
        return "The centre board is \(size), which subtends ±\(angle)° from \(Int(model.viewingDistanceCM)) cm — \(metrics.isComfortable ? "inside" : "outside") the ±22° comfortable scan."
    }

    private func metricsRow(screen: ScreenInfo, geometry: LayoutGeometry) -> some View {
        let center = geometry.rect(for: .center) ?? .zero
        let side = geometry.rect(for: .leftTop) ?? .zero
        let metrics = model.metrics

        let centreCM = Double(center.width) / Double(screen.frame.width) * screen.physicalWidthCM
        let centreHeightCM = Double(center.height) / Double(screen.frame.height) * screen.physicalHeightCM
        let angle = metrics.map { String(format: "±%.1f°", $0.centerHalfAngleDeg) } ?? "—"
        let band = metrics.map { "\(Int($0.sideInnerAngleDeg.rounded()))–\(Int($0.sideOuterAngleDeg.rounded()))°" } ?? "—"

        return HStack(spacing: 8) {
            MetricTile(
                title: "CENTRE BOARD",
                value: "\(Int(center.width)) × \(Int(center.height))",
                caption: String(format: "%.1f × %.1f cm", centreCM, centreHeightCM)
            )
            MetricTile(
                title: "CENTRE ANGLE",
                value: angle,
                caption: metrics?.isComfortable == true ? "inside ±22°" : "outside ±22°",
                tint: metrics?.isComfortable == true ? .primary : .orange
            )
            MetricTile(
                title: model.splitSides ? "SIDE PANE" : "SIDE BOARD",
                value: model.splitSides ? "\(Int(side.width)) × \(Int(side.height))" : "\(Int(side.width)) × \(Int(side.height))",
                caption: model.splitSides ? "two equal panes" : "single column"
            )
            MetricTile(
                title: "SIDE GAZE BAND",
                value: band,
                caption: "from screen centre"
            )
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        readout: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(readout)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct PresetChip: View {
    let preset: LayoutPreset
    let halfAngle: Double?
    let selected: Bool
    let action: () -> Void

    private var comfortable: Bool {
        guard let halfAngle else { return true }
        return halfAngle <= Attention.comfortHalfAngleDeg
    }

    private var detail: String {
        let percent = Int((preset.centerFraction * 100).rounded())
        guard let halfAngle else { return "\(percent)%" }
        return "\(percent)%  ·  ±\(String(format: "%.1f", halfAngle))°"
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(comfortable ? Color.secondary : Color.orange)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(comfortable ? preset.blurb : preset.blurb + " — outside the ±22° comfortable scan.")
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let caption: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
