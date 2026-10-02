#if DEBUG
    import Foundation

    /// `scripts/meeting-archive-check.py`: `--meeting-archive-settings-check <folder> export|import`, run in a full
    /// launch (services attached), then quits.
    /// - `export`: what leaves this Mac: config.json's bytes (`makeConfigData`), what Yap Cloud sync sends
    ///   (`makeCloudConfigData`) and Settings › Export Settings' backup, as `config.json`, `cloud.json`, `backup.json`.
    /// - `import`: `foreign-backup.json` applied as Import Settings applies it (every category), then
    ///   `foreign-config.json` as a pulled or edited config.json is applied.
    /// Both print the auto-archive switch and folder (`MeetingAutoArchive`) as this Mac has them afterwards.
    @MainActor
    enum MeetingArchiveSettingsCheck {
        static let argument = "--meeting-archive-settings-check"

        static func runIfRequested() {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 2) else { return }
            let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            let step = arguments[index + 2]
            Task { @MainActor in
                do {
                    let loader = YapConfigLoader.shared
                    if step == "export" {
                        guard let config = await loader.makeConfigData(), let cloud = await loader.makeCloudConfigData(),
                            let backup = await loader.makeBackupForCheck()
                        else { throw CocoaError(.featureUnsupported) }
                        try config.write(to: folder.appendingPathComponent("config.json"))
                        try cloud.write(to: folder.appendingPathComponent("cloud.json"))
                        try JSONEncoder().encode(backup).write(to: folder.appendingPathComponent("backup.json"))
                    } else {
                        let backup = try JSONDecoder().decode(
                            BackupFile.self, from: Data(contentsOf: folder.appendingPathComponent("foreign-backup.json")))
                        try await loader.applyBackupForCheck(backup)
                        try await loader.applyConfigData(Data(contentsOf: folder.appendingPathComponent("foreign-config.json")))
                    }
                    let defaults = UserDefaults.standard
                    print("settings-check: \(step) enabled \(defaults.bool(forKey: MeetingAutoArchive.enabledKey)) folder \(defaults.string(forKey: MeetingAutoArchive.folderKey) ?? "none")")
                    fflush(stdout)
                    exit(0)
                } catch {
                    print("settings-check: failed \(error)")
                    fflush(stdout)
                    exit(1)
                }
            }
        }
    }
#endif
