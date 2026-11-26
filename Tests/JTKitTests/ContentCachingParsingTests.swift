import Foundation
import Testing
@testable import JTKit

@Suite("1.11.0: the inventory’s content caching section")
struct ContentCachingInventoryTests {
    @Test("Every field of the test Mac’s section, as Jamf answered it")
    func fixture() throws {
        let computer = try CacheFixture.computer()
        let cache = try #require(computer.contentCaching)
        #expect(cache.isActivated == true && cache.isActive == true)
        #expect(cache.cacheStatus == "OK" && cache.startupStatus == "OK" && cache.registration == .succeeded)
        #expect(cache.registrationError == nil && cache.registrationResponseCode == 0 && cache.registrationStarted == nil)
        #expect(cache.cacheUsed == 162_133 && cache.actualCacheUsed == 162_133 && cache.cacheFree == 195_032_792_064)
        #expect(cache.cacheLimit == nil && cache.personalLimit == nil, "0 is no limit")
        #expect(cache.personalUsed == 162_133 && cache.personalFree == 195_032_792_064)
        #expect(cache.pressurePercent == 0)
        #expect(cache.categories == [.init(name: "iCloud", bytes: 162_133)])
        #expect(cache.categories[0].isPersonal && cache.topCategory == nil, "iCloud is never the top category")
        #expect(cache.countersSince == CacheFixture.date("2026-11-25T09:06:16Z"))
        #expect(cache.returnedToClients == 162_133 && cache.returnedToPeers == 0 && cache.returnedToChildren == 0)
        #expect(cache.storedFromOrigin == 162_133 && cache.storedFromParents == 0 && cache.storedFromPeers == 0)
        #expect(cache.imported == 0 && cache.dropped == 0)
        #expect(cache.parents.isEmpty && cache.alerts.isEmpty)
        #expect(cache.port == 50_519 && cache.publicAddress == "203.0.113.10")
        #expect(cache.serverGuid == "00000000-0000-4000-8000-0000000000CA")
        #expect(cache.isRestrictedMedia == false && cache.tetherator == "CONTENT_CACHING_DISABLED")
        // Jamf reports completed false at 0 % with code 0 on a cache that never moved anything
        let migration = try #require(cache.dataMigration)
        #expect(migration.completed == false && !migration.isMoving && !migration.failed)
        // the general section that comes with it
        #expect(computer.general?.managementID == CacheFixture.managementID)
        #expect(computer.general?.reportDate == CacheFixture.date("2026-11-25T09:08:04.386Z"))
        #expect(computer.general?.site?.assignedName == nil, "Jamf Pro’s “no site”: ID -1, None")
    }

