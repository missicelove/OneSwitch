import AppKit

@main
enum OneSwitchMain {
    @MainActor
    static func main() {
        // Developer tool (scripts/settings-screenshots.sh): render the settings window to PNGs and exit.
        // Checked before anything touches AppEnvironment, because it switches to a throwaway profile.
        if let options = SettingsSnapshot.options(from: CommandLine.arguments) {
            SettingsSnapshot.run(options)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // A menu-bar agent until the settings window opens (it switches to .regular while shown).
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
