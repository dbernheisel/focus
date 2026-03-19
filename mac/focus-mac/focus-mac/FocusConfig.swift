import Foundation

struct FocusConfig: Decodable {
    let linear: [LinearWorkspace]?

    struct LinearWorkspace: Decodable {
        let desktopLinks: Bool?

        enum CodingKeys: String, CodingKey {
            case desktopLinks = "desktop_links"
        }
    }

    enum CodingKeys: String, CodingKey {
        case linear
    }

    var useDesktopLinks: Bool {
        linear?.first?.desktopLinks ?? false
    }

    static func load() -> FocusConfig? {
        let home = realHomeDirectory
        let path = URL(fileURLWithPath: home).appendingPathComponent(".config/focus/config.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(FocusConfig.self, from: data)
    }
}

/// The real home directory, bypassing sandbox container redirection
var realHomeDirectory: String {
    if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
        return String(cString: home)
    }
    return FileManager.default.homeDirectoryForCurrentUser.path
}
