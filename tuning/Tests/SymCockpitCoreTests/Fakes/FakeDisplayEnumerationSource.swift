import Foundation
@testable import SymCockpitCore

struct FakeDisplayEnumerationSource: DisplayEnumerationSource, Sendable {
    var screens: [ScreenSnapshot]

    func enumerateScreens() -> [ScreenSnapshot] {
        screens
    }
}
