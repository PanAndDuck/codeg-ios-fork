/// Adapts system paste values and manually entered text to one import closure.
/// The adapter owns no clipboard/UI state and can be tested without UIKit.
struct PairingCodeInput {
    let importCode: (String) -> Bool

    @discardableResult
    func paste(_ values: [String]) -> Bool {
        // One editor imports one code. Empty input still reaches the shared
        // parser so it reports an error and clears any stale relay offer.
        submit(values.first ?? "")
    }

    @discardableResult
    func submit(_ value: String) -> Bool {
        importCode(value)
    }
}
