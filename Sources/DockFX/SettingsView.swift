import SwiftUI

/// DockFX's own part of the General tab: the Accessibility permission and the main switch.
struct GeneralSettings: View {
    @Bindable var prefs: Preferences
    var permissions: Permissions

    var body: some View {
        if !permissions.accessibility {
            Section {
                LabeledContent {
                    Button("Allow…", action: permissions.openAccessibilitySettings)
                } label: {
                    Text("Accessibility")
                    Text("To see where each icon is in the Dock and which one the pointer is over. DockFX doesn't read or change anything else.")
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("Switch on DockFX in Privacy & Security › Accessibility. The effects start straight away.")
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Toggle(isOn: $prefs.isEnabled) {
                Text("Turn on DockFX")
                Text("Plays effects on the Dock at the moments in the tabs above.")
            }
        } header: {
            Text("Effects")
        }
    }
}

/// A moment's tab of Settings (Pointing, Opening, …): its look, and how that looks and moves.
struct MomentSettings: View {
    @Bindable var prefs: Preferences
    let moment: Moment
    var permissions: Permissions
    /// Plays the moment's effect as it's set now.
    let tryIt: () -> Void

    private var style: Binding<EffectStyle> {
        Binding { prefs[moment] } set: { prefs[moment] = $0 }
    }

    var body: some View {
        let look = prefs[moment].look
        Section {
            Picker(selection: style.look) {
                ForEach(Look.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Look")
                Text(moment.detail)
            }
        } header: {
            Text(moment.title)
        }

        if look != .off {
            Section {
                slider("Strength", "How bright and solid it is.", style.strength, in: EffectStyle.strengths, show: percent)
                slider("Size", look.sizeDetail, style.size, in: EffectStyle.sizes, show: percent)
                slider("Speed", moment == .always ? "How quickly it plays, and how often it comes round." : "How quickly it plays.",
                       style.speed, in: EffectStyle.speeds, show: times)
                if look == .sparkles {
                    slider("Amount", "How many dots.", style.amount, in: EffectStyle.amounts, show: percent)
                }
                if look == .ripple {
                    Picker(selection: style.rings) {
                        ForEach(EffectStyle.ringCounts, id: \.self) { Text("\($0)").tag($0) }
                    } label: {
                        Text("Rings")
                        Text("How many rings spread out, one after another.")
                    }
                }
                Picker(selection: style.color) {
                    ForEach(EffectColor.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Colour")
                    if prefs[moment].color == .icon {
                        Text("Each icon's effect is in the main colour of its icon; white for grey icons.")
                    }
                }
                if prefs[moment].color == .custom {
                    ColorPicker("Custom colour", selection: Binding {
                        CGColor.hex(prefs[moment].customColor)
                    } set: {
                        prefs[moment].customColor = $0.hex
                    }, supportsOpacity: false)
                }
            } header: {
                Text(look.label)
            }

            Section {
                if moment != .always {
                    LabeledContent {
                        Button("Try It", action: tryIt)
                            .disabled(!permissions.accessibility)
                    } label: {
                        Text("Try it")
                        Text(moment.isOnIcon ? "Plays it on every icon, one after another." : "Plays it along the Dock.")
                    }
                }
                LabeledContent {
                    Button("Reset") { prefs[moment] = Moment.defaultStyle(moment, keeping: look) }
                } label: {
                    Text("Reset")
                    Text("Puts this look's settings back to normal.")
                }
            } footer: {
                if moment == .always {
                    Text("While the Dock shows, changes appear on it as you make them.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func slider(_ title: String, _ detail: String, _ value: Binding<Double>,
                        in range: ClosedRange<Double>, show: @escaping (Double) -> String) -> some View {
        LabeledContent {
            HStack {
                Slider(value: value, in: range)
                    .frame(width: 140)
                Text(show(value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func times(_ value: Double) -> String { String(format: "%.1f×", value) }
}

extension Moment {
    /// The normal settings for `look` at `moment`.
    static func defaultStyle(_ moment: Moment, keeping look: Look) -> EffectStyle {
        var style = moment.defaultStyle
        style.look = look
        return style
    }
}
