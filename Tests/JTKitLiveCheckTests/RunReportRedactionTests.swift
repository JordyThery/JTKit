import Foundation
import Testing
@testable import JTKitLiveCheck

// 1.5.0: a run report never holds a real ID, whatever a test passes to
// `record(step:passed:note:)`. Made-up values only.

@Suite("1.5.0: run reports without IDs")
struct RunReportRedactionTests {
    @Test("UUIDs, declaration identifiers, tokens and serial-shaped words are masked")
    func patterns() {
        let text = "Blueprint_0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f_s1_c1_sys_cfg12 token 9f86d081884c7d659a2feaa0c55ad015 serial ZZTEST12345A"
        let masked = LiveCheckRun.redacted(text)
        #expect(masked == "Blueprint_<id>_s1_c1_sys_cfg12 token <hash> serial <code>")
        // versions, models and short board IDs stay readable
        #expect(LiveCheckRun.redacted("MacBookPro16,1 on 26.7.1, J314sAP") == "MacBookPro16,1 on 26.7.1, J314sAP")
    }

    @Test("Registered values are masked as whole words only")
    func registered() {
        let masked = LiveCheckRun.redacted("group 812 has 8120 devices; device 812", hiding: ["812"])
        #expect(masked == "group <id> has 8120 devices; device <id>")
    }
}
