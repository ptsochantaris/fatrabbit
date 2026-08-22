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

/// The edits `--deMac` applies to directory data as it is relocated.
struct MacCleanup {
    /// Offsets, within one run of directory data, of the 32-byte entries to mark deleted. A removed
    /// name covers its short entry plus every long-name entry preceding it.
    ///
    /// Keyed by that run's absolute device offset rather than by a cluster number, which is what lets
    /// one list describe both kinds of directory. Nearly every run is a cluster; a FAT12/16 root is a
    /// fixed region with no clusters at all, and it is exactly where the root-level metadata this
    /// flag exists to strip — `.Spotlight-V100`, `.fseventsd`, `.Trashes` — is to be found.
    let removals: [UInt64: [Int]]
    let removedNames: [String]
    let removedFiles: Int
    let removedDirectories: Int
    /// Data clusters freed by the removals, including whole subtrees of removed directories.
    let removedClusters: [UInt32]
    /// The `.` and `..` entries found carrying the hidden attribute, as the device offset of the run
    /// holding each and the offset within it. A list of edits gathered by the scan rather than a mark
    /// on every directory, since the entries needing one are a handful and finding them again
    /// would mean reading the whole volume back.
    ///
    /// A fixed root never appears here, having no `.` or `..` of its own, but it is keyed the same
    /// way as `removals` regardless so that one notion of where directory data lives serves both.
    let hiddenDots: [(at: UInt64, offset: Int)]

    var isEmpty: Bool { removedFiles == 0 && removedDirectories == 0 }
}
