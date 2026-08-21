import Foundation
@testable import SymTuneCore

struct FakeDisplayEnumerationSource: DisplayEnumerationSource, Sendable {
    var screens: [ScreenSnapshot]

    func enumerateScreens() -> [ScreenSnapshot] {
        screens
    }
}
