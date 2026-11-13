import Foundation
import OsbManagerCore

enum FrameCheck {
    static let option = "--check-frames"
    static let expected = ["OsbManagerCore.NativeStack.selfCheck", "OsbManagerApp.FrameCheck.run"]

    @inline(never)
    static func run() -> Never {
        let own = NativeStack.selfCheck().filter { $0 != FrameReducer.external }
        print(own.joined(separator: "\n"))
        exit(expected.allSatisfy(own.contains) ? 0 : 1)
    }
}
