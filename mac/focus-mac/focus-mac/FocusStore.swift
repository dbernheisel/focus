import Foundation
import AppKit

struct FocusTicket: Decodable, Identifiable {
    let identifier: String
    let title: String
    let workspace: String?

    var id: String { identifier }

    func linearURL(useDesktopLinks: Bool) -> URL? {
        guard let workspace, !workspace.isEmpty else { return nil }
        let proto = useDesktopLinks ? "linear://" : "https://linear.app/"
        return URL(string: "\(proto)\(workspace)/issue/\(identifier)")
    }
}

@MainActor
@Observable
class FocusStore {
    var tickets: [FocusTicket] = []
    var isLoading = false
    var lastError: String?

    private var refreshTimer: Timer?
    private let config: FocusConfig?

    init() {
        config = FocusConfig.load()
    }

    func startPolling() {
        refresh()
        let timer = Timer(timeInterval: 900, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil

        Task {
            do {
                self.tickets = try await Self.fetchTickets()
            } catch {
                self.lastError = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    func openTicket(_ ticket: FocusTicket) {
        let useDesktop = config?.useDesktopLinks ?? false
        guard let url = ticket.linearURL(useDesktopLinks: useDesktop) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func findFocusBinary() -> String? {
        let home = realHomeDirectory
        let candidates = [
            "\(home)/.local/bin/focus",
            "/opt/homebrew/bin/focus",
            "/usr/local/bin/focus",
            "\(home)/focus/zig-out/bin/focus",
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func fetchTickets() async throws -> [FocusTicket] {
        guard let binary = findFocusBinary() else {
            throw FocusError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--list"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw FocusError.cliFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode([FocusTicket].self, from: data)
    }
}

enum FocusError: LocalizedError {
    case binaryNotFound
    case cliFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Could not find 'focus' binary. Ensure it is installed."
        case .cliFailed(let msg):
            return "focus --list failed: \(msg)"
        }
    }
}
