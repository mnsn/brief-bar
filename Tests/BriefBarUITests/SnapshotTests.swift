import AppKit
import SwiftUI
import Testing
@testable import BriefBarUI

/// `--render` draws hundreds of pictures in one process, which never goes back to an event loop to empty the main thread's
/// autorelease pool. What drawing a picture leaves there must go with the picture, its window and its view graph
/// with it, or SwiftUI runs out of room for its view graphs before the last picture.
@MainActor
struct SnapshotTests {
    private final class Shown: ObservableObject {}

    private struct ShownView: View {
        @ObservedObject var shown: Shown

        var body: some View {
            Text("Needs you").padding()
        }
    }

    @Test func letsGoOfWhatItDrewOnceItsDrawn() {
        weak var gone: Shown?
        let image: NSBitmapImageRep? = {
            let shown = Shown()
            gone = shown
            return Snapshot.render(ShownView(shown: shown), appearance: NSAppearance(named: .aqua))
        }()
        #expect(image.map { $0.pixelsWide > 0 && $0.pixelsHigh > 0 } == true)
        #expect(gone == nil)
    }
}
