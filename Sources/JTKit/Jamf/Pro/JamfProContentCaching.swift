@_exported import JTKitContentCaching

// The content cache model, its DDM status and the status item itself live
// in JTKitContentCaching (1.12.0), which needs Foundation only; JTKit names
// them as before.
extension JamfPro {
    /// A Mac’s content cache, from the `CONTENT_CACHING` section of `v4/computers-inventory`.
    public typealias ContentCaching = JTKitContentCaching.ContentCaching
    /// A Mac’s content cache as its DDM status report gives it (macOS 27).
    public typealias ContentCacheStatus = JTKitContentCaching.ContentCacheStatus
    /// One item of a device’s DDM status report, as Jamf Pro keeps it.
    public typealias StatusItem = DDMStatusItem
}
