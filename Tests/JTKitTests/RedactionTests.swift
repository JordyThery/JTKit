import Foundation
import Testing
@testable import JTKit

@Suite("Redaction")
struct RedactionTests {
    private let hidden = Redaction.placeholder

    @Test("Authorization keeps its scheme; cookies are hidden whole; other headers stay")
    func headers() {
        let headers = Redaction.headers([
            "Authorization": "Bearer abc.def.ghi",
            "Cookie": "JSESSIONID=secret; theme=dark",
            "Set-Cookie": "session=xyz; Path=/",
            "X-Environment-Id": "env-1",
        ])
        #expect(headers.map(\.name) == ["Authorization", "Cookie", "Set-Cookie", "X-Environment-Id"])
        #expect(headers[0].value == "Bearer \(hidden)")
        #expect(headers[1].value == hidden)
        #expect(headers[2].value == hidden)
        #expect(headers[3].value == "env-1")
        #expect(Redaction.headerValue(name: "authorization", value: "onlyonepart") == hidden)
    }

    @Test("Secret form fields are hidden, also when the name is percent-encoded")
    func formFields() {
        let body = Data("grant_type=client_credentials&client_id=abc&client_secret=s3cr3t%2B&pass%77ord=x".utf8)
        let text = Redaction.body(body, contentType: "application/x-www-form-urlencoded")
        #expect(text == "grant_type=client_credentials&client_id=abc&client_secret=\(hidden)&pass%77ord=\(hidden)")
    }

