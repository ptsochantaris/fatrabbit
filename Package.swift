// swift-tools-version: 6.2

import PackageDescription

// fatrabbit is one executable target with no dependencies, no resources and no tests, so almost
// everything here is carrying over what the Xcode project used to say. The settings below are the
// ones that were load-bearing; the rest of what a .pbxproj holds — signing, deployment targets,
// Info.plist keys, the iOS platforms this command-line tool never built for — described a world
// this package does not live in.
//
// The measurement harness under Testing/ is deliberately outside Sources/, so it is not something
// the target has to exclude. It never located the binary through DerivedData, so nothing there
// needed changing when the build moved.

// Release-only flags. Both are things the Xcode project asked for and did not get, which is the
// reason they are written out explicitly here rather than left to the build system:
//
//   -Ounchecked      Xcode's SWIFT_DISABLE_SAFETY_CHECKS turned into `-remove-runtime-asserts`,
//                    which drops `assert` and `precondition` but leaves bounds and overflow
//                    checking in place. `-Ounchecked` is the flag that removes those too, and is
//                    what the setting was being asked for. It is safe here only because cluster
//                    numbers are validated where they are read — `FAT32Volume.chain` refuses
//                    anything outside the data region — rather than at the array subscripts they
//                    later feed, of which there are around 150.
//
//   -lto=llvm-full   `LLVM_LTO = YES` in the project was a C-family setting. There is no C in this
//                    target, so it expanded to nothing at all and no LTO was ever performed. This
//                    is the Swift spelling, and it has to be given to the compile and the link
//                    both, or the bitcode is produced and then ignored.
let releaseOnly: [String] = ["-Ounchecked"]

let package = Package(
    name: "fatrabbit",
    // MACOSX_DEPLOYMENT_TARGET = 26.3, carried over exactly. Not cosmetic: `Mutex.withLock` is
    // macOS 15 and later, and SwiftPM's own default floor is old enough that four files stop
    // compiling without this. Apple platforms only — a Linux build ignores it.
    platforms: [.macOS("26.3")],
    products: [
        // Named for parity with the Xcode target, so the binary the harness and any muscle memory
        // reach for keeps the name it had.
        .executable(name: "fatrabbit", targets: ["fatrabbit"])
    ],
    targets: [
        .executableTarget(
            name: "fatrabbit",
            swiftSettings: [
                // SWIFT_VERSION = 6.0. Carries strict concurrency at `complete` with it, so that
                // does not need saying separately.
                .swiftLanguageMode(.v6),
                // The three the Release build was actually passing. `MemberImportVisibility` was
                // set by hand; the other two arrived through SWIFT_APPROACHABLE_CONCURRENCY, which
                // is a bundle rather than a flag and so has to be unpacked into its members here.
                // `NonisolatedNonsendingByDefault` in particular changes what isolation an async
                // function inherits, so leaving it out would not merely lose an optimisation.
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .unsafeFlags(releaseOnly, .when(configuration: .release))
            ]
        )
    ]
)

// `unsafeFlags` bars a package from being used as a dependency. fatrabbit is a root executable and
// will never be one, so the bar costs nothing and is the supported way to say these two things in
// a manifest. Release builds are whole-module and `-O` by default under SwiftPM, so neither is
// repeated above.
