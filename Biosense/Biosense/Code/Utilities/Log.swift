import Foundation

/// Shared timestamp formatter for console logs (HH:mm:ss.SSS).
private let _logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// Timestamped console log.  Drop-in replacement for `debugPrint`.
/// Prints: `[HH:mm:ss.SSS] <items>`
func tLog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let ts = _logDateFormatter.string(from: Date())
    let body = items.map { "\($0)" }.joined(separator: separator)
    print("[\(ts)] \(body)", terminator: terminator)
}
