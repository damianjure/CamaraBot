import SwiftUI

// The parts every Engineer page is built from, so they read as one app: a page with a
// header, cards, labeled columns, and fields, buttons and menus in CueVideo's own style
// (the Signal tokens in Theme.swift) rather than stock macOS controls.

/// A scrolling Engineer page. Content keeps a comfortable width and sits at the left.
struct Page<Content: View>: View {
    /// Use the whole window instead of a comfortable reading width: for the routing schematic.
    var wide = false
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.s5) { content }
                .padding(wide ? T.s4 : T.s5)
                .frame(maxWidth: wide ? .infinity : 1240, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(T.bg)
        .foregroundStyle(T.ink)
    }
}

/// A page's title, one line on what it's for, and a "?" holding the longer explanation.
struct PageHeader<Trailing: View>: View {
    let title: String
    let purpose: String
    var help: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: T.s3) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: T.s2) {
                    Text(title).font(.sans(22, .bold))
                    if let help { HelpButton(text: help) }
                }
                Text(purpose).font(.sans(13)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: T.s4)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, purpose: String, help: String? = nil) {
        self.init(title: title, purpose: purpose, help: help) { EmptyView() }
    }
}

/// A small "?" that opens the longer explanation, so pages don't open with paragraphs.
struct HelpButton: View {
    let text: String
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 13)).foregroundStyle(T.inkSubtle)
        }
        .buttonStyle(.plain)
        .help(tr("What this is for", es: "Para qué sirve esto"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text).font(.sans(13)).foregroundStyle(T.ink).fixedSize(horizontal: false, vertical: true)
                .frame(width: 380, alignment: .leading).padding(T.s4)
        }
    }
}

/// A titled block on a page.
struct Card<Content: View>: View {
    var title: String? = nil
    var help: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            if let title {
                HStack(spacing: T.s2) {
                    Text(title).panelLabel()
                    if let help { HelpButton(text: help) }
                }
            }
            content
        }
        .padding(T.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.rLG).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(T.line))
    }
}

/// A column heading over a table of rows.
struct Col: View {
    let title: String
    var width: CGFloat? = nil
    init(_ title: String, _ width: CGFloat? = nil) { self.title = title; self.width = width }
    var body: some View {
        Text(title).font(.sans(10, .bold)).tracking(0.8).textCase(.uppercase).foregroundStyle(T.inkSubtle)
            .lineLimit(1).frame(width: width, alignment: .leading)
    }
}

/// Text fields: sunken, hairline border, the app's font.
struct CueFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain).font(.sans(13))
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
    }
}

/// Buttons. One primary per page (the thing the page is for); the rest secondary or quiet.
struct CueButton: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = kind == .primary ? T.onAction : (kind == .quiet ? T.accentStrong : (kind == .danger ? T.danger : T.ink))
        let bg: Color = kind == .primary ? T.accent : (kind == .secondary ? T.surfaceRaised : Color.clear)
        return configuration.label
            .font(.sans(12, .semibold)).foregroundStyle(fg).lineLimit(1)
            .padding(.horizontal, kind == .quiet ? 4 : 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(kind == .secondary || kind == .danger ? T.line : Color.clear))
            .opacity(enabled ? 1 : 0.45)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .contentShape(Rectangle())
    }
}

/// A small icon button with a tooltip: reorder, remove, edit.
struct IconButton: View {
    let icon: String
    let help: String
    var color: Color = T.inkMuted
    var size: CGFloat = 12
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold)).foregroundStyle(color)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }
}

/// A menu that looks like a field: what's chosen now, and a chevron.
struct MenuField<Content: View>: View {
    let text: String
    var width: CGFloat? = nil
    var icon: String? = nil
    var strong = false
    @ViewBuilder let content: Content

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(T.inkSubtle) }
                Text(text).font(.sans(strong ? 13 : 12, .semibold)).foregroundStyle(T.ink).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(T.inkSubtle)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: strong ? 32 : 28)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// A row of choices, one lit: sub-pages, shot sizes, M/Es.
struct Segments<V: Hashable>: View {
    let items: [(String, V)]
    @Binding var selection: V

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let on = items[i].1 == selection
                Button { selection = items[i].1 } label: {
                    Text(items[i].0).font(.sans(12, .semibold)).foregroundStyle(on ? T.onAction : T.inkMuted)
                        .padding(.horizontal, T.s3).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: T.rSM).fill(on ? T.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
        .fixedSize()
    }
}

/// A small tag: LIVE, NEXT, ON, HIDDEN.
struct Tag: View {
    let text: String
    var color: Color = T.lineStrong
    var ink: Color = T.ink
    var size: CGFloat = 9
    var body: some View {
        Text(text).font(.sans(size, .bold)).tracking(0.6).textCase(.uppercase).foregroundStyle(ink)
            .padding(.horizontal, 5).frame(height: size + 7)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(color))
            .fixedSize()
    }
}

/// A section that folds away, for things looked at now and then.
struct Fold<Content: View>: View {
    let title: String
    let count: Int
    @Binding var open: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Button { open.toggle() } label: {
                HStack(spacing: T.s2) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(T.inkSubtle)
                        .frame(width: 12)
                    Text(title).panelLabel()
                    Text("\(count)").font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content }
        }
    }
}
