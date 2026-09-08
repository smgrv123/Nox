import Foundation

/// The OS capabilities and network/filesystem permissions a skill declares.
public struct ManifestPermissions: Sendable, Hashable {
    public var network: Bool
    public var networkHosts: [String]
    public var fileWritePaths: [String]
    public var requires: [String]

    public init(
        network: Bool = false,
        networkHosts: [String] = [],
        fileWritePaths: [String] = [],
        requires: [String] = []
    ) {
        self.network = network
        self.networkHosts = networkHosts
        self.fileWritePaths = fileWritePaths
        self.requires = requires
    }
}

extension ManifestPermissions: Codable {

    private enum CodingKeys: String, CodingKey {
        case network
        case networkHosts
        case fileWritePaths
        case requires
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.network = try container.decodeIfPresent(Bool.self, forKey: .network) ?? false
        self.networkHosts = try container.decodeIfPresent([String].self, forKey: .networkHosts) ?? []
        self.fileWritePaths = try container.decodeIfPresent([String].self, forKey: .fileWritePaths) ?? []
        self.requires = try container.decodeIfPresent([String].self, forKey: .requires) ?? []
    }
}
