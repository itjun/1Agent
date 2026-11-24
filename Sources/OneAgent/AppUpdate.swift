import Foundation

/// 只迁移旧更新器的用户选择，安装与校验由 Sparkle 管理。
enum AppUpdatePreferences {
    static let migrationKey = "update.sparklePreferencesMigrated"

    static func migrate(defaults: UserDefaults = .standard, directory: URL? = nil) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("1Agent/update", isDirectory: true)
        let file = directory.appendingPathComponent("prefs.json")
        struct LegacyPreferences: Decodable { var autoCheck: Bool }
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LegacyPreferences.self, from: $0) }
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil {
            defaults.set(previous?.autoCheck ?? true, forKey: "SUEnableAutomaticChecks")
        }
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        defaults.set(true, forKey: migrationKey)
        // 不递归删除下载目录；只清理旧更新器明确拥有的普通文件。
        for name in ["prefs.json", "latest.json", "latest.json.sig"] {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// 更新和普通退出共用一次保存；失败后允许重试，不会缓存失败结果。
@MainActor
final class ApplicationExitPreparation {
    private var task: Task<Void, Error>?

    func reset() { task = nil }

    func prepare(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        if let task { return try await task.value }
        let task = Task { try await operation() }
        self.task = task
        do { try await task.value }
        catch { self.task = nil; throw error }
    }
}
