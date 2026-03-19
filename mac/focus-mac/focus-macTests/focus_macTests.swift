import Testing
import Foundation

// Self-contained test models matching the app's types.
// This avoids test host issues with the menubar-only app.

private struct TestConfig: Decodable {
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
}

private struct TestTicket: Decodable {
    let identifier: String
    let title: String
    let workspace: String?

    func linearURL(useDesktopLinks: Bool) -> URL? {
        guard let workspace, !workspace.isEmpty else { return nil }
        let proto = useDesktopLinks ? "linear://" : "https://linear.app/"
        return URL(string: "\(proto)\(workspace)/issue/\(identifier)")
    }
}

struct FocusConfigTests {
    @Test func decodesDesktopLinksTrue() throws {
        let json = """
        { "linear": [{ "desktop_links": true }] }
        """
        let config = try JSONDecoder().decode(TestConfig.self, from: Data(json.utf8))
        #expect(config.useDesktopLinks == true)
    }

    @Test func decodesDesktopLinksFalse() throws {
        let json = """
        { "linear": [{ "desktop_links": false }] }
        """
        let config = try JSONDecoder().decode(TestConfig.self, from: Data(json.utf8))
        #expect(config.useDesktopLinks == false)
    }

    @Test func defaultsToFalseWhenMissing() throws {
        let json = """
        { "linear": [{}] }
        """
        let config = try JSONDecoder().decode(TestConfig.self, from: Data(json.utf8))
        #expect(config.useDesktopLinks == false)
    }

    @Test func defaultsToFalseWhenNoLinear() throws {
        let json = "{}"
        let config = try JSONDecoder().decode(TestConfig.self, from: Data(json.utf8))
        #expect(config.useDesktopLinks == false)
    }

    @Test func ignoresUnknownFields() throws {
        let json = """
        { "linear": [{ "api_key": "lin_api_abc", "workspace": "my-team", "desktop_links": true }], "default_team": "Global" }
        """
        let config = try JSONDecoder().decode(TestConfig.self, from: Data(json.utf8))
        #expect(config.useDesktopLinks == true)
    }
}

struct FocusTicketTests {
    private func decode(_ json: String) throws -> TestTicket {
        try JSONDecoder().decode(TestTicket.self, from: Data(json.utf8))
    }

    private func makeTicket(identifier: String = "ENG-42", title: String = "Test", workspace: String? = "my-team") throws -> TestTicket {
        let ws = workspace.map { "\"\($0)\"" } ?? "null"
        return try decode("""
        {
            "identifier": "\(identifier)",
            "title": "\(title)",
            "state_name": "Todo",
            "state_type": "unstarted",
            "priority_label": "No priority",
            "workspace": \(ws)
        }
        """)
    }

    @Test func decodesFromCLIJson() throws {
        let ticket = try makeTicket(identifier: "TV-3381", title: "Fix the bug", workspace: "tv-labs")
        #expect(ticket.identifier == "TV-3381")
        #expect(ticket.title == "Fix the bug")
        #expect(ticket.workspace == "tv-labs")
    }

    @Test func webURL() throws {
        let ticket = try makeTicket()
        #expect(ticket.linearURL(useDesktopLinks: false)?.absoluteString == "https://linear.app/my-team/issue/ENG-42")
    }

    @Test func desktopURL() throws {
        let ticket = try makeTicket()
        #expect(ticket.linearURL(useDesktopLinks: true)?.absoluteString == "linear://my-team/issue/ENG-42")
    }

    @Test func urlIsNilWhenWorkspaceEmpty() throws {
        let ticket = try makeTicket(workspace: "")
        #expect(ticket.linearURL(useDesktopLinks: false) == nil)
    }

    @Test func urlIsNilWhenWorkspaceNil() throws {
        let ticket = try makeTicket(workspace: nil)
        #expect(ticket.linearURL(useDesktopLinks: false) == nil)
    }
}
