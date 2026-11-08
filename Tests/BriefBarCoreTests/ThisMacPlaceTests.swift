import Testing

/// Tests run BriefBar's code on your Mac, so what BriefBar does on it beyond its own windows and files, opening a link, a
/// file or an app, showing files in the Finder, putting text on the clipboard, and asking in an alert or a panel, goes
/// through `ThisMac`, which refuses each in tests: nothing else does any of them. Otherwise a test whose code met one, as
/// delivering a prompt to a session does once it's sent, would open it: the Copilot app, not knowing the session, said it
/// couldn't find it.
struct ThisMacPlaceTests {
    @Test(.onTestThreads) func onlyThisMacOpensCopiesOrAsks() throws {
        let effects = /NSWorkspace\.shared\.(open|activateFileViewerSelecting)|NSPasteboard\.general\.(clearContents|setString|setData|writeObjects|declareTypes|setPropertyList)|\.runModal\(/
        #expect(try sourcesMatching(effects) == ["BriefBarUI/ThisMac.swift"])
    }
}
