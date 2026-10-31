// SPDX-License-Identifier: MIT

/// Turns the Mac's hardware model code (`hw.model`, advertised in the
/// Bonjour TXT `model` key) into a device type the phone can show before it
/// has connected and learned the computer's own name. Anything unrecognised
/// is just "Mac": a wrong name is worse than a plain one.
public enum MacModel {

    /// Apple silicon codes carry no family in their text (`Mac15,6`), so they
    /// are listed. Checked against mrmacintosh.com's model list; newer
    /// generations are absent until added here.
    private static let appleSilicon: [String: String] = [
        "Mac13,1": "Mac Studio", "Mac13,2": "Mac Studio",
        "Mac14,2": "MacBook Air",
        "Mac14,3": "Mac mini", "Mac14,12": "Mac mini",
        "Mac14,5": "MacBook Pro", "Mac14,6": "MacBook Pro", "Mac14,7": "MacBook Pro",
        "Mac14,9": "MacBook Pro", "Mac14,10": "MacBook Pro",
        "Mac15,3": "MacBook Pro", "Mac15,6": "MacBook Pro", "Mac15,7": "MacBook Pro",
        "Mac15,8": "MacBook Pro", "Mac15,9": "MacBook Pro", "Mac15,10": "MacBook Pro",
        "Mac15,11": "MacBook Pro",
        "Mac15,4": "iMac", "Mac15,5": "iMac",
    ]

    /// Older codes start with the family, then digits (`MacBookPro17,1`).
    private static let families: [String: String] = [
        "MacBookPro": "MacBook Pro", "MacBookAir": "MacBook Air", "MacBook": "MacBook",
        "Macmini": "Mac mini", "iMacPro": "iMac Pro", "iMac": "iMac", "MacPro": "Mac Pro",
    ]

    public static func friendlyName(forCode code: String?) -> String {
        guard let code, !code.isEmpty else { return "Mac" }
        if let name = appleSilicon[code] { return name }
        let prefix = String(code.prefix { !$0.isNumber })
        return families[prefix] ?? "Mac"
    }
}
