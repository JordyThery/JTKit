import Foundation
import Testing
@testable import JTKit

@Suite("Identifier masker")
struct IdentifierMaskerTests {
    private func found(_ json: String) -> [FoundIdentifier] {
        IdentifierMasker.identifiers(inBody: Data(json.utf8))
    }

    @Test("Serials, UDIDs, IMEI and MAC addresses are found by key")
    func deviceKeys() {
        let identifiers = found(#"""
        {"results":[{"serialNumber":"C02XK1JHJG5H","udid":"6F3A6C1E-2B0D-4E9B-9C1A-1D2E3F4A5B6C",
                      "imei":"35 209900 176148 1","wifiMacAddress":"a4:83:e7:12:34:56","id":"12"}]}
        """#)
        #expect(Set(identifiers.map(\.value)) == ["C02XK1JHJG5H", "6F3A6C1E-2B0D-4E9B-9C1A-1D2E3F4A5B6C",
                                                 "35 209900 176148 1", "a4:83:e7:12:34:56"])
        #expect(identifiers.allSatisfy { $0.kind == .device })
    }

    @Test("A device record’s name is a device name; a Blueprint’s or a group’s isn’t")
    func names() {
        let identifiers = found(#"""
        {"computer":{"serialNumber":"C02XK1JHJG5H","name":"Jordy’s MacBook"},
         "blueprint":{"id":"5b1f7c2e-0000-0000-0000-000000000001","name":"Engineers"},
         "group":{"name":"All Macs"},"inventory":{"deviceName":"iPad Lab 3","computerName":"Studio Mac"}}
        """#)
        let values = Set(identifiers.map(\.value))
        #expect(values.contains("Jordy’s MacBook"))
        #expect(values.contains("iPad Lab 3"))
        #expect(values.contains("Studio Mac"))
        #expect(!values.contains("Engineers"))
        #expect(!values.contains("All Macs"))
    }

    @Test("Emails, usernames, full names and IP addresses are found; version numbers aren’t addresses")
    func peopleAndAddresses() {
        let identifiers = found(#"""
        {"username":"jdoe","realName":"Jane Doe","userPrincipalName":"jane@corp.example",
         "ipAddress":"10.1.2.3","note":"mail ops@corp.example","osVersion":"15.1.0.1","lastIpAddress":"not an address"}
        """#)
        let byValue = Dictionary(identifiers.map { ($0.value, $0.kind) }, uniquingKeysWith: { first, _ in first })
        #expect(byValue["jdoe"] == .user)
        #expect(byValue["Jane Doe"] == .user)
        #expect(byValue["jane@corp.example"] == .user)
        #expect(byValue["ops@corp.example"] == .user)
        #expect(byValue["10.1.2.3"] == .address)
        #expect(byValue["15.1.0.1"] == nil)
        #expect(byValue["not an address"] == nil)
    }

    @Test("Classic API XML: device records, scope users and identifier elements")
    func classicXML() {
        let xml = #"""
        <os_x_configuration_profile><scope><computers><computer><id>1</id><name>Lab Mac</name>
        <udid>6F3A6C1E-2B0D-4E9B-9C1A-1D2E3F4A5B6C</udid></computer></computers>
        <limitations><users><user><name>jdoe</name></user></users></limitations>
        <computer_groups><computer_group><id>2</id><name>Engineers</name></computer_group></computer_groups>
        </scope><general><serial_number>C02XK1JHJG5H</serial_number></general></os_x_configuration_profile>
        """#
        let identifiers = IdentifierMasker.identifiers(inBody: Data(xml.utf8))
        let byValue = Dictionary(identifiers.map { ($0.value, $0.kind) }, uniquingKeysWith: { first, _ in first })
        #expect(byValue["Lab Mac"] == .device)
        #expect(byValue["6F3A6C1E-2B0D-4E9B-9C1A-1D2E3F4A5B6C"] == .device)
        #expect(byValue["jdoe"] == .user)
        #expect(byValue["C02XK1JHJG5H"] == .device)
        #expect(byValue["Engineers"] == nil)
    }

    @Test("Paths: serials and UDIDs, but a Blueprint’s UUID is an object ID")
    func paths() {
        let blueprint = "5b1f7c2e-1111-2222-3333-444455556666"
        let identifiers = IdentifierMasker.identifiers(
            inPath: "/JSSResource/computers/udid/6F3A6C1E-2B0D-4E9B-9C1A-1D2E3F4A5B6C?serial=C02XK1JHJG5H")
        #expect(Set(identifiers.map(\.value)) == ["6F3A6C1E-2B0D-4E9B-9C1A-1D2E3F4A5B6C", "C02XK1JHJG5H"])
        #expect(IdentifierMasker.identifiers(inPath: "/blueprints/v1/blueprints/\(blueprint)/deploy").isEmpty)
        #expect(IdentifierMasker.identifiers(inPath: "/api/v1/devices/00008103-001A2C3E0C38001E").map(\.value)
                == ["00008103-001A2C3E0C38001E"])
        // a numeric ID isn’t a serial number
        #expect(IdentifierMasker.identifiers(inPath: "/api/v1/computers/1234567890").isEmpty)
    }

    @Test("Each value gets one stable placeholder, numbered per kind in order of appearance")
    func stablePlaceholders() {
        let masker = IdentifierMasker([
            FoundIdentifier(.device, "C02XK1JHJG5H"),
            FoundIdentifier(.user, "jane@corp.example"),
            FoundIdentifier(.device, "F9FXK2LMQ1GC"),
            FoundIdentifier(.device, "c02xk1jhjg5h"),
        ])
        let text = "GET /serial/C02XK1JHJG5H for jane@corp.example, then F9FXK2LMQ1GC and c02xk1jhjg5h again"
        #expect(masker.mask(text) == "GET /serial/<device 1> for <user 1>, then <device 2> and <device 1> again")
    }

    @Test("Longer values win, and whole words only, so nothing is cut into pieces")
    func longestFirstAndWholeWords() {
        let masker = IdentifierMasker([
            FoundIdentifier(.user, "jordy"),
            FoundIdentifier(.user, "jordy@corp.example"),
            FoundIdentifier(.user, "mac"),
            FoundIdentifier(.user, "device"),
        ])
        #expect(masker.mask("jordy@corp.example and jordy use macOS on a mac")
                == "<user 2> and <user 1> use macOS on a <user 3>")
        // a value that appears in a placeholder never breaks it
        #expect(masker.mask("device jordy") == "<user 4> <user 1>")
    }

    @Test("Values in an encoded address are masked: after a percent escape, and in encoded form")
    func encodedAddresses() {
        let masker = IdentifierMasker([
            FoundIdentifier(.device, "C02XK1JHJG5H"),
            FoundIdentifier(.user, "jane@corp.example"),
        ])
        #expect(masker.mask("GET /api/v2/mobile-devices/detail?filter=serialNumber%3D%3D%22C02XK1JHJG5H%22")
                == "GET /api/v2/mobile-devices/detail?filter=serialNumber%3D%3D%22<device 1>%22")
        #expect(masker.mask("?email=jane%40corp.example&page=0") == "?email=<user 1>&page=0")
        // still whole words only: a value inside a longer one stays
        #expect(masker.mask("%22XC02XK1JHJG5H%22") == "%22XC02XK1JHJG5H%22")
    }

    @Test("Short and common values are never masked")
    func ignoresCommonValues() {
        let masker = IdentifierMasker([FoundIdentifier(.user, "jo"), FoundIdentifier(.user, "Unknown")])
        #expect(masker.mask("jo Unknown") == "jo Unknown")
    }

    @Test("Status items name their identifier in a key field")
    func statusItems() {
        let identifiers = found(#"[{"key":"device.identifier.serial-number","value":"C02XK1JHJG5H"}]"#)
        #expect(identifiers == [FoundIdentifier(.device, "C02XK1JHJG5H")])
    }
}
