import Foundation

/// Asks which volume to work on, when the command line did not say.
///
/// The one rule this exists to enforce: a run never starts on a device nobody named. Where a path was
/// given, that is the naming and none of this happens. Where it was not, the list is shown and the
/// question asked *even when there is exactly one candidate* — a single attached card is the case
/// where guessing would be most tempting, and the case where being wrong costs the most, since the
/// only way to be wrong is to rewrite the wrong volume.
///
/// Plain lines and a line of input, deliberately. `Terminal` has the machinery for a full-screen
/// selector and this uses none of it: this runs before the event stream exists, so nothing has yet
/// taken the alternate screen or put the terminal in raw mode, and a prompt that needs neither works
/// the same over ssh, in tmux, and under a `TERM` the display would refuse to draw on.
enum DevicePicker {
    /// Nothing was chosen, and why.
    ///
    /// Its own error type rather than a `FATError`, because none of these are faults of a volume —
    /// they are answers to "which volume", and "I/O error:" in front of them would be a lie.
    struct Unresolved: Error, CustomStringConvertible {
        let description: String
    }

    /// The chosen device node, or nil where the answer was to do nothing.
    static func choose(includingFixed: Bool) throws(Unresolved) -> String? {
        // Both ends have to be a terminal: stdin because there has to be somebody to answer, and
        // stderr because the question and the list go there, and asking one that nobody can see is
        // worse than not asking. A scripted run therefore fails exactly as it does today.
        guard isatty(STDIN_FILENO) != 0, isatty(STDERR_FILENO) != 0 else {
            throw Unresolved(description: """
            Missing expected argument '<volume>'.
            It may be left out only when there is a terminal to ask on: a run with its input or its \
            output redirected has to name the device itself.
            """)
        }

        let findings = DeviceScan.sweep(includingFixed: includingFixed)
        let offered = findings.candidates.filter(\.isAvailable)
        guard !offered.isEmpty else {
            throw Unresolved(description: nothingToOffer(findings, includingFixed: includingFixed))
        }

        Terminal.write(listing(findings, includingFixed: includingFixed))

        let range = offered.count == 1 ? "1" : "1-\(offered.count)"
        while true {
            Terminal.write("Pick a volume [\(range), q to abort]: ")
            // nil is end of input, which is the same answer as an empty line: do nothing.
            guard let answer = readLine(strippingNewline: true)?
                .trimmingCharacters(in: .whitespaces) else {
                Terminal.write("\n")
                return nil
            }
            if answer.isEmpty || answer.lowercased() == "q" { return nil }
            if let number = Int(answer), number >= 1, number <= offered.count {
                return offered[number - 1].device.node
            }
            Terminal.write("  Not one of the choices.\n")
        }
    }

    // MARK: - Drawing it

    /// The list, as one string ending in a blank line.
    ///
    /// Numbers belong to the volumes that can actually be worked on and to no others, so the numbers
    /// on screen are exactly the answers that will be accepted. A mounted volume is shown with a `-`
    /// where its number would be and the reason underneath, in the words the run itself would use if
    /// the volume had been named on the command line.
    private static func listing(_ findings: DeviceScan.Findings, includingFixed: Bool) -> String {
        let all = findings.candidates
        let nodes = width(of: all.map(\.device.node))
        let sizes = all.map { readableBytes($0.device.bytes) }
        let sizeColumn = width(of: sizes)
        let names = all.map { $0.name.isEmpty ? "(no name)" : "\"\($0.name)\"" }
        let nameColumn = width(of: names)

        var lines = ["", "Attached FAT volumes:", ""]
        var number = 0
        for (index, candidate) in all.enumerated() {
            let marker: String
            if candidate.isAvailable {
                number += 1
                marker = String(number)
            } else {
                marker = "-"
            }
            lines.append("  " + pad(marker, to: 2, alignRight: true)
                + "  " + pad(candidate.device.node, to: nodes)
                + "  " + pad(candidate.flavour.name, to: 5)
                + "  " + pad(sizes[index], to: sizeColumn, alignRight: true)
                + "  " + pad(names[index], to: nameColumn)
                + "  " + note(for: candidate))
            if case .mounted(let device, let places) = candidate.state {
                lines.append("        at \(places.joined(separator: ", ")) — unmount it first, "
                    + "keeping it attached: \(System.unmountCommand(for: device))")
            }
        }

        // The footnotes are both conditional, and a run as root with --all-devices has neither, so
        // the blank line that separates them from the list is theirs rather than the list's.
        var footnotes: [String] = []
        if findings.unreadable > 0 {
            footnotes.append("  \(findings.unreadable.counted("other device")) could not be read; "
                + "a disk device only opens as root, so this needs sudo.")
        }
        if !includingFixed {
            footnotes.append("  Internal and system disks are not shown. "
                + "--all-devices includes them.")
        }
        if !footnotes.isEmpty { lines.append(contentsOf: [""] + footnotes) }

        lines.append(contentsOf: ["", ""])
        return lines.joined(separator: "\n")
    }

