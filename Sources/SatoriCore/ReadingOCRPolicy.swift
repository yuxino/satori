import Foundation

/// Keeps remote OCR for small, high-fidelity reading bridges. Larger ranges
/// are usually chapter maps, where local OCR gives enough structure without
/// turning one reading action into a request per scanned page.
public enum ReadingOCRPolicy {
    public static let maxRemoteOCRPagesForRange = 4

    public static func usesRemoteOCR(forPageRangeCount count: Int, hasQwenConfiguration: Bool) -> Bool {
        hasQwenConfiguration
            && count > 0
            && count <= maxRemoteOCRPagesForRange
    }
}
