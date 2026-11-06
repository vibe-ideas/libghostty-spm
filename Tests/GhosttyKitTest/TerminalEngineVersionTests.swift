import GhosttyKit
import Testing

struct TerminalEngineVersionTests {
    @Test
    func `embedded terminal reports Ghostty 1_4_0 with release fast optimization`() {
        let info = ghostty_info()
        let version = info.version.map { String(cString: $0) } ?? ""
        #expect(version.hasPrefix("1.4.0"))
        #expect(info.build_mode == GHOSTTY_BUILD_MODE_RELEASE_FAST)
    }
}