    /// The trailing column: what a person would use to recognise the thing, or why it is not on
    /// offer. The two never both need saying — a mounted volume's whole story is that it is mounted.
    private static func note(for candidate: FATCandidate) -> String {
        if case .mounted = candidate.state { return "mounted" }
        let model = candidate.device.model
        switch candidate.device.attachment {
        case .image: return model.isEmpty ? "disk image" : model
        case .external: return model
        case .fixed: return model.isEmpty ? "internal" : "\(model) (internal)"
        }
    }

    private static func width(of column: [String]) -> Int {
        column.map(\.count).max() ?? 0
    }

    private static func pad(_ text: String, to width: Int, alignRight: Bool = false) -> String {
        let padding = String(repeating: " ", count: max(0, width - text.count))
        return alignRight ? padding + text : text + padding
    }

    // MARK: - Having nothing to offer

    /// Why the list is empty, and what to do about it. Every reason it could be empty gets a
    /// sentence, because "no volumes found" on its own is indistinguishable from a broken tool.
    private static func nothingToOffer(_ findings: DeviceScan.Findings,
                                       includingFixed: Bool) -> String {
        var lines: [String] = []

        // Found, but every one of them is in use. This is the common case in practice: a card the
        // system has helpfully mounted the moment it was plugged in.
        let mounted = findings.candidates.filter { !$0.isAvailable }
        if mounted.isEmpty {
            // Where nothing at all could be opened, that is the finding, and "none found" said first
            // would read as "there is nothing there" when the truth is that nothing was looked at.
            if findings.candidates.isEmpty, findings.unreadable > 0 {
                return ["None of the attached devices could be read, so none of them could be "
                    + "identified: a disk device only opens as root, so this needs sudo.",
                    "A device may also be named directly: fatrabbit \(System.exampleDevice)"]
                    .joined(separator: "\n")
            }
            lines.append(includingFixed
                ? "No FAT volume found on any attached device."
                : "No FAT volume found on any removable, external or image-backed device.")
        } else {
            lines.append("Every FAT volume found is mounted, and a mounted volume is refused:")
            for candidate in mounted {
                guard case .mounted(let device, let places) = candidate.state else { continue }
                let name = candidate.name.isEmpty ? "" : " (\"\(candidate.name)\")"
                lines.append("  \(candidate.device.node)\(name) at \(places.joined(separator: ", "))"
                    + " — \(System.unmountCommand(for: device))")
            }
        }

        if findings.unreadable > 0 {
            lines.append("\(findings.unreadable.counted("device")) could not be read; a disk device "
                + "only opens as root, so this needs sudo.")
        }
        if !includingFixed {
            lines.append("Internal and system disks were not looked at; --all-devices includes them.")
        }
        lines.append("A device may also be named directly: fatrabbit \(System.exampleDevice)")
        return lines.joined(separator: "\n")
    }
}
