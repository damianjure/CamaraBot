import SwiftUI
import AppKit
import CoreText
import CueDesign
import CueNDI

/// Churchfront Signal tokens, from CueKit's CueDesign so every Cue app matches.
/// These short names stay so the views read as before.
enum T {
    static func hex(_ v: UInt32) -> Color { CueColor.solid(v) }
    static let bg = CueColor.bg
    static let surface = CueColor.surface
    static let surfaceRaised = CueColor.surfaceRaised
    static let surfaceSunken = CueColor.surfaceSunken
    static let line = CueColor.line
    static let lineStrong = CueColor.lineStrong
    static let ink = CueColor.ink
    static let inkMuted = CueColor.inkMuted
    static let inkSubtle = CueColor.inkSubtle
    static let accent = CueColor.accent
    static let accentStrong = CueColor.accentStrong
    static let onAction = CueColor.onAction
    static let success = CueColor.success
    static let warning = CueColor.warning
    static let danger = CueColor.danger
    /// Tally: program red, preview green, as on every switcher panel.
    static let program = CueColor.tallyProgram
    static let preview = CueColor.tallyPreview

    static let s1 = CueSpace.s1, s2 = CueSpace.s2, s3 = CueSpace.s3, s4 = CueSpace.s4, s5 = CueSpace.s5, s6 = CueSpace.s6
    static let rSM = CueSpace.rSM, rMD = CueSpace.rMD, rLG = CueSpace.rLG
}

enum Fonts {
    static var figtreeLoaded: Bool { CueFont.figtreeLoaded }
    static func register() {
        CueFont.register()
        ndi_set_app_name("CueVideo")
    }
}

extension Font {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.figtreeLoaded ? .custom("Figtree", size: size).weight(weight) : .system(size: size, weight: weight)
    }
}

extension View {
    /// ALL CAPS panel label, tracked out.
    func panelLabel(_ color: Color = T.inkSubtle) -> some View {
        self.font(.sans(11, .bold)).tracking(1.4).textCase(.uppercase).foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

/// A backlit panel button, like the keys on an ATEM control surface.
struct PanelButton: View {
    let title: String
    var subtitle: String? = nil
    var lit: Color? = nil
    var width: CGFloat = 76
    var height: CGFloat = 56
    var titleSize: CGFloat = 14
    var blink = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                let on = lit != nil && (!blink || Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0)
                VStack(spacing: 2) {
                    Text(title).font(.sans(titleSize, .bold)).lineLimit(1).minimumScaleFactor(0.6)
                    if let subtitle { Text(subtitle).font(.sans(9, .medium)).lineLimit(1).opacity(0.8) }
                }
                .padding(.horizontal, 4)
                .frame(width: width, height: height)
                .foregroundStyle(on ? T.onAction : T.inkMuted)
                .background(
                    RoundedRectangle(cornerRadius: T.rMD)
                        .fill(on ? (lit ?? T.surfaceRaised) : T.surfaceRaised)
                        .shadow(color: on ? (lit ?? .clear).opacity(0.55) : .clear, radius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(on ? Color.white.opacity(0.25) : T.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).brightness(configuration.isPressed ? 0.08 : 0)
    }
}
