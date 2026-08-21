import Foundation

/// Recognises the metadata macOS scatters over a removable volume, which `--deMac` strips.
enum MacCruft {
    /// Volume-level metadata macOS only ever creates at the root of a volume. Matched at the
    /// root alone, so a user directory that happens to share one of these names is left alone.
    private static let rootOnlyNames: Set<String> = [
        ".spotlight-v100",                          // Spotlight index
        ".spotlight-v200",
        ".fseventsd",                               // FSEvents change journal
        ".trashes",                                 // per-volume trash
        ".temporaryitems",
        ".documentrevisions-v100",                  // version store
        ".volumeicon.icns",                         // custom volume icon
        ".apdisk",                                  // volume settings
        ".com.apple.timemachine.donotpresent",
        ".metadata_never_index",
        ".metadata_never_index_unless_rootfs",
        ".background",
        ".pkinstallsandboxmanager",
        ".pkinstallsandboxmanager-systemsoftware"
    ]

    /// True if `name` is macOS cruft. AppleDouble sidecars (`._name`) and `.DS_Store` are
    /// removed wherever they occur; volume-level metadata only at the root.
    static func matches(_ name: String, isRoot: Bool) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("._") { return true }    // AppleDouble resource-fork sidecar
        if lower == ".ds_store" { return true }     // Finder folder settings
        return isRoot && rootOnlyNames.contains(lower)
    }
}

/// The edits `--deMac` applies to directory clusters as they are relocated.
struct MacCleanup {
    /// Offsets, within a directory cluster, of the 32-byte entries to mark deleted. Keyed by
    /// the cluster's original number. A removed name covers its short entry plus every
    /// long-name entry preceding it.
    let removals: [UInt32: [Int]]
    let removedNames: [String]
    let removedFiles: Int
    let removedDirectories: Int
    /// Data clusters freed by the removals, including whole subtrees of removed directories.
    let removedClusters: [UInt32]
    /// The `.` and `..` entries found carrying the hidden attribute, as the cluster holding each
    /// and its offset within that cluster. A list of edits gathered by the scan rather than a mark
    /// on every directory, since the entries needing one are a handful and finding them again
    /// would mean reading the whole volume back.
    let hiddenDots: [(cluster: UInt32, offset: Int)]

    var isEmpty: Bool { removedFiles == 0 && removedDirectories == 0 }
}
