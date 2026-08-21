import Foundation

/// Turning figures into the shapes people read them in.
///
/// All of it belongs to whoever is displaying, not to the engine: the engine deals in clusters, bytes
/// and `Duration`s, and every choice below — how much precision a number deserves, when an estimate is
/// worth making at all — is a presentation decision. It lives in one file so that the plain output and
/// the block map cannot drift into two dialects of the same run.

// MARK: - Sizes

/// Bytes as someone would say them out loud, for titles and summaries.
func readableBytes(_ bytes: UInt64) -> String {
    let units = ["KiB", "MiB", "GiB", "TiB"]
    guard bytes >= 1024 else { return "\(bytes) bytes" }
    var value = Double(bytes) / 1024
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
}

// MARK: - Counting things

extension BinaryInteger {
    /// The form of a word that goes with this many of them.
    ///
    /// For the words that are not the count itself — a verb agreeing with it, most often. Everything
    /// that *is* a count of something wants `counted` below.
    func word(_ singular: String, _ plural: String) -> String {
        self == 1 ? singular : plural
    }

    /// This many of something, named: `1 cluster`, `2 clusters`, `0 clusters`.
    ///
    /// The reporting used to dodge this thirty times over by writing `cluster(s)`, which is what a
    /// program says when it cannot be bothered to know whether it moved one thing or several — and it
    /// knows exactly. Zero takes the plural, which is what English does.
    func counted(_ singular: String, _ plural: String) -> String {
        "\(self) \(word(singular, plural))"
    }

    /// The same, where the plural is the singular plus an `s` — which covers most of them, and leaves
    /// the ones that are not regular saying so at the point of use rather than everywhere.
    func counted(_ singular: String) -> String {
        counted(singular, singular + "s")
    }
}

// MARK: - Shares

/// A share of the work as a percentage, carrying a decimal while the figure is small.
///
/// A run over a card is well over a million clusters, so early generations are fractions of a percent:
/// truncating them to a whole number prints "0%" beside a generation that plainly did something, which
/// reads as a broken counter rather than as an honest 0.3%. Only ever says 100% when everything counted
/// really has been done.
func percentage(_ done: some BinaryInteger, of total: some BinaryInteger) -> String {
    guard total > 0 else { return "100%" }
    if done >= total { return "100%" }
    let share = Double(done) * 100 / Double(total)
    if share < 10 { return String(format: "%.1f%%", share) }
    return "\(Int(share))%"
}

/// The same share as a fraction for a progress bar, or nil where there is no honest denominator — the
/// scan cannot know how many directories it will find, and a bar that invented one would be lying.
func fraction(_ done: some BinaryInteger, of total: some BinaryInteger) -> Double? {
    guard total > 0 else { return nil }
    return min(1, Double(done) / Double(total))
}

// MARK: - Estimates

/// "~52m left", once there is enough behind us to extrapolate from.
///
/// Measured against the whole of the work rather than its current stage, whose rate swings wildly:
/// generations differ in size by orders of magnitude, and a run of tiny moves costs nothing like a run
/// of large ones. Suppressed for the first few seconds, where the sample is too small to do anything
/// but mislead.
func estimate(_ done: some BinaryInteger, of total: some BinaryInteger,
              since start: ContinuousClock.Instant) -> String? {
    let elapsed = start.duration(to: .now).totalSeconds
    guard elapsed > 5, done > 0, done < total else { return nil }
    let remaining = Double(Int(total) - Int(done)) * (elapsed / Double(done))
    return "~\(Duration.seconds(remaining).coarse) left"
}

/// Average rate as bytes actually moved over the time taken. Worth reporting because on slow media it
/// is what tells you whether the medium or the work is the limit — and a generation of thousands of
/// one-cluster moves reads very differently from one large sequential run.
func rate(clusters: some BinaryInteger, of clusterSize: Int, over duration: Duration) -> String {
    let seconds = duration.totalSeconds
    guard seconds > 0.001, clusters > 0 else { return "—" }
    let mib = Double(clusters) * Double(clusterSize) / (1024 * 1024)
    return String(format: "%.1f MiB/s", mib / seconds)
}

// MARK: - Durations

extension Duration {
    /// Seconds as a single number, for rate and estimate arithmetic.
    var totalSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// As `readable`, but never finer than a whole second, rounded up.
    ///
    /// For predictions rather than measurements. "~3.5s left" claims a precision an extrapolation
    /// from an average rate does not have, and the tenth changes several times a second while it
    /// sits on screen, which reads as fidgeting rather than as information.
    var coarse: String {
        let whole = max(1, Int(totalSeconds.rounded(.up)))
        let (hours, minutes, seconds) = (whole / 3600, (whole % 3600) / 60, whole % 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// Rendered the way someone reads a clock rather than a stopwatch: never more precision than
    /// the figure deserves, so a run that takes all afternoon reports "2h 14m" rather than a count
    /// of seconds nobody will parse.
    var readable: String {
        let total = totalSeconds
        if total < 1 { return String(format: "%.0fms", total * 1000) }
        if total < 60 { return String(format: "%.1fs", total) }
        let whole = Int(total.rounded())
        let (hours, minutes, seconds) = (whole / 3600, (whole % 3600) / 60, whole % 60)
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m \(seconds)s"
    }
}
