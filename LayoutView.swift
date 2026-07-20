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
    /// Persist an edited config (writes config.jsonc → hot-reloads). Nil = read-only (snapshots).
    var onSave: ((Config) -> Void)? = nil

    @State private var selectedMode: String?
    @State private var highlightedKey: String?
    /// The input row currently open in the editor panel (nil = nothing selected).
    @State private var selectedKey: String?
    /// Illustration (interactive, editable) vs. metallic 3D model (showpiece).
    @State private var show3D = false
    // "Add app / layer" popover state.
    @State private var showAdd = false
    @State private var addIsLayer = false
    @State private var addName = ""
    @State private var addTargetMode = "global"

    // The mode currently being viewed (falls back to the default if the selection is gone
    // after a hot-reload).
    private var mode: String {
        if let m = selectedMode, config.modes[m] != nil { return m }
        return config.defaultModeName
    }

    /// When false, the content is laid out without a ScrollView — needed for offscreen
    /// ImageRenderer snapshots (a ScrollView measures as empty when rendered headless).
    var scrolls: Bool = true

    init(config: Config, onSave: ((Config) -> Void)? = nil, scrolls: Bool = true, initialSelected: String? = nil) {
        self.config = config
        self.onSave = onSave
        self.scrolls = scrolls
        _selectedKey = State(initialValue: initialSelected)
    }

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
            if selectedKey != nil, onSave != nil { editorPanel }
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
        Button {
            addName = ""; addIsLayer = false; addTargetMode = config.defaultModeName; showAdd = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                Text("Add…").font(.system(size: 13))
            }
            .padding(.leading, 9).padding(.trailing, 13).padding(.vertical, 7)
            .foregroundStyle(.secondary)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(onSave == nil)
        .popover(isPresented: $showAdd, arrowEdge: .bottom) { addPopover }
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $addIsLayer) {
                Text("App profile").tag(false)
                Text("Layer").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if addIsLayer {
                TextField("Layer name (e.g. tvLayer)", text: $addName).textFieldStyle(.roundedBorder)
                Text("A layer is a mode you activate by holding a key (the Layer action). It inherits Global.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("App bundle id (e.g. com.apple.Notes)", text: $addName).textFieldStyle(.roundedBorder)
                HStack(spacing: 6) {
                    Text("uses mode").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("", selection: $addTargetMode) {
                        ForEach(sortedModeNames, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 130)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showAdd = false }
                Button("Create") { createAdd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(addName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 300)
    }

    private func createAdd() {
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let onSave = onSave else { showAdd = false; return }
        if addIsLayer {
            onSave(config.addMode(name, inherits: config.defaultModeName))
            selectedMode = name
        } else {
            onSave(config.setAppProfile(bundleID: name, mode: addTargetMode))
            selectedMode = addTargetMode
        }
        showAdd = false
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

    /// A compact 2D-illustration ↔ 3D-model switch under the remote.
    private var viewModeToggle: some View {
        HStack(spacing: 0) {
            modeChip("Illustration", "square.on.square", on: !show3D) { show3D = false }
            modeChip("3D", "cube", on: show3D) { show3D = true }
        }
        .padding(3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.14), lineWidth: 1))
    }

    private func modeChip(_ title: String, _ icon: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.18)) { act() } }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .background(
                Capsule().fill(on ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .shadow(color: on ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var stage: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 13) {
                if show3D {
                    RemoteScene3D()
                        .frame(width: 190, height: 512)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    RemoteView(highlightedKey: $highlightedKey, onSelect: onSave == nil ? nil : { key in
                        selectedKey = key       // click a remote button → open its editor row
                        highlightedKey = key
                    })
                }
                viewModeToggle
                Text(show3D
                     ? "Metallic 3rd-gen model — drag to orbit. Switch to Illustration to edit."
                     : "Aluminum Siri Remote (3rd gen). Click an input to edit it.")
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
        .background(rowBackground(row))
        .onHover { hovering in
            if hovering { highlightedKey = row.hotspot }
            else if highlightedKey == row.hotspot { highlightedKey = nil }
        }
        .onTapGesture {
            guard onSave != nil else { return }
            selectedKey = (selectedKey == row.key) ? nil : row.key
            highlightedKey = row.hotspot
        }
    }

    private func rowBackground(_ row: InputRow) -> Color {
        if selectedKey == row.key { return Color.accentColor.opacity(0.16) }
        if highlightedKey == row.hotspot { return Color.accentColor.opacity(0.07) }
        return Color.clear
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
        Text("Click any input to edit its Tap / Double-tap / Hold actions — changes save to config.jsonc and apply live.")
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
            // The physical Back button (‹) reports HID usage 0x86 → config key `button.menu`.
            InputRow(key: "button.menu",       name: "Back"),
            InputRow(key: "button.power",      name: "Power"),
        ]),
        InputGroup(name: "Gestures", rows: [
            InputRow(key: "swipe.up",    name: "Swipe ↑"),
            InputRow(key: "swipe.down",  name: "Swipe ↓"),
            InputRow(key: "swipe.left",  name: "Swipe ←"),
            InputRow(key: "swipe.right", name: "Swipe →"),
            InputRow(key: "tap.two",     name: "Two-finger tap"),
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
        case "button.menu":       return "Back"
        case "button.power":      return "Sleep / Wake"
        default:                  return "—"   // ring directions (incl. .hold), swipes, tap.two
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

    // MARK: - Editor panel (edit the selected input's slots, per mode)

    /// Base input key for the editor: strip a `.hold*`/`.double` suffix so selecting any row of an
    /// input shows ALL its slots.
    private var editBase: String {
        guard let k = selectedKey else { return "" }
        for suffix in [".hold3", ".hold2", ".hold", ".double"] where k.hasSuffix(suffix) {
            return String(k.dropLast(suffix.count))
        }
        return k
    }

    private var sortedModeNames: [String] { config.modes.keys.sorted() }

    private struct Slot { let slotKey: String; let label: String }
    private func slots(for base: String) -> [Slot] {
        if base.hasPrefix("ring.") || base.hasPrefix("button.") {
            return [
                Slot(slotKey: base,             label: "Tap"),
                Slot(slotKey: base + ".double", label: "Double-tap"),
                Slot(slotKey: base + ".hold",   label: "Hold"),
                Slot(slotKey: base + ".hold2",  label: "Hold ··"),
                Slot(slotKey: base + ".hold3",  label: "Hold ···"),
            ]
        }
        // Swipes / two-finger tap are one-shot gesture events — a single action, no hold/double.
        if base.hasPrefix("swipe.") || base == "tap.two" {
            return [Slot(slotKey: base, label: "Action")]
        }
        return []
    }

    private func saveSlot(_ slotKey: String, _ action: Action?) {
        onSave?(config.setBinding(slotKey, to: action, inMode: mode))
    }

    static func inputName(_ key: String) -> String {
        for g in groups { for r in g.rows where r.key == key { return r.name } }
        switch key {
        case "ring.up": return "Ring ↑"; case "ring.down": return "Ring ↓"
        case "ring.left": return "Ring ←"; case "ring.right": return "Ring →"
        default: return key
        }
    }

    private var editorPanel: some View {
        let base = editBase
        let theSlots = slots(for: base)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("EDIT").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(.secondary)
                Text(Self.inputName(base)).font(.system(size: 13, weight: .semibold))
                Text("in \(mode == config.defaultModeName ? "Global" : mode)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { selectedKey = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Color.secondary.opacity(0.06))

            if theSlots.isEmpty {
                Text("This input is handled natively and isn't remappable here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(16)
            } else {
                ForEach(Array(theSlots.enumerated()), id: \.element.slotKey) { idx, slot in
                    if idx > 0 { Divider() }
                    HStack(spacing: 12) {
                        Text(slot.label).font(.system(size: 13, weight: .medium))
                            .frame(width: 92, alignment: .leading)
                        ActionSlotEditor(
                            action: config.modes[mode]?.bindings[slot.slotKey],
                            modeNames: sortedModeNames,
                            onChange: { saveSlot(slot.slotKey, $0) }
                        )
                        .id("\(mode)/\(slot.slotKey)")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 10)
    }
}

/// Per-slot action editor: pick an action type + its params; commits via `onChange`.
private struct ActionSlotEditor: View {
    let action: Action?
    let modeNames: [String]
    let onChange: (Action?) -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case none = "None", keystroke = "Keystroke", media = "Media", mouse = "Mouse",
             launchApp = "Launch app", openURL = "Open URL", shell = "Shell",
             applescript = "AppleScript", space = "Switch space", brightness = "Brightness",
             layer = "Layer", mode = "Mode", repeatKey = "Repeat key"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .none
    @State private var text: String = ""
    @State private var pick: String = ""
    @State private var value: Double = 0
    // Preserved so editing one field of a multi-field action doesn't reset the others (#8):
    @State private var repDelay: Double = 0.3       // repeatKey timing, kept from the loaded action
    @State private var repInterval: Double = 0.045
    @State private var altLaunch: String = ""       // the launch field NOT being edited (url ↔ app)
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Computed binding: `set` runs only on a USER pick, so `load()` (which sets @State
            // directly) never triggers a save → no reload loop. On a type change we RESET the params
            // so a leftover value from the old type can't be written as the new type (e.g. keystroke
            // "up" → shell "up", which would then EXECUTE `up`).
            Picker("", selection: Binding(get: { kind }, set: { kind = $0; resetParamsForKind(); commit() })) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 128)
            param
        }
        .onAppear(perform: load)
        // Commit text fields when focus LEAVES (not only on Enter) — otherwise typing a value then
        // clicking another row (which changes this editor's `.id` and discards its @State) loses it.
        .onChange(of: focused) { isFocused in if !isFocused { commit() } }
    }

    @ViewBuilder private var param: some View {
        switch kind {
        case .none:
            Text("does nothing").foregroundStyle(.secondary).font(.system(size: 12))
        case .keystroke, .repeatKey:
            TextField("cmd+shift+t", text: $text).textFieldStyle(.roundedBorder).frame(width: 170)
                .focused($focused).onSubmit(commit)
        case .shell:
            TextField("shell command", text: $text).textFieldStyle(.roundedBorder).frame(width: 240)
                .focused($focused).onSubmit(commit)
        case .applescript:
            TextField("AppleScript source", text: $text).textFieldStyle(.roundedBorder).frame(width: 240)
                .focused($focused).onSubmit(commit)
        case .launchApp:
            TextField("App name (e.g. Safari)", text: $text).textFieldStyle(.roundedBorder).frame(width: 200)
                .focused($focused).onSubmit(commit)
        case .openURL:
            TextField("https://…", text: $text).textFieldStyle(.roundedBorder).frame(width: 220)
                .focused($focused).onSubmit(commit)
        case .media:  enumPicker(["playpause","next","previous","volup","voldown","mute"])
        case .mouse:  enumPicker(["click","rightclick","scroll","move"])
        case .space:  enumPicker(["left","right"])
        case .mode:   enumPicker(modeNames.isEmpty ? ["global"] : modeNames)
        case .layer:
            HStack(spacing: 8) {
                enumPicker(modeNames.isEmpty ? ["global"] : modeNames)
                Text("tap = toggle · hold = momentary")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .brightness:
            HStack(spacing: 6) {
                // Commit only when the drag ends (onEditingChanged → false), not on every tick —
                // each commit is a file write + engine reload.
                Slider(value: $value, in: 0...1, onEditingChanged: { editing in if !editing { commit() } })
                    .frame(width: 130)
                Text("\(Int(value*100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func enumPicker(_ options: [String]) -> some View {
        Picker("", selection: Binding(get: { pick }, set: { pick = $0; commit() })) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().frame(width: 130)
    }

    private func load() {
        guard let a = action else { kind = .none; return }
        switch a {
        case .keystroke(let k):       kind = .keystroke; text = k
        case .media(let k):           kind = .media; pick = k
        case .mouse(let op):          kind = .mouse; pick = op
        case .launch(let app, let url):
            if let app = app { kind = .launchApp; text = app; altLaunch = url ?? "" }
            else { kind = .openURL; text = url ?? ""; altLaunch = "" }
        case .shell(let c):           kind = .shell; text = c
        case .applescript(let s):     kind = .applescript; text = s
        case .mode(let to):           kind = .mode; pick = to
        case .layer(let n):           kind = .layer; pick = n
        case .space(let d):           kind = .space; pick = d < 0 ? "left" : "right"
        case .repeatKey(let k, let d, let i): kind = .repeatKey; text = k; repDelay = d; repInterval = i
        case .brightness(let v):      kind = .brightness; value = v
        }
    }

    /// On a type change, clear params so a leftover value from the previous type is never written as
    /// the new type; seed sensible defaults for the picker-based types.
    private func resetParamsForKind() {
        text = ""; altLaunch = ""; repDelay = 0.3; repInterval = 0.045; value = 0
        switch kind {
        case .media:        pick = "playpause"
        case .mouse:        pick = "click"
        case .space:        pick = "left"
        case .layer, .mode: pick = modeNames.first ?? "global"
        default:            pick = ""
        }
    }

    private func commit() { onChange(build()) }

    private func build() -> Action? {
        switch kind {
        case .none:        return nil
        case .keystroke:   return text.isEmpty ? nil : .keystroke(keys: text)
        case .repeatKey:   return text.isEmpty ? nil : .repeatKey(keys: text, delay: repDelay, interval: repInterval)
        case .media:       return .media(key: pick.isEmpty ? "playpause" : pick)
        case .mouse:       return .mouse(op: pick.isEmpty ? "click" : pick)
        case .launchApp:   return text.isEmpty ? nil : .launch(app: text, url: altLaunch.isEmpty ? nil : altLaunch)
        case .openURL:     return text.isEmpty ? nil : .launch(app: altLaunch.isEmpty ? nil : altLaunch, url: text)
        case .shell:       return text.isEmpty ? nil : .shell(command: text)
        case .applescript: return text.isEmpty ? nil : .applescript(script: text)
        case .space:       return .space(direction: pick == "left" ? -1 : 1)
        case .layer:       return pick.isEmpty ? nil : .layer(pick)
        case .mode:        return pick.isEmpty ? nil : .mode(to: pick)
        case .brightness:  return .brightness(value)
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
            content: LayoutView(config: config, scrolls: false)   // read-only render (Pickers don't draw offscreen)
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
