import Foundation
import Testing
@testable import BriefBarCore

@Suite struct UpdaterMessageTests {
    @Test func makesOneLineAndReadsItBack() throws {
        let messages = [
            UpdaterMessage(.check),
            UpdaterMessage(.setAutomaticallyChecks, flag: false),
            UpdaterMessage(.state, canCheck: true, automaticallyChecks: true),
            UpdaterMessage(.pending, version: "0.2.0"),
            UpdaterMessage(.attended),
            UpdaterMessage(.hello, version: "2.10.0", path: "/Applications/BriefBar.app/Contents/Helpers/x\ny"),
        ]
        for message in messages {
            let line = message.line
            #expect(!line.contains(UInt8(ascii: "\n")))
            #expect(UpdaterMessage(line: line) == message)
        }
        #expect(String(decoding: UpdaterMessage(.state, canCheck: true, automaticallyChecks: false).line, as: UTF8.self)
            == #"{"automaticallyChecks":false,"canCheck":true,"kind":"state"}"#)
    }

    @Test func ignoresWhatIsntAMessage() {
        for line in ["", "check", "{}", #"{"kind":"selfDestruct"}"#, #"{"kind":7}"#, "[1,2]", #"{"kind":"state","canCheck":"yes"}"#] {
            #expect(UpdaterMessage(line: Data(line.utf8)) == nil, "\(line)")
        }
    }

    @Test func showsOnlyVersionsThatLookLikeOne() {
        #expect(UpdaterMessage(.pending, version: "0.2.0").displayVersion == "0.2.0")
        #expect(UpdaterMessage(.pending, version: "1.0.0-beta.2+7").displayVersion == "1.0.0-beta.2+7")
        for version in ["", "1.0 now", "1.0\n", "<b>1.0</b>", String(repeating: "9", count: 33), "١٫٠"] {
            #expect(UpdaterMessage(.pending, version: version).displayVersion == nil, "\(version)")
        }
        #expect(UpdaterMessage(.pending).displayVersion == nil)
    }
}
