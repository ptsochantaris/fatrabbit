import Foundation

/// What the system currently thinks of the volume we have been pointed at.
enum MountState {
    /// Nothing in the system claims it.
    case free
    /// Mounted, along with the device node the system reports and where it is mounted.
    case mounted(device: String, at: [String])
    /// A disk image attached with nothing mounted from it. The device is still live — it reads
    /// through the file we would be writing — but no filesystem is in the way.
    case attached(device: String)
}

/// Works out whether `path` is currently mounted, so a run can refuse rather than fight the
/// kernel for a live filesystem. Writing underneath a mounted volume is the one way to lose data
/// here that the copy-then-repoint design cannot protect against: the kernel holds its own idea
/// of the FAT and directory blocks, and will write them back over ours whenever it pleases.
///
/// Two cases, because both are ways in which the volume this tool is aimed at gets mounted: a
/// device node, which the mount table answers directly, and an image file, where the mount table
/// names the shim device in front of the file rather than the file itself.
///
/// Both answers come from the system rather than from a command-line tool, so there is nothing to
/// find on `PATH` and no output format to keep up with. The four platform-specific pieces this
/// needs — the mount table, the claims test, device canonicalisation and the image lookup — live
/// in `System`, so the reasoning below is the same on every platform.
func mountState(ofVolumeAt path: String) -> MountState {
    let target = System.canonicalDevice(System.resolve(path))
    let mounts = System.mountedFilesystems()

    // A device node — including the case where the caller passed a whole disk one of whose slices
    // is mounted, which is just as fatal as naming the slice itself.
    let direct = mounts.filter { System.claims(target, $0.device) || target == $0.mountPoint }
    if let first = direct.first {
        return .mounted(device: first.device, at: direct.map(\.mountPoint))
    }

    // An image file: ask the system which devices, if any, are reading through this file, then
    // look those up in the mount table.
    let devices = System.imageDevices(backing: target)
    guard let whole = devices.first else { return .free }
    let indirect = mounts.filter { mount in devices.contains { System.claims($0, mount.device) } }
    guard let first = indirect.first else { return .attached(device: whole) }
    return .mounted(device: first.device, at: indirect.map(\.mountPoint))
}