    @Test("Parents, alerts and categories; a field of another type reads anyway; a bad entry is skipped")
    func shapes() throws {
        let json = #"""
        {"id":"7","contentCaching":{"activated":"true","active":1,"cacheBytesUsed":"12","cacheBytesLimit":100,
         "registrationStatus":"CONTENT_CACHING_PENDING","maxCachePressureLast1HourPercentage":"55",
         "cacheDetails":[{"categoryName":"Mac Software","diskSpaceBytesUsed":9000000000},{"diskSpaceBytesUsed":1},
                         {"categoryName":"iCloud","diskSpaceBytesUsed":99000000000}],
         "parents":[{"address":"192.0.2.1","port":49100,"guid":"G","healthy":false,"version":"2.0",
                     "alerts":{"className":"com.apple.AssetCache.LowSpaceAlert","postDate":"2026-11-25T08:00:00Z"},
                     "details":{"acPower":true,"cacheSizeBytes":5000,"portable":false}}],
         "alerts":[{"className":"com.apple.AssetCache.CacheVolumeAlert","postDate":"2026-11-25T08:00:00.000Z","cacheBytesLimit":7}],
         "dataMigrationCompleted":false,"dataMigrationProgressPercentage":40,"dataMigrationError":{"code":0}}}
        """#
        let cache = try #require(try JSONDecoder().decode(JamfPro.Computer.self, from: Data(json.utf8)).contentCaching)
        #expect(cache.isActivated == true && cache.isActive == true && cache.cacheUsed == 12 && cache.cacheLimit == 100)
        #expect(cache.registration == .pending && cache.pressurePercent == 55)
        #expect(cache.categories.map(\.name) == ["Mac Software", "iCloud"])
        #expect(cache.topCategory?.name == "Mac Software")
        let parent = try #require(cache.parents.first)
        #expect(parent == .init(address: "192.0.2.1", port: 49_100, guid: "G", isHealthy: false, version: "2.0",
                                alert: "com.apple.AssetCache.LowSpaceAlert", alertPosted: CacheFixture.date("2026-11-25T08:00:00Z"),
                                acPower: true, cacheSize: 5_000, isPortable: false))
        #expect(cache.alerts.first?.className == "com.apple.AssetCache.CacheVolumeAlert" && cache.alerts.first?.cacheLimit == 7)
        #expect(cache.dataMigration?.isMoving == true)
        // asked without the section: none
        let plain = try JSONDecoder().decode(JamfPro.Computer.self, from: Data(#"{"id":"8","general":{"name":"Mac"}}"#.utf8))
        #expect(plain.contentCaching == nil)
    }

    @Test("Categories as text, as the status item writes them")
    func categoriesText() {
        #expect(JamfPro.ContentCaching.Category.parse(text: "iCloud : 30435304,Other : 1426903")
                == [.init(name: "iCloud", bytes: 30_435_304), .init(name: "Other", bytes: 1_426_903)])
        #expect(JamfPro.ContentCaching.Category.parse(text: "Mac Software:5, broken, : 3,Apps : x") == [.init(name: "Mac Software", bytes: 5)])
        #expect(JamfPro.ContentCaching.Category.parse(text: "").isEmpty)
    }

    @Test("The site: a computer’s and a mobile device’s; Jamf Pro’s “no site” is none")
    func site() throws {
        let computer = try JSONDecoder().decode(JamfPro.Computer.self, from: Data(#"{"id":"7","general":{"site":{"id":"3","name":"Studio"}}}"#.utf8))
        #expect(JamfPro.GroupMember(computer: computer)?.siteName == "Studio")
        #expect(JamfPro.GroupMember(computer: try CacheFixture.computer())?.siteName == nil)
        let detail = try LosslessJSON(data: Data(#"{"mobileDeviceId":"4","general":{"site":{"id":"2","name":"Field"}}}"#.utf8))
        #expect(JamfPro.GroupMember(mobileDetail: detail)?.siteName == "Field")
        let member = try LosslessJSON(data: Data(#"{"mobileDeviceId":"5","siteName":"None","siteId":"-1"}"#.utf8))
        #expect(JamfPro.GroupMember(mobileDevice: member)?.siteName == nil)
        #expect(JamfPro.Site(id: "1", name: "Field").assignedName == "Field")
    }

    @Test("A device’s site comes through classification and is saved; a device saved before 1.11.0 reads without one")
    func deviceSite() throws {
        var member = JamfPro.GroupMember(id: "7", kind: .computer, name: "Mac 7", serialNumber: "ZZTEST7")
        member.siteName = "Studio"
        let device = SoftwareUpdateRules.Classifier.classify(
            SoftwareUpdateRules.DeviceInput(member: member, status: nil),
            context: SoftwareUpdateRules.ClassificationContext(target: nil, serverTimeZone: .gmt, now: Date()))
        #expect(device.siteName == "Studio")
        let saved = try JSONEncoder().encode(device)
        #expect(try JSONDecoder().decode(SoftwareUpdateRules.DeviceStatus.self, from: saved).siteName == "Studio")
        var old = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        old["siteName"] = nil
        let older = try JSONDecoder().decode(SoftwareUpdateRules.DeviceStatus.self, from: try JSONSerialization.data(withJSONObject: old))
        #expect(older.siteName == nil && older.name == "Mac 7")
    }

    @Test("The device’s declaration report carries Apple’s declaration type")
    func payloadType() throws {
        let json = try LosslessJSON(data: try CacheFixture.data("declarations.json"))
        let reports = (json["results"]?.arrayValue ?? []).compactMap(JamfPlatform.DeclarationReport.init(json:))
        #expect(reports.map(\.payloadType) == [JamfPlatform.ContentCacheSettings.declarationType,
                                               "com.apple.configuration.softwareupdate.enforcement.specific"])
        #expect(reports[0].declarationIdentifier == "Blueprint_\(CacheFixture.blueprintID)_s1_c1_declaration_custom_0")
        #expect(reports[0].status == .successful && reports[0].active == true)
    }
}

@Suite("1.11.0: the macOS 27 content cache status items")
struct ContentCacheStatusTests {
    @Test("The test Mac’s flattened items; the two keys older than their item are dropped")
    func flattened() throws {
        let status = try #require(JamfPro.ContentCacheStatus(items: try CacheFixture.statusItems()))
        let info = try #require(status.info)
        #expect(info.cacheUsed == 31_862_207 && info.cacheFree == 194_989_865_984 && info.cacheLimit == nil)
        #expect(info.cacheStatus == "OK" && info.pressurePercent == 0)
        #expect(info.personalUsed == 30_435_304 && info.personalFree == 194_989_865_984 && info.personalLimit == nil)
        #expect(info.categories == [.init(name: "iCloud", bytes: 30_435_304), .init(name: "Other", bytes: 1_426_903)])
        #expect(info.updated == "2026-11-25T09:13:50.911")
        let main = try #require(status.status)
        #expect(main.isActivated == true && main.isActive == true && main.cacheStatus == "OK" && main.startupStatus == "OK")
        #expect(main.privateAddresses == ["192.0.2.10"] && main.publicAddress == "203.0.113.10" && main.port == 50_519)
        #expect(main.registrationStatus == 1 && main.tetheratorStatus == 0 && main.version == "265.40.2")
        #expect(main.serverGuid == "00000000-0000-4000-8000-0000000000CA")
        // left from before the cache registered, hours older than the item’s other keys
        #expect(main.registrationError == nil && main.registrationResponseCode == nil)
        #expect(status.droppedKeys == ["content-cache.status.registration-error", "content-cache.status.registration-response-code"])
        // an older item on its own is current: items are independent
        #expect(status.parents == [] && status.peers == [])
    }

    @Test("A key a few milliseconds older than the newest is current; one more than a minute older isn’t")
    func tolerance() {
        let items = [JamfPro.StatusItem(key: "content-cache.info.cache-used", value: "5", lastUpdateTime: "2026-11-25T09:13:50.91"),
                     JamfPro.StatusItem(key: "content-cache.info.cache-free", value: "6", lastUpdateTime: "2026-11-25T09:13:00.1"),
                     JamfPro.StatusItem(key: "content-cache.info.cache-status", value: "OK", lastUpdateTime: "2026-11-25T09:12:40"),
                     JamfPro.StatusItem(key: "content-cache.info.cache-limit", value: "9")]
        let status = JamfPro.ContentCacheStatus(items: items)
        #expect(status?.info?.cacheUsed == 5 && status?.info?.cacheFree == 6 && status?.info?.cacheLimit == 9)
        #expect(status?.info?.cacheStatus == nil && status?.droppedKeys == ["content-cache.info.cache-status"])
    }

    @Test("Nested JSON and Jamf Pro’s {key=value} text read the same as flattened keys; removed entries are left out")
    func nested() throws {
        let time = "2026-11-25T09:13:50.9"
        let json = [
            JamfPro.StatusItem(key: "content-cache.info", value: #"{"cache-used":31862207,"cache-limit":0,"cache-status":"OK","max-cache-pressure-last-hour":0.15,"cache-details":"iCloud : 30435304,Other : 1426903"}"#, lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.status", value: #"{"server-guid":"G1","activated":true,"active":false,"private-addresses":["192.0.2.10","192.0.2.11"],"port":50519,"registration-status":1}"#, lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.parents", value: #"[{"identifier":"P1","address":"192.0.2.1","port":51194,"healthy":true,"version":"2.0"},{"identifier":"P2","_removed":true}]"#, lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.peers", value: #"[{"identifier":"Q1","address":"192.0.2.20","port":51194,"friendly":true,"healthy":false,"version":"2.0"}]"#, lastUpdateTime: time),
        ]
        let java = [
            JamfPro.StatusItem(key: "content-cache.info", value: "{cache-used=31862207, cache-details=iCloud : 30435304,Other : 1426903, cache-limit=0, cache-status=OK, max-cache-pressure-last-hour=0.15}", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.status", value: "{server-guid=G1, activated=true, active=false, private-addresses=[192.0.2.10, 192.0.2.11], port=50519, registration-status=1}", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.parents", value: "[{identifier=P1, address=192.0.2.1, port=51194, healthy=true, version=2.0}, {identifier=P2, _removed=true}]", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.peers", value: "[{identifier=Q1, address=192.0.2.20, port=51194, friendly=true, healthy=false, version=2.0}]", lastUpdateTime: time),
        ]
        let flattened = [
            JamfPro.StatusItem(key: "content-cache.parents.0.identifier", value: "P1", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.parents.0.address", value: "192.0.2.1", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.parents.0.port", value: "51194", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.parents.0.healthy", value: "true", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.parents.0.version", value: "2.0", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.parents[1].identifier", value: "P2", lastUpdateTime: time),
            JamfPro.StatusItem(key: "content-cache.parents[1]._removed", value: "true", lastUpdateTime: time),
        ]
        let parent = JamfPro.ContentCacheStatus.Neighbor(identifier: "P1", address: "192.0.2.1", port: 51_194, isHealthy: true, version: "2.0")
        let peer = JamfPro.ContentCacheStatus.Neighbor(identifier: "Q1", address: "192.0.2.20", port: 51_194, isHealthy: false,
                                                       isFriendly: true, version: "2.0")
        for items in [json, java] {
            let status = try #require(JamfPro.ContentCacheStatus(items: items))
            #expect(status.info?.cacheUsed == 31_862_207 && status.info?.cacheLimit == nil && status.info?.cacheStatus == "OK")
            #expect(status.info?.pressurePercent == 15)
            #expect(status.info?.categories.map(\.bytes) == [30_435_304, 1_426_903])
            #expect(status.status?.serverGuid == "G1" && status.status?.isActivated == true && status.status?.isActive == false)
            #expect(status.status?.privateAddresses == ["192.0.2.10", "192.0.2.11"] && status.status?.port == 50_519)
            #expect(status.parents == [parent] && status.peers == [peer])
        }
        #expect(JamfPro.ContentCacheStatus(items: flattened)?.parents == [parent])
    }

    @Test("Pressure: Apple’s fraction as a percentage; a whole number as it is")
    func pressure() {
        #expect(JamfPro.ContentCacheStatus.percent("0.15") == 15)
        #expect(JamfPro.ContentCacheStatus.percent("1.0") == 100)
        #expect(JamfPro.ContentCacheStatus.percent("0") == 0)
        #expect(JamfPro.ContentCacheStatus.percent("72") == 72)
        #expect(JamfPro.ContentCacheStatus.percent("x") == nil)
    }

    @Test("No content-cache item: nil")
    func none() {
        #expect(JamfPro.ContentCacheStatus(items: [JamfPro.StatusItem(key: "device.operating-system.version", value: "27.2")]) == nil)
    }
}

@Suite("1.11.0: a Blueprint’s content caching declaration")
struct ContentCacheSettingsTests {
    @Test("The test Blueprint: Jamf’s com.jamf.ddm-strict component with Apple’s declaration")
    func fixture() throws {
        let blueprint = try CacheFixture.blueprint()
        #expect(blueprint.isCachingBlueprint)
        let settings = try #require(blueprint.contentCacheSettings.first)
        #expect(blueprint.contentCacheSettings.count == 1)
        #expect(settings.componentIdentifier == "com.jamf.ddm-strict" && settings.stepIndex == 0 && settings.componentIndex == 0)
        #expect(settings.stepName == "Components in this blueprint" && settings.activationPredicate == nil)
        #expect(settings.keepAwake == true && settings.autoActivation == true && settings.allowSharedCaching == true)
        #expect(settings.allowPersonalCaching == nil && settings.cacheLimit == nil && settings.parents == nil)
        #expect(settings.declarativeStatusInterval == 300 && settings.sendsLiveFigures)
        // as the device reported it (declarations.json)
        #expect(settings.configurationIdentifier(blueprintID: blueprint.id) == "Blueprint_\(CacheFixture.blueprintID)_s1_c1_declaration_custom_0")
        #expect(settings.identifierPrefix(blueprintID: blueprint.id.uppercased()) == "Blueprint_\(CacheFixture.blueprintID)_s1_c1_")
    }

    @Test("A custom-declarations component, Jamf’s Included wrapping, zeros as “not set”, in its step")
    func custom() throws {
        let json = #"""
        {"id":"b2","name":"Caches","steps":[{"name":"One","components":[{"identifier":"com.jamf.ddm.sw-updates","configuration":{}}]},
         {"name":"Two","activationPredicate":"@status(device.operating-system.family) == 'macOS'","components":[
          {"identifier":"com.jamf.ddm.passcode-settings","configuration":{}},
          {"identifier":"com.jamf.ddm.custom-declarations","configuration":{"declarations":[
            {"type":"com.apple.configuration.safari.settings","payload":{}},
            {"type":"com.apple.configuration.content-cache.settings","payload":{
              "CacheLimit":{"Included":true,"Value":1000},"Port":{"Included":false,"Value":80},"PersonalCacheLimit":0,
              "Parents":["192.0.2.1","192.0.2.2"],"ParentSelectionPolicy":"first-available","AllowPersonalCaching":false,
              "LocalSubnetsOnly":false,"DeclarativeStatusInterval":0}}]}}]}]}
        """#
        let blueprint = try JamfPlatform.BlueprintDetail(data: Data(json.utf8))
        let settings = try #require(blueprint.contentCacheSettings.first)
        #expect(settings.stepIndex == 1 && settings.componentIndex == 1 && settings.declarationIndex == 1)
        #expect(settings.stepName == "Two" && settings.activationPredicate?.contains("macOS") == true)
        #expect(settings.cacheLimit == 1_000 && settings.port == nil && settings.personalCacheLimit == nil)
        #expect(settings.parents == ["192.0.2.1", "192.0.2.2"] && settings.parentSelectionPolicy == "first-available")
        #expect(settings.allowPersonalCaching == false && settings.localSubnetsOnly == false && !settings.sendsLiveFigures)
        #expect(settings.configurationIdentifier(blueprintID: "B2") == "Blueprint_b2_s2_c2_declaration_custom_1")
        let plain = try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"b3","name":"None","steps":[]}"#.utf8))
        #expect(!plain.isCachingBlueprint)
    }

    @Test("Activations are told from configurations by name")
    func activation() {
        #expect(JamfPlatform.ContentCacheSettings.isActivation("Blueprint_x_s1_c1_sys_act1"))
        #expect(!JamfPlatform.ContentCacheSettings.isActivation("Blueprint_x_s1_c1_declaration_custom_0"))
        #expect(!JamfPlatform.ContentCacheSettings.isActivation("Blueprint_x_s1_c1_sys_cfg1"))
    }
}