    @Test("JSON secrets are hidden at any depth, ignoring case; personal blocks whole")
    func json() throws {
        let body = Data(#"""
        {"access_token":"tok","items":[{"Password":"p","name":"Engineers"}],
         "nested":{"deeper":{"recoveryLockPassword":"r","PIN":123456}},
         "location":{"username":"jdoe","room":"12"},"pageSize":5}
        """#.utf8)
        let text = try #require(Redaction.body(body))
        for secret in ["\"tok\"", "\"p\"", "\"r\"", "123456", "jdoe"] {
            #expect(!text.contains(secret), "\(secret) still visible")
        }
        #expect(text.contains("Engineers"))
        #expect(text.contains("\"pageSize\" : 5"))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(parsed["location"] as? String == hidden)
    }

    @Test("Extension attributes are hidden whole, like the personal blocks")
    func extensionAttributes() throws {
        let body = Data(#"""
        {"general":{"name":"Lab Mac","extensionAttributes":[{"name":"Wi-Fi key","values":["hunter2"]}]},
         "extension_attributes":[{"name":"Setup","value":"s3cr3t"}]}
        """#.utf8)
        let text = try #require(Redaction.body(body))
        #expect(!text.contains("hunter2") && !text.contains("s3cr3t") && !text.contains("Wi-Fi key"))
        #expect(text.contains("Lab Mac"))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((parsed["general"] as? [String: Any])?["extensionAttributes"] as? String == hidden)
        #expect(parsed["extension_attributes"] as? String == hidden)
    }

    @Test("Classic API XML elements are hidden, also with attributes")
    func xml() {
        let xml = #"<computer><general><name>Lab</name><password type="x">hunter2</password></general><PIN>1234</PIN></computer>"#
        let text = Redaction.body(Data(xml.utf8), contentType: "application/xml") ?? ""
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("1234"))
        #expect(text.contains("<name>Lab</name>"))
        #expect(text.contains(#"<password type="x">\#(hidden)</password>"#))
    }

    @Test("Free text: Bearer and Basic credentials, JSON fragments and key=value pairs")
    func freeText() {
        let text = Redaction.text(#"failed: Bearer eyJabc.def== then Basic YWRtaW46aHVudGVyMg== and "client_secret": "leak" or token=abc123"#)
        #expect(!text.contains("eyJabc"))
        #expect(!text.contains("YWRtaW46"))
        #expect(!text.contains("leak"))
        #expect(!text.contains("abc123"))
        #expect(text.contains("Bearer \(hidden)"))
        #expect(Redaction.text("Nothing to hide here.") == "Nothing to hide here.")
    }

    @Test("Secret query parameters are hidden; the rest of the address stays")
    func query() throws {
        let url = try #require(URL(string: "https://example.com/api/x?page=1&client_secret=abc&token=t"))
        #expect(Redaction.url(url) == "https://example.com/api/x?page=1&client_secret=\(hidden)&token=\(hidden)")
        let plain = try #require(URL(string: "https://example.com/api/x"))
        #expect(Redaction.url(plain) == "https://example.com/api/x")
    }

    @Test("Error messages shown to the user are redacted")
    func errorMessages() {
        let response = HTTPResponse(status: 401, headers: ["Content-Type": "application/json"],
                                    data: Data(#"{"error":"invalid_client","client_secret":"leaked"}"#.utf8))
        let error = HTTPError.status(response, method: "POST", path: "auth/token", duringSignIn: true)
        let message = error.localizedDescription
        #expect(message.hasPrefix("Sign-in failed: HTTP 401 Unauthorized\n"))
        #expect(message.contains("invalid_client"))
        #expect(!message.contains("leaked"))
        let transport = HTTPError.transport(method: "GET", path: "x", code: .timedOut, message: "Bearer abc failed")
        #expect(!(transport.errorDescription ?? "").contains("abc"))
    }

    @Test("An Azure Storage upload address hides its signature")
    func azureSignature() throws {
        let address = "https://store.blob.core.windows.net/c/blob?sv=2019-02-02&sr=b&sig=abc%2Bdef%3D&se=2026-10-26T12%3A00%3A00Z&sp=rw&comp=block&blockid=YmxvY2s%3D"
        let redacted = Redaction.url(try #require(URL(string: address)))
        #expect(redacted == "https://store.blob.core.windows.net/c/blob?sv=2019-02-02&sr=b&sig=\(hidden)&se=2026-10-26T12%3A00%3A00Z&sp=rw&comp=block&blockid=YmxvY2s%3D")
        #expect(!Redaction.text("PUT \(address) failed").contains("abc%2Bdef"))
    }

    @Test("A codeload address hides its token parameter")
    func codeloadToken() throws {
        let address = "https://codeload.github.com/owner/repo/legacy.zip/refs/heads/main?token=ABCDEF123456"
        let redacted = Redaction.url(try #require(URL(string: address)))
        #expect(redacted == "https://codeload.github.com/owner/repo/legacy.zip/refs/heads/main?token=\(hidden)")
    }

    @Test("A GitHub token in an Authorization header of the form “token …” keeps only the word")
    func gitHubTokenHeader() {
        let headers = Redaction.headers(["Authorization": "token ghp_16C7e42F292c6912E7710c838347Ae178B4a"])
        #expect(headers.first?.value == "token \(hidden)")
    }

    @Test("GitHub tokens are hidden anywhere in free text, by their prefix",
          arguments: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"])
    func gitHubTokensInText(prefix: String) throws {
        let token = prefix + "11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz"
        let text = Redaction.text("Request failed; token was \(token). Retry with (\(token))")
        #expect(text == "Request failed; token was \(hidden). Retry with (\(hidden))")
        // also inside an error answer, as the recorder cleans it
        let body = try #require(Redaction.body(Data(#"{"message":"Bad credentials \#(token)"}"#.utf8)))
        #expect(!Redaction.text(body).contains(token))
        // a word that merely contains the prefix stays
        #expect(Redaction.text("high_ghp_value") == "high_ghp_value")
    }

    @Test("Strict form encoding keeps + & = and quotes from changing a request")
    func formEncoding() {
        #expect(FormEncoding.encode("s3cr3t+with&specials=") == "s3cr3t%2Bwith%26specials%3D")
        #expect(FormEncoding.encode([URLQueryItem(name: "filter", value: #"a=="b""#)]) == "filter=a%3D%3D%22b%22")
    }
}
