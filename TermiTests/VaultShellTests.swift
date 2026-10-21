import Testing
import SwiftUI
@testable import Termi

// The vault page shell's one rule that pages and tests have to agree on: how many card columns
// a content width gets, and how the open inspector caps them at two.

@Test func itemGridColumnsFollowTheRoom() {
    // Wide window, panel closed: three.
    #expect(DSItemGridColumns.count(width: 1200, inspectorVisible: false) == 3)
    #expect(DSItemGridColumns.count(width: 980, inspectorVisible: false) == 3)
    // Narrower: two, then one — a card is never squeezed below its minimum.
    #expect(DSItemGridColumns.count(width: 979, inspectorVisible: false) == 2)
    #expect(DSItemGridColumns.count(width: 900, inspectorVisible: false) == 2)
    #expect(DSItemGridColumns.count(width: 520, inspectorVisible: false) == 2)
    #expect(DSItemGridColumns.count(width: 519, inspectorVisible: false) == 1)
    // With the inspector open two columns are the most, even in a wide window.
    #expect(DSItemGridColumns.count(width: 1400, inspectorVisible: true) == 2)
    #expect(DSItemGridColumns.count(width: 900, inspectorVisible: true) == 2)
    #expect(DSItemGridColumns.count(width: 400, inspectorVisible: true) == 1)
}
