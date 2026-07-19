//
//  LayoutView.swift
//  HyperVibe (settings UI — Layout tab)
//
//  Read-only "what every button does" map, built from the live parsed Config. An app "Hub"
//  row (one chip per mode) selects the mode being viewed; the drawn RemoteView on the left and
//  a grouped input→mapping list on the right show, per key, the resolved action and whether it's
//  Custom (defined in this mode), Inherited (from an ancestor mode), or System (unbound → native).
//  Hovering a row lights the matching element on the remote.
//

import SwiftUI
import AppKit

struct LayoutView: View {
    let config: Config

    @State private var selectedMode: String?
    @State private var highlightedKey: String?

    // The mode currently being viewed (falls back to the default if the selection is gone
    // after a hot-reload).
    private var mode: String {
        if let m = selectedMode, config.modes[m] != nil { return m }
        return config.defaultModeName
    }

    /// When false, the content is laid out without a ScrollView — needed for offscreen
    /// ImageRenderer snapshots (a ScrollView measures as empty when rendered headless).
    var scrolls: Bool = true

    var body: some View {
        Group {
            if scrolls {
                ScrollView { contentStack }
            } else {
                contentStack
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            hub
            legend
            stage
            foot
        }
        .padding(.bottom, 8)
    }

    // MARK: - Head

    private var head: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LAYOUT")
                .font(.system(size: 11, weight: .heavy)).tracking(1.4)
                .foregroundStyle(.secondary)
            Text("What every button does")
                .font(.system(size: 22, weight: .bold))
            Text("Pick an app from the hub. Anything not set for that app falls back to Global, then to the remote's native behavior.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 4)
    }

    // MARK: - Hub (one chip per mode)

    private var hub: some View {
        let apps = config.appsByMode
        let def = config.defaultModeName
        let modes = config.modes.keys.sorted { a, b in
            if a == def { return true }
            if b == def { return false }
            return chipTitle(a, apps: apps, isDefault: false) < chipTitle(b, apps: apps, isDefault: false)
        }
        return HStack(spacing: 8) {
            Text("APP")
                .font(.system(size: 11, weight: .heavy)).tracking(1)
                .foregroundStyle(.secondary)
            ForEach(modes, id: \.self) { m in
                chip(mode: m,
                     title: chipTitle(m, apps: apps, isDefault: m == def),
                     icon: chipIcon(m, apps: apps, isDefault: m == def),
                     count: config.modes[m]?.bindings.count ?? 0)
            }
            addChip
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 6)
    }

    private func chip(mode m: String, title: String, icon: String, count: Int) -> some View {
        let on = m == mode
        return Button {
            selectedMode = m
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(on ? Color.white.opacity(0.22) : Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(on ? Color.clear : Color.secondary.opacity(0.25), lineWidth: 1))
                Text(title).font(.system(size: 13, weight: .medium))
                Text("\(count)").font(.system(size: 11, weight: .semibold))
                    .monospacedDigit().opacity(0.65)
            }
            .padding(.leading, 9).padding(.trailing, 13).padding(.vertical, 7)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(on ? Color.clear : Color.secondary.opacity(0.22), lineWidth: 1))
            .shadow(color: on ? Color.accentColor.opacity(0.3) : .clear, radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var addChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            Text("Add app…").font(.system(size: 13))
        }
        .padding(.leading, 9).padding(.trailing, 13).padding(.vertical, 7)
        .foregroundStyle(.secondary)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
        .help("Assigning apps to modes is edited in config.jsonc for now.")
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(.accentColor, "Custom in this app")
            legendItem(.secondary, "Inherited from Global")
            legendItem(Color.secondary.opacity(0.55), "System / native")
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 26).padding(.vertical, 6)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }

    // MARK: - Stage: remote + list

    private var stage: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 13) {
                RemoteView(highlightedKey: $highlightedKey)
                Text("Aluminum Siri Remote (3rd gen). Hover a row → its button lights up.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal, 8).padding(.top, 6)

            VStack(spacing: 16) {
                ForEach(Self.groups, id: \.name) { group in
                    groupCard(group)
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 16)
    }

    private func groupCard(_ group: InputGroup) -> some View {
        VStack(spacing: 0) {
            Text(group.name.uppercased())
                .font(.system(size: 11, weight: .heavy)).tracking(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.secondary.opacity(0.06))
            ForEach(Array(group.rows.enumerated()), id: \.element.key) { idx, row in
                if idx > 0 { Divider() }
                mappingRow(row)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }

    private func mappingRow(_ row: InputRow) -> some View {
        let r = resolve(row.key)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 13.5, weight: .medium))
                Text(row.key).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: 8)
            Text(r.label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(r.kind == .system ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
            tag(r)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(highlightedKey == row.hotspot ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering in
            if hovering { highlightedKey = row.hotspot }
            else if highlightedKey == row.hotspot { highlightedKey = nil }
        }
    }

    private func tag(_ r: Resolved) -> some View {
        let (bg, fg): (Color, Color)
        switch r.kind {
        case .custom:    (bg, fg) = (Color.accentColor.opacity(0.15), .accentColor)
        case .inherited: (bg, fg) = (Color.secondary.opacity(0.15), .secondary)
        case .system:    (bg, fg) = (Color.secondary.opacity(0.1), Color.secondary.opacity(0.8))
        }
        return Text(r.tag)
            .font(.system(size: 10.5, weight: .bold)).tracking(0.3)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
    }

    // MARK: - Foot

    private var foot: some View {
        Text("Reads your live config.jsonc. Read-only map for now — clicking a row to re-assign is the next step.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 26).padding(.top, 6).padding(.bottom, 18)
    }

    // MARK: - Resolution

    private enum Kind { case custom, inherited, system }
    private struct Resolved { let label: String; let kind: Kind; let tag: String }

    private func resolve(_ key: String) -> Resolved {
        if let res = config.resolveBinding(key, in: mode) {
            if res.sourceMode == mode {
                return Resolved(label: res.action.displayLabel, kind: .custom, tag: "Custom")
            }
            let tag = res.sourceMode == config.defaultModeName ? "Global" : "Inherited"
            return Resolved(label: res.action.displayLabel, kind: .inherited, tag: tag)
        }
        return Resolved(label: Self.nativeLabel(key), kind: .system, tag: "System")
    }

    // MARK: - Static tables

    private struct InputRow {
        let key: String
        let name: String
        /// `.hold` variants light the base ring element (ring.up.hold → ring.up).
        var hotspot: String { key.hasSuffix(".hold") ? String(key.dropLast(5)) : key }
    }
    private struct InputGroup { let name: String; let rows: [InputRow] }

    private static let groups: [InputGroup] = [
        InputGroup(name: "Clickpad", rows: [
            InputRow(key: "ring.up",      name: "Ring ↑"),
            InputRow(key: "ring.up.hold", name: "Ring ↑ · hold"),
            InputRow(key: "ring.down",    name: "Ring ↓"),
            InputRow(key: "ring.left",    name: "Ring ←"),
            InputRow(key: "ring.right",   name: "Ring →"),
            InputRow(key: "select",       name: "Center click"),
            InputRow(key: "touch",        name: "Touch surface"),
        ]),
        InputGroup(name: "Buttons", rows: [
            InputRow(key: "button.siri",       name: "Siri / voice"),
            InputRow(key: "button.playPause",  name: "Play / Pause"),
            InputRow(key: "button.mute",       name: "Mute"),
            InputRow(key: "button.volumeUp",   name: "Volume +"),
            InputRow(key: "button.volumeDown", name: "Volume −"),
            InputRow(key: "button.tv",         name: "TV"),
            InputRow(key: "button.back",       name: "Back"),
            InputRow(key: "button.power",      name: "Power"),
        ]),
    ]

    /// The remote's native behavior text for an unbound key.
    private static func nativeLabel(_ key: String) -> String {
        switch key {
        case "select":            return "Click"
        case "touch":             return "Move · Scroll · Swipe"
        case "button.siri":       return "Siri"
        case "button.playPause":  return "Play / Pause"
        case "button.mute":       return "Mute"
        case "button.volumeUp":   return "Volume +"
        case "button.volumeDown": return "Volume −"
        case "button.tv":         return "Control Center"
        case "button.back":       return "Back"
        case "button.power":      return "Sleep / Wake"
        default:                  return "—"   // ring directions (incl. .hold)
        }
    }

    // MARK: - Chip labels

    private func chipTitle(_ m: String, apps: [String: [String]], isDefault: Bool) -> String {
        if isDefault { return "Global" }
        if let first = apps[m]?.first { return Self.friendlyApp(first) }
        return m.prefix(1).uppercased() + m.dropFirst()
    }

    private func chipIcon(_ m: String, apps: [String: [String]], isDefault: Bool) -> String {
        if isDefault { return "globe" }
        if let first = apps[m]?.first { return Self.appIcon(first) }
        return "app.dashed"
    }

    private static func friendlyApp(_ id: String) -> String {
        let known: [String: String] = [
            "com.apple.Music": "Apple Music",
            "com.apple.Safari": "Safari",
            "com.apple.TV": "Apple TV",
            "com.apple.finder": "Finder",
            "com.apple.mail": "Mail",
            "com.microsoft.VSCode": "VS Code",
            "com.google.Chrome": "Chrome",
            "com.apple.iWork.Keynote": "Keynote",
            "com.apple.Preview": "Preview",
            "com.apple.systempreferences": "System Settings",
        ]
        if let n = known[id] { return n }
        let last = id.split(separator: ".").last.map(String.init) ?? id
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    private static func appIcon(_ id: String) -> String {
        switch id {
        case "com.apple.Music":       return "music.note"
        case "com.apple.Safari":      return "safari"
        case "com.apple.TV":          return "tv"
        case "com.microsoft.VSCode":  return "chevron.left.forwardslash.chevron.right"
        case "com.google.Chrome":     return "globe"
        case "com.apple.finder":      return "folder"
        case "com.apple.mail":        return "envelope"
        default:                      return "app.dashed"
        }
    }
}

/// Headless renderer for the Layout tab — used by `HyperVibe --snapshot-layout <path>` so the UI
/// can be captured without a visible window or any UI-scripting permissions. macOS 13+ ImageRenderer.
@MainActor
enum LayoutSnapshot {
    static func renderAndExit(to path: String) {
        let config = ConfigStore.loadConfig()
        let renderer = ImageRenderer(
            content: LayoutView(config: config, scrolls: false)
                .frame(width: 900)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2.0
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("📸 wrote layout snapshot → \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot: write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
