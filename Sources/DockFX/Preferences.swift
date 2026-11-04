import AppKit
import AppShell
import Foundation
import Observation

/// What an effect looks like. Each one has a version for a single icon and one along the whole
/// Dock (see Looks.swift).
enum Look: String, CaseIterable, Identifiable, Codable {
    case off
    case glow
    case shine
    case sparkles
    case ripple

    var id: String { rawValue }

    /// The looks that draw something.
    static var visible: [Look] { allCases.filter { $0 != .off } }

    var label: String {
        switch self {
        case .off: "Off"
        case .glow: "Glow"
        case .shine: "Shine"
        case .sparkles: "Sparkles"
        case .ripple: "Ripple"
        }
    }

    /// What Size changes for this look.
    var sizeDetail: String {
        switch self {
        case .off: ""
        case .glow: "How far the glow spreads."
        case .shine: "How wide the band of light is."
        case .sparkles: "How big the dots are, and how high they rise."
        case .ripple: "How far the rings spread."
        }
    }
}

/// Where an effect's colour comes from.
enum EffectColor: String, CaseIterable, Identifiable, Codable {
    case icon
    case accent
    case white
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .icon: "From each app's icon"
        case .accent: "Accent colour"
        case .white: "White"
        case .custom: "Custom"
        }
    }
}

/// A moment DockFX plays an effect at. Each has its own tab in Settings and its own style.
enum Moment: String, CaseIterable, Identifiable {
    case pointing
    case opening
    case switching
    case slidingIn
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pointing: "Pointing"
        case .opening: "Opening"
        case .switching: "Switching"
        case .slidingIn: "Sliding In"
        case .always: "Always"
        }
    }

    var symbol: String {
        switch self {
        case .pointing: "cursorarrow.rays"
        case .opening: "arrow.up.forward.app"
        case .switching: "arrow.left.arrow.right"
        case .slidingIn: "dock.arrow.up.rectangle"
        case .always: "infinity"
        }
    }

    /// When it plays, under its look in Settings.
    var detail: String {
        switch self {
        case .pointing: "Plays on the icon under the pointer."
        case .opening: "Plays on an app's icon once it has opened."
        case .switching: "Plays on the icon of the app you switch to."
        case .slidingIn: "Plays along the Dock as it appears, when it hides itself or an app is full screen."
        case .always: "Keeps a gentle effect going along the Dock while it shows. Uses a little more battery."
        }
    }

    /// Whether it plays on one icon, rather than along the whole Dock.
    var isOnIcon: Bool { self == .pointing || self == .opening || self == .switching }

    var defaultStyle: EffectStyle {
        switch self {
        case .pointing: EffectStyle(look: .glow)
        case .opening: EffectStyle(look: .sparkles)
        case .switching: EffectStyle(look: .ripple)
        case .slidingIn: EffectStyle(look: .shine)
        case .always: EffectStyle(look: .off)
        }
    }
}

/// How one moment's effect looks and moves.
struct EffectStyle: Equatable, Codable {
    var look: Look
    /// How bright and solid it is: 1 is normal.
    var strength = 1.0
    /// How far it reaches, and how big its parts are: 1 is normal.
    var size = 1.0
    /// How many times as fast as normal it plays.
    var speed = 1.0
    var color = EffectColor.icon
    /// For `EffectColor.custom`, as #RRGGBB.
    var customColor = "#FFC94D"
    /// For Sparkles: how many, 1 being normal.
    var amount = 1.0
    /// For Ripple: how many rings.
    var rings = 2

    static let strengths = 0.25...1.5
    static let sizes = 0.5...2.0
    static let speeds = 0.5...2.0
    static let amounts = 0.25...3.0
    static let ringCounts = 1...4

    init(look: Look) {
        self.look = look
    }

    /// How much longer than normal it takes.
    var pace: Double { 1 / speed }

    /// Missing values (from an older DockFX) keep their defaults.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        look = try values.decode(Look.self, forKey: .look)
        strength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        size = try values.decodeIfPresent(Double.self, forKey: .size) ?? size
        speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? speed
        color = try values.decodeIfPresent(EffectColor.self, forKey: .color) ?? color
        customColor = try values.decodeIfPresent(String.self, forKey: .customColor) ?? customColor
        amount = try values.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        rings = try values.decodeIfPresent(Int.self, forKey: .rings) ?? rings
    }
}

@Observable @MainActor
final class Preferences {
    private enum Key {
        static let isEnabled = "isEnabled"
        static func style(_ moment: Moment) -> String { "effect.\(moment.rawValue)" }
    }

    @ObservationIgnored var onEnabledChange: (() -> Void)?
    /// Whenever a moment's style changes.
    @ObservationIgnored var onStylesChange: (() -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard

    var isEnabled: Bool {
        didSet {
            save(isEnabled, Key.isEnabled)
            onEnabledChange?()
        }
    }
    private var styles: [Moment: EffectStyle]

    /// Each moment's style.
    subscript(moment: Moment) -> EffectStyle {
        get { styles[moment] ?? moment.defaultStyle }
        set {
            guard newValue != self[moment] else { return }
            styles[moment] = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                save(data, Key.style(moment))
            }
            onStylesChange?()
        }
    }

    init() {
        defaults.register(defaults: [
            Key.isEnabled: true,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        var styles: [Moment: EffectStyle] = [:]
        for moment in Moment.allCases {
            styles[moment] = defaults.data(forKey: Key.style(moment))
                .flatMap { try? JSONDecoder().decode(EffectStyle.self, from: $0) } ?? moment.defaultStyle
        }
        self.styles = styles
    }

    /// A README clip (`-demo <scene>`) changes settings on screen, but never saves them.
    private func save(_ value: Any, _ key: String) {
        guard AppShell.demoScene == nil else { return }
        defaults.set(value, forKey: key)
    }
}

extension CGColor {
    /// From #RRGGBB; white if it can't be read.
    static func hex(_ string: String) -> CGColor {
        let digits = string.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .white }
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// As #RRGGBB, in sRGB.
    var hex: String {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = converted(to: space, intent: .defaultIntent, options: nil)?.components,
              parts.count >= 3 else { return "#FFFFFF" }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(parts[0]), channel(parts[1]), channel(parts[2]))
    }
}
