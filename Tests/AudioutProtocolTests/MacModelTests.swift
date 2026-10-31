// SPDX-License-Identifier: MIT

import Testing
@testable import AudioutProtocol

@Suite struct MacModelTests {

    // Turns red if the family prefix stops being read from the front of an older code.
    @Test func olderCodesNameTheirFamilyFromThePrefix() {
        #expect(MacModel.friendlyName(forCode: "MacBookPro17,1") == "MacBook Pro")
        #expect(MacModel.friendlyName(forCode: "MacBookAir10,1") == "MacBook Air")
        #expect(MacModel.friendlyName(forCode: "Macmini9,1") == "Mac mini")
        #expect(MacModel.friendlyName(forCode: "iMac21,1") == "iMac")
        #expect(MacModel.friendlyName(forCode: "iMacPro1,1") == "iMac Pro")
        #expect(MacModel.friendlyName(forCode: "MacPro7,1") == "Mac Pro")
    }

    // Turns red if an Apple silicon code is dropped from the table or mapped to the wrong product.
    @Test func appleSiliconCodesComeFromTheTable() {
        #expect(MacModel.friendlyName(forCode: "Mac13,1") == "Mac Studio")
        #expect(MacModel.friendlyName(forCode: "Mac14,2") == "MacBook Air")
        #expect(MacModel.friendlyName(forCode: "Mac14,3") == "Mac mini")
        #expect(MacModel.friendlyName(forCode: "Mac15,6") == "MacBook Pro")
        #expect(MacModel.friendlyName(forCode: "Mac15,4") == "iMac")
    }

    // Turns red if an unknown, empty or non-model string returns anything but plain Mac.
    @Test func anUnlistedOrBrokenCodeIsJustMac() {
        #expect(MacModel.friendlyName(forCode: "Mac99,9") == "Mac")
        #expect(MacModel.friendlyName(forCode: "") == "Mac")
        #expect(MacModel.friendlyName(forCode: nil) == "Mac")
        #expect(MacModel.friendlyName(forCode: "garbage") == "Mac")
        #expect(MacModel.friendlyName(forCode: "Audiout-A6439E9A") == "Mac")
    }
}
