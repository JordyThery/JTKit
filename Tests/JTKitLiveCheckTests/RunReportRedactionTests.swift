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
        #expect(LiveCheckRun.redacted("Test Mac 7 in Field iPads", hiding: ["Test Mac 7", "Field iPads"]) == "<id> in <id>")
        #expect(LiveCheckRun.redacted("path pro/v1/groups/12, id=12, computer #12", hiding: ["12"])
                == "path pro/v1/groups/<id>, id=<id>, computer #<id>")
        // followed by punctuation: still an ID; followed by a digit after a period: a version
        #expect(LiveCheckRun.redacted("read group 501. Then group 501) and device 501: done; group 501.2", hiding: ["501"])
                == "read group <id>. Then group <id>) and device <id>: done; group 501.2")
    }

    @Test("A numeric ID doesn’t mask counts, dates, versions or builds")
    func numbersStayReadable() {
        let text = "12 devices run 15.8.1 (24G12), reported 2026-10-14T19:08, 10 of 27"
        #expect(LiveCheckRun.redacted(text, hiding: ["10", "12", "14", "15", "27", "8"]) == text)
    }
}
