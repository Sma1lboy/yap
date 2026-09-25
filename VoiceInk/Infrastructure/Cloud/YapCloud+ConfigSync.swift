import Foundation

// Yap Cloud is the store behind "Sync via Yap Cloud" (CloudConfigSync).
extension YapCloud: ConfigCloudStore {}
extension YapCloudConfigDocument: CloudConfigDocument {}

extension YapCloud: ConfigVersionHistoryStore {
    func listConfigVersions() async throws -> [CloudConfigVersionInfo] {
        try await fetchConfigVersions().map {
            CloudConfigVersionInfo(
                version: $0.version.string, updatedAt: $0.updatedDate, deviceName: $0.deviceName, bytes: $0.bytes)
        }
    }

    func fetchConfigVersion(_ version: String) async throws -> Data {
        try await fetchConfig(version: version).config
    }
}
