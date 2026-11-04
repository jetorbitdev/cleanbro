import SwiftUI

/// UI language, persisted in UserDefaults under `language`. English is the default.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, id

    static let storageKey = "language"

    /// Current language, read by `L(_:_:)`. Views re-render on change because the
    /// root views are keyed with `.id(language)`.
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .en
    }

    var id: String { rawValue }

    /// Shown in each language's own name so it is recognisable whatever is active.
    var title: String {
        switch self {
        case .en: "English"
        case .id: "Bahasa Indonesia"
        }
    }

    /// Makes AppKit's own strings (app menu, Edit, Window, Help…) use this language.
    /// AppKit reads it at launch, so a change shows up in those menus after a restart.
    func applyToSystemMenus() {
        UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
    }

    var locale: Locale { Locale(identifier: self == .en ? "en_US" : "id_ID") }
}

/// Localized string: pass the English and Indonesian text side by side.
/// `L("\(n) files", "\(n) file")`
func L(_ en: String, _ id: String) -> String {
    AppLanguage.current == .id ? id : en
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .en

    var body: some View {
        Picker(L("Language", "Bahasa"), selection: $language) {
            ForEach(AppLanguage.allCases) { l in Text(l.title).tag(l) }
        }
        .onChange(of: language) { _, new in new.applyToSystemMenus() }
        if language != AppLanguage.atLaunch {
            HStack {
                Text(L("The menu bar changes language after CleanBro restarts.",
                       "Bahasa menu bar berganti setelah CleanBro dibuka ulang."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Restart Now", "Buka Ulang Sekarang")) { AppLanguage.relaunch() }
            }
        }
    }
}

extension AppLanguage {
    /// Language the menu bar was built with (captured in CleanBroApp.init).
    static let atLaunch = AppLanguage.current

    /// Starts a fresh copy of the app once this one has quit, then quits.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
