import Foundation
import ReadiumNavigator
import ReadiumShared

final class BooksEPUBNavigator: EPUBNavigatorViewController {
    var annotate: ((Locator, Bool) -> Void)?
    @objc func highlightSelection() {
        guard let locator = currentSelection?.locator else { return }
        annotate?(locator, false); clearSelection()
    }
    @objc func noteSelection() {
        guard let locator = currentSelection?.locator else { return }
        annotate?(locator, true); clearSelection()
    }
}
