import Foundation
import Testing
@testable import JTKit

/// A Blueprint in compact form, exactly as the serializer writes it: fields an
/// app must never touch, mixed number literals, unicode and escapes.
/// (From AppSettings2Blueprint's tests, where this code came from.)
let sampleBlueprintJSON = #"{"id":"6f0c1e2a-0000-4000-8000-000000000001","name":"Microsoft AutoUpdate – Legacy","description":"Migrated from \"Classic\" profile","created":"2025-11-02T09:15:00.123Z","updated":"2026-09-30T14:02:11.987654Z","deploymentState":{"state":"DEPLOYED","lastDeployment":{"started":"2026-09-30T14:03:00Z","state":"SUCCEEDED"}},"scope":{"deviceGroups":["a1","b2"]},"steps":[{"name":"Step 1","activationPredicate":null,"components":[{"identifier":"com.jamf.ddm.passcode","configuration":{"minLength":6,"ratio":1.0,"big":12345678901234567890123,"exp":1e5,"neg":-0,"enabled":true,"tags":[],"meta":{}}},{"identifier":"com.jamf.ddm-configuration-profile","configuration":{"payloadDisplayName":"MAU","payloadContent":[{"payloadType":"com.apple.ManagedClient.preferences","PayloadContent":{"com.microsoft.autoupdate2":{"Forced":[{"mcx_preference_settings":{"HowToCheck":"AutomaticDownload","UpdateCheckFrequency":720,"EnableCheckForUpdatesButton":false,"Ratio":0.5,"Channels":["Production","Preview"],"Nested":{"a":"é😀/","b":"line\nbreak"}}}]},"com.example.other":{"Set-Once":[{"mcx_data_timestamp":"2024-01-01T00:00:00Z","mcx_preference_settings":{"Key":"Value"}}]}}}]}}]}]}"#

@Suite("Lossless JSON round trip")
struct LosslessJSONRoundTripTests {
    @Test func compactRoundTripIsByteIdentical() throws {
        let data = Data(sampleBlueprintJSON.utf8)
        #expect(try LosslessJSON(data: data).serialized() == data)
    }

    @Test func stepsRoundTripIsByteIdentical() throws {
        let steps = try #require(try LosslessJSON(string: sampleBlueprintJSON)["steps"])
        let stepsData = steps.serialized()
        #expect(try LosslessJSON(data: stepsData).serialized() == stepsData)
        #expect(sampleBlueprintJSON.contains(String(decoding: stepsData, as: UTF8.self)))
    }

    @Test func prettyAndCompactProduceSameTree() throws {
        let compact = try LosslessJSON(string: sampleBlueprintJSON)
        let pretty = try LosslessJSON(data: compact.serialized(pretty: true))
        #expect(pretty == compact)
        #expect(pretty.serialized() == Data(sampleBlueprintJSON.utf8))
    }

    @Test(arguments: ["1.0", "1e5", "1E+5", "-0", "0.1", "12345678901234567890123", "-1.25e-10", "720"])
    func numberLiteralsArePreserved(literal: String) throws {
        let json = "[\(literal)]"
        #expect(try LosslessJSON(string: json).serializedString() == json)
    }

    @Test func keyOrderAndDuplicateKeysArePreserved() throws {
        let json = #"{"z":1,"a":2,"m":3,"a":4}"#
        let parsed = try LosslessJSON(string: json)
        #expect(parsed.objectValue?.keys == ["z", "a", "m", "a"])
        #expect(parsed.serializedString() == json)
    }

    @Test func escapesAreDecoded() throws {
        let parsed = try LosslessJSON(string: #"["\u00e9\n\ud83d\ude00\/\"\\\t"]"#)
        #expect(parsed[0]?.stringValue == "é\n😀/\"\\\t")
        #expect(parsed.serializedString() == #"["é\n😀/\"\\\t"]"#)
    }

    @Test func controlCharactersAreEscaped() {
        #expect(LosslessJSON.string("a\u{01}b").serializedString() == #""a\u0001b""#)
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "\"unterminated", "tru", "[1] x", "\"\\ud800\""])
    func invalidJSONThrowsInsteadOfCrashing(input: String) {
        #expect(throws: LosslessJSON.ParseError.self) { try LosslessJSON(string: input) }
    }

