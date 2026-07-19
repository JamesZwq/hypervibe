//
//  SettingsView.swift
//  HyperVibe (settings UI)
//
//  Minimal, Apple-style settings window. Every value applies live and persists.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                cursorSection
                circularSection
                footerSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 452, height: 700)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: "appletvremote.gen4.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color.accentColor.opacity(0.35), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("siriRemote").font(.system(size: 19, weight: .semibold))
                Text("Touch & gesture tuning")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connected ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(model.connected ? "Connected" : "Waiting")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.quaternary))
    }

    // MARK: - Sections

    private var cursorSection: some View {
        Section {
            slider(icon: "cursorarrow.motionlines", title: "Speed",
                   value: $model.tune.cursorSpeed, range: 0.1...2.0,
                   minIcon: "tortoise.fill", maxIcon: "hare.fill",
                   display: { String(format: "%.2f×", $0) })
            slider(icon: "hand.raised.fill", title: "Steadiness",
                   value: $model.tune.cursorDeadzone, range: 0.0...0.02,
                   minIcon: "scribble.variable", maxIcon: "hand.raised.fill",
                   display: { String(format: "%.0f", $0 * 1000) })
        } header: {
            Text("Cursor")
        } footer: {
            Text("Higher steadiness ignores finger jitter, so it's easier to hold still and click.")
        }
    }

    private var circularSection: some View {
        Section {
            Toggle(isOn: $model.tune.circularEnabled) {
                rowLabel("Circular scroll", "arrow.clockwise")
            }
            if model.tune.circularEnabled {
                slider(icon: "circle.dashed", title: "Outer ring only",
                       value: $model.tune.circularMinRadius, range: 0.15...0.45,
                       minIcon: "smallcircle.filled.circle.fill", maxIcon: "circle",
                       display: { String(format: "%.0f%%", $0 * 100) })
                slider(icon: "timer", title: "Start resistance",
                       value: $model.tune.circularStartThreshold, range: 0.1...1.5,
                       minIcon: "hare.fill", maxIcon: "tortoise.fill",
                       display: { String(format: "%.0f°", $0 * 180 / .pi) })
                slider(icon: "speedometer", title: "Scroll speed",
                       value: $model.tune.circularPixelsPerTick, range: 4...40,
                       minIcon: "tortoise.fill", maxIcon: "hare.fill",
                       display: { String(format: "%.0f", $0) })
                Toggle(isOn: $model.tune.circularInvert) {
                    rowLabel("Reverse direction", "arrow.left.arrow.right")
                }
            }
        } header: {
            Text("Circular Scroll")
        } footer: {
            Text("Circle a finger on the pad's outer ring to scroll — like a click wheel.")
        }
        .animation(.easeInOut(duration: 0.22), value: model.tune.circularEnabled)
    }

    private var footerSection: some View {
        Section {
            Button(role: .destructive) {
                withAnimation { model.resetToDefaults() }
            } label: {
                rowLabel("Reset to defaults", "arrow.counterclockwise")
            }
        } footer: {
            Text("Button, ring, and swipe mappings live in ~/.config/siriremote/config.jsonc")
                .font(.system(size: 11))
        }
    }

    // MARK: - Reusable rows

    private func rowLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 18)
            Text(title).font(.system(size: 13))
        }
    }

    private func slider(icon: String, title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, minIcon: String, maxIcon: String,
                        display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                rowLabel(title, icon)
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Image(systemName: minIcon).font(.system(size: 11)).foregroundStyle(.tertiary)
                Slider(value: value, in: range)
                Image(systemName: maxIcon).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}
