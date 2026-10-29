import Foundation
import Testing
@testable import CoincideKit

/// Synthetic exports only.
@Suite struct PasswordCSVTests {
    @Test func readsTheCommonExports() throws {
        let chrome = "name,url,username,password,note\nGitHub,https://github.com/login,octo,\"fixture,chrome\",\"a \"\"quoted\"\" note\"\nbad,,x,y,\n"
        var result = try PasswordCSV.parse(Data(chrome.utf8))
        #expect(result.logins.count == 1 && result.skipped == 1)
        #expect(result.logins[0].appears(in: "fixture,chrome") && result.logins[0].title == "GitHub")

        let safari = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\nExample,https://example.org,me,fixture-safari,\"multi\nline\",otpauth://totp/x?secret=ABC\r\n"
        result = try PasswordCSV.parse(Data(safari.utf8))
        #expect(result.logins.first?.username == "me" && result.logins.first?.appears(in: "otpauth://totp/x?secret=ABC") == true)

        let firefox = "\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\"\n\"https://mozilla.test\",\"fox\",\"fixture-ff\",,\"\",\"{x}\"\n"
        #expect(try PasswordCSV.parse(Data(firefox.utf8)).logins.first?.url.host == "mozilla.test")

        let onePassword = "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nShop,shop.test,buyer,fixture-1p,,false,false,,\n"
        #expect(try PasswordCSV.parse(Data(onePassword.utf8)).logins.first?.url.absoluteString == "https://shop.test")

        let bitwarden = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,Bank,,,0,https://bank.test,me,fixture-bw,\n,,note,Secure note,text,,0,,,,\n"
        result = try PasswordCSV.parse(Data(bitwarden.utf8))
        #expect(result.logins.map(\.title) == ["Bank"] && result.skipped == 1)

        #expect(throws: (any Error).self) { try PasswordCSV.parse(Data("a,b\n1,2\n".utf8)) }
        #expect(throws: (any Error).self) { try PasswordCSV.parse(Data([0xFF, 0xFE, 0x00])) }
        let login = try #require(try PasswordCSV.parse(Data(chrome.utf8)).logins.first)
        var dumped = ""
        dump(login, to: &dumped)
        for text in [login.description, String(reflecting: login), dumped] { #expect(!login.appears(in: text)) }
    }

    @Test func importsIntoCoincideLogins() throws {
        let folder = try FixtureFolder()
        let provider = CoincideLoginProvider(directory: folder.url, secrets: MemorySecretStore())
        let csv = "name,url,username,password\nGitHub,https://github.com,octo,fixture-import\nGitHub again,https://github.com/login,octo,fixture-newer\n"
        let saved = try provider.importLogins(try PasswordCSV.parse(Data(csv.utf8)).logins)
        #expect(saved == 2)
        #expect(provider.saved.count == 1 && provider.saved.first?.title == "GitHub")
        #expect(provider.isSaved(url: URL(string: "https://github.com")!, username: "octo", password: "fixture-newer"))
        let list = try String(contentsOf: folder.url.appendingPathComponent("browser-logins.json"), encoding: .utf8)
        #expect(!list.contains("fixture-import") && !list.contains("fixture-newer"))
    }
}