    /// JTKit is on macOS 14, so this check no longer uses `String(validating:)`.
    @Test func invalidUTF8InAStringThrows() {
        let bytes: [UInt8] = [0x22, 0xC3, 0x28, 0x22]  // "\xC3(" : a broken two-byte sequence
        #expect(throws: LosslessJSON.ParseError.self) { try LosslessJSON(data: Data(bytes)) }
    }

    @Test func excessiveNestingThrows() {
        let deep = String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000)
        #expect(throws: LosslessJSON.ParseError.self) { try LosslessJSON(string: deep) }
    }
}

@Suite("Lossless JSON editing")
struct LosslessJSONEditingTests {
    private let settingsPath: [LosslessJSON.PathComponent] = [
        .key("steps"), .index(0), .key("components"), .index(1), .key("configuration"),
        .key("payloadContent"), .index(0), .key("PayloadContent"), .key("com.microsoft.autoupdate2"),
        .key("Forced"), .index(0), .key("mcx_preference_settings"),
    ]

    @Test func editingOneKeyChangesOnlyThatKey() throws {
        let original = try LosslessJSON(string: sampleBlueprintJSON)
        var edited = original
        let path = settingsPath + [.key("UpdateCheckFrequency")]
        let didSet = edited.setValue(.number(LosslessJSON.Number(240)), at: path)
        #expect(didSet)
        let expected = sampleBlueprintJSON.replacingOccurrences(of: #""UpdateCheckFrequency":720"#, with: #""UpdateCheckFrequency":240"#)
        #expect(edited.serializedString() == expected)
        let other: [LosslessJSON.PathComponent] = [.key("steps"), .index(0), .key("components"), .index(0)]
        #expect(edited.value(at: other) == original.value(at: other))
        #expect((settingsPath + [.key("Ratio")]).pathString == "steps[0].components[1].configuration.payloadContent[0].PayloadContent.com.microsoft.autoupdate2.Forced[0].mcx_preference_settings.Ratio")
    }

    @Test func editedKeyKeepsItsPosition() throws {
        var value = try LosslessJSON(string: #"{"a":1,"b":2,"c":3}"#)
        value.setValue(.string("x"), at: [.key("b")])
        #expect(value.serializedString() == #"{"a":1,"b":"x","c":3}"#)
    }

    @Test func settingThroughAMissingPathFails() throws {
        var value = try LosslessJSON(string: sampleBlueprintJSON)
        let before = value
        let setMissingIndex = value.setValue(.null, at: [.key("steps"), .index(9), .key("name")])
        let setMissingKey = value.setValue(.null, at: [.key("missing"), .key("deeper")])
        #expect(!setMissingIndex)
        #expect(!setMissingKey)
        #expect(value == before)
    }
}

@Suite("Lossless JSON meaning")
struct LosslessJSONSemanticsTests {
    @Test func semanticEqualityIgnoresKeyOrderAndNumberFormat() throws {
        let a = try LosslessJSON(string: #"{"a":1,"b":[1.0,{"x":true,"y":null}]}"#)
        #expect(a.isSemanticallyEqual(to: try LosslessJSON(string: #"{"b":[1,{"y":null,"x":true}],"a":1.00}"#)))
        #expect(!a.isSemanticallyEqual(to: try LosslessJSON(string: #"{"a":1,"b":[{"x":true,"y":null},1]}"#)))
        #expect(!a.isSemanticallyEqual(to: try LosslessJSON(string: #"{"a":"1","b":[1,{"x":true,"y":null}]}"#)))
    }

    /// Decimal holds 38 significant digits; longer differing literals must not
    /// collide into "equal".
    @Test func numbersBeyondDecimalPrecisionCompareByLiteral() {
        let digits = String(repeating: "9", count: 45)
        let a = LosslessJSON.number(LosslessJSON.Number(literal: digits + "1"))
        let b = LosslessJSON.number(LosslessJSON.Number(literal: digits + "2"))
        #expect(!a.isSemanticallyEqual(to: b))
        #expect(a.isSemanticallyEqual(to: a))
    }

    @Test func alignmentFollowsTheReferenceOrder() throws {
        let value = try LosslessJSON(string: #"{"kind":"C","type":"t","payload":{"b":1,"a":2},"extra":0}"#)
        let reference = try LosslessJSON(string: #"{"type":"t","payload":{"a":0,"b":0},"kind":"C"}"#)
        #expect(value.aligned(to: reference).serializedString() == #"{"type":"t","payload":{"a":2,"b":1},"kind":"C","extra":0}"#)
    }
}
