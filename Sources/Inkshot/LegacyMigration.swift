import Foundation

/// The app was called PSE (bundle id com.viafirst.pse) until 0.7.0. On the first launch as
/// Inkshot, take over its screenshot history and settings so nothing is lost.
enum LegacyMigration {
    private static let doneKey = "migratedFromPSE"

    static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("PSE", isDirectory: true)
        let new = support.appendingPathComponent("Inkshot", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        if let legacy = UserDefaults(suiteName: "com.viafirst.pse") {
            for key in ["historyLimit", "pageWidth", "lastSaveFolder"] where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
