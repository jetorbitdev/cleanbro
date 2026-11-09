import SwiftUI
import AppKit

/// User-chosen app appearance, persisted in UserDefaults under `appearance`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("System", "Ikuti Sistem")
        case .light: L("Light", "Terang")
        case .dark: L("Dark", "Gelap")
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Next mode for the quick toggle: Sistem → Terang → Gelap → Sistem.
    var next: AppAppearance {
        switch self {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }

    /// Applied app-wide so window chrome, sheets and alerts follow too.
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Keeps NSApp.appearance in sync with the stored preference.
struct AppearanceSync: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    func body(content: Content) -> some View {
        content
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { _, new in new.apply() }
    }
}

/// Small button that cycles the appearance; used in the sidebar footer.
struct AppearanceToggle: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Button { appearance = appearance.next } label: {
            Image(systemName: appearance.icon).frame(width: 18)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("appearance.toggle")
        .help(L("Appearance: \(appearance.title) (click to change)", "Tampilan: \(appearance.title) (klik untuk ganti)"))
        .contextMenu { AppearancePicker() }
    }
}

/// Picker listing all modes; used in menus and Settings.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Picker(L("Appearance", "Tampilan"), selection: $appearance) {
            ForEach(AppAppearance.allCases) { a in
                Label(a.title, systemImage: a.icon).tag(a)
            }
        }
    }
}

struct GeneralSettings: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Picker(L("Appearance", "Tampilan"), selection: $appearance) {
                ForEach(AppAppearance.allCases) { a in Text(a.title).tag(a) }
            }
            .pickerStyle(.segmented)
            LanguagePicker()
        }
        .padding(20)
        .frame(width: 480)
    }
}
