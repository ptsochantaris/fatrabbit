# Measuring and verifying against real media

Everything here exists because an image file on an SSD is not a drive. It reads and writes an
order of magnitude faster, overlaps reads with writes, and absorbs small writes into a cache —
so it reports "no difference" for changes worth 13% on real hardware, and "8% slower" for the
same change. Anything performance-related has to be measured on the medium the tool is for.

And not only performance. An image also accepts transfers a card refuses: 2 MiB against 128 KiB on
the two measured here, which is enough for an image to run clean while a card silently returns the
wrong bytes. That cost four directories and an unknown amount of file content before it was found —
see the section below. An image A/B proves the arithmetic; only hardware proves the transfers.

**Every card figure below is stale.** They all predate the metadata cache, adjacent-transfer fusion and
the move to `pread`/`pwrite`, each of which changed the shape of a run — so treat the card rows as a
record of what was true when measured, not as a current comparison.

**And so is every spinner figure below**, for a different reason: the volume they were taken on was lost
and rebuilt, and the driver laid it out differently — see "The filesystem driver writes the test volume".
"Where the run stands now" is the only current measurement in this file. The rows further down are kept
because each one records *why* a change was made, and that argument survives even when the absolute
numbers beside it do not.

Two standing rules, so they are not buried below. **Devices are `/dev/rdiskN` and only ever
`/dev/rdiskN`** — the tool redirects itself there, so anything measuring, restoring or capturing
around it must too. **The test device is the 320 GB USB 2.0 spinning drive, the volume named
`SPINTEST`** — resolve the node by that name every time rather than by a number you remember, because
they are handed out in attach order and the number this drive had last session belonged to a
CoreSimulator volume the next. Card figures still appear below as a record, but nothing is being
measured on one at present.

A third standing rule, added after it cost a volume: **ask the device what it will accept, and never
assume an image can stand in for a card on anything to do with how bytes reach the medium.** Both
halves of that are the section immediately below.

## The transfer size has to come from the device, and an image will never tell you

This is the most expensive thing in this file. A run destroyed four directories and an unknown amount
of file content on a 33 GB card, reported success, and left a volume that passed `fsck` and every
structural check there is.

`maxTransfer` was a hardcoded megabyte, justified in its own comment as "a multiple of every
plausible block size" — which quietly conflated two different limits: how a transfer must be
*aligned*, and how large it may be. Devices publish the second. Nobody had asked.

| Device | Advertised maximum | What was being asked for |
| --- | --- | --- |
| USB card reader | **131,072** (128 KiB) | 1 MiB — **8× over** |
| `hdiutil` raw image | 2,097,152 (2 MiB) | 1 MiB — within limits |

On that reader an oversized read returns the **right length of the wrong bytes** — the contents of an
address 65,536 away — with no error at any level. `pread` returns the full count. Nothing is logged.
The copy is then written faithfully to the correct destination, so the FAT, every pointer and every
length agree and only the contents are wrong.

Every read that came back wrong exceeded the advertised limit, and every one came back from exactly
64 KiB away:

| Failing read | Multiple of 64 KiB |
| --- | --- |
| 176 KB | 2.75 |
| 448 KB | 7.00 |
| 512 KB | 8.00 |
| 4,656 KB | 72.75 |

The fix is to ask: `System.maximumTransfer` is the platform seam's ninth member —
`DKIOCGETMAXBYTECOUNTREAD` and its write twin on Darwin, `BLKSECTGET` on Linux — and the megabyte
became `min(what the device says, 1 MiB)`. The ceiling stays for interruptibility and progress
granularity rather than capability: a 64 MB span as one transfer would freeze the block map for its
duration, and the syscall saving from raising it is microseconds against transfers measured in
seconds.

**The methodological lesson, which is the part worth carrying.** An image cannot reproduce this
class of fault *at all*, because images advertise a larger maximum than any card. The same binary
with the same flags completed a full run on a card-identical image — 387,817 verified moves, 1.14M
clusters, not a murmur — while the card failed four times out of four. Every image A/B in this file
is silent on anything that depends on how large a request the medium is given. `ab-verify.py` on an
image proves the *arithmetic*; only hardware proves the *transfers*.

What was measured and ruled out along the way, so nobody repeats it:

- **Not the media, and not read instability.** Two full passes over all 33.5 GB, every 8 MB block
  hashed: 4,000 blocks compared, zero differing. 67 GB of reads. Reads alone are stable — it takes
  writes to provoke.
- **Not the write/read turn.** A durability barrier inserted at exactly the turn from a write pass
  back to a read pass, which is where the budget-triggered flushes had nothing between them: the run
  failed identically, same −65,536 signature. A sync is stronger than a wait, so the wait was never
  going to be the answer either. The flag that did this was measured and then removed.
- **Not the cache.** One failure had the cache holding all 352 blocks of the range and agreeing with
  the medium, while a direct read disagreed. Another had the cache holding none of it.
- **Not the kernel.** No USB or storage error appears in the system log for any of the four runs.

### Verified on both platforms

| Gate | Result |
| --- | --- |
| Card, transfers capped at 64 KiB, full run with `--verify-copies` | all 6,429 generations, 368,255 objects, 1,761,461 clusters, 433,953 transfers, **zero read contradictions**, 0 fragmented, `fsck_msdos` clean |
| Card, same volume, 1 MiB transfers | failed 4/4, always inside the first gigabyte |
| Card, auto-detection, no flags | reports and uses 128 KiB |
| Linux loop device, `max_sectors_kb` = 1280 / 128 / 64 | honours each exactly; silent at 1280, which is above the ceiling |
| Linux, `--verify-copies` at 128 KiB | 3,724 objects moved, contents byte-identical through `fatread.py`, 0 fragmented, `fsck.fat` clean |

The Linux path is tested by lowering the kernel's own advertised maximum —
`echo 128 > /sys/block/loopN/queue/max_sectors_kb` in a `--privileged` container — which is the only
way to exercise the clamp without hardware that misbehaves.

### The harness had the same bug, and so does `dd`

Worth its own heading, because a verifier that is wrong in the same way as the tool it verifies is
worse than no verifier — it manufactures confidence.

`fatread.py` reached the volume through a buffered handle and, fatally, accepted a **short read
without complaint**:

```python
def read_at(self, offset, count):
    self.f.seek(offset)
    return self.f.read(count)          # may return fewer bytes. Silently.
```

A truncated cluster buffer makes the directory parse stop early, so every entry past the truncation
point vanishes. On the card that hid a directory of fifty files — `Eldritch Force/DATA/ROOMART` —
which was present the whole time. It also asked for the entire FAT in one 8 MB request, sixty-four
times what the card accepts. Repaired: positioned reads, looped until complete, capped at the
device's stated maximum, and a hard error rather than a short buffer. The file count on the same
unchanged card went from 272,960 to **273,096**.

`ab-verify.py` was restoring and capturing in 4 MB chunks — thirty-two times over. Both now ask the
device.

And **`dd bs=1m` is not safe on such a device either.** Writing an 18.7 GB image to this card at 1 MB
per block left exactly one file of 59,872 bytes holding entirely foreign content — 57,629 bytes
different, from byte 0 — where the source image had it correct. Every fatrabbit run on that card had
`--verify-copies` on and reported no read contradiction, so the substitution predates them: the
imaging step did it. One bad block in 17,900. Use `bs=128k` on a card, or whatever it advertises.

The general lesson is uncomfortable and worth stating plainly: **every tool in this directory that
touches a device is a suspect until it has been shown to respect the device's limits.** Three of them
did not.

### What it leaves behind, all default-on and free

The dot-entry pass now refuses to write a `.` into a cluster that holds no directory, instead of
taking arbitrary bytes for a directory and patching a pointer into them. That is not hypothetical:
all four destroyed directories carried, at bytes 20 and 26 — exactly the FAT pointer field — that
cluster's own number, under name fields reading `SINCLAIR`, `ZXTape!` and `Navy1`. Those eight bytes
were the repair pass's own handwriting, papering over the loss.

`CopyBatch` treats a missing or wrong-length span as a hard failure rather than skipping it, and the
chain walker distinguishes a bad start cluster from a bad step instead of printing one number twice
once masked and once not.

`--verify-copies` is the one flag kept: it reads every span twice, by two routes, and stops if the
medium contradicts itself. Off by default, since it doubles the read traffic of the copy phase, and
for a medium you have reason to distrust.

## Adding FAT16 and FAT12

The gate that mattered here was not "does FAT16 work" but **"is FAT32 still bit-for-bit what it
was"**, because every geometry change was written as a generalisation that reduces to the old
arithmetic when `rootEntCnt` and `fatSize16` are zero. If that is true, it is provable; if it is
nearly true, it is a corruption waiting for someone else's card. So:

| Gate | Result |
| --- | --- |
| FAT32 A/B, spinning drive, raw node, 2 GiB / 131,007 clusters / 42,000 files | **bytes identical, files identical**, 123s vs 124s |
| FAT32 A/B, same again with `--deMac` | **bytes identical, files identical** |
| FAT32 A/B, image, 9,006 files | bytes identical, files identical |

The `--deMac` row is there because that path was not merely widened but reshaped: erasing directory
entries used to read and write the whole cluster holding them and now covers only the span the edits
fall in, which is what let one code path serve both a cluster and a fixed root region. Fewer
transfers, same bytes — but "same bytes" is a claim about a write path and had to be shown rather
than argued.

Then the new variants, all with `fatread.py` before/after, `contiguity.py`, and `fsck_msdos -n`:

| Volume | Where | Before → after |
| --- | --- | --- |
| FAT16, 32,763 clusters, 3,046 files | image | 709 free runs → 1; high-water 6,957 → 5,624 |
| FAT16, 32,763 clusters, 1,206 files | **spinning drive** | 3 fragmented → 0; 612 free runs → 1 |
| FAT16 with `--deMac` | image | all six root-level metadata entries stripped from the fixed region |
| FAT12, 2,045 clusters, 78 files | image | 37 free runs → 1; high-water 217 → 167 |

Every one: all files byte-identical, 0 objects fragmented, fsck clean, and remounts.

Two notes on what those rows are worth. **The FAT12 row is stronger than it looks** — 133 moves
rewrote essentially the whole table, and an independent 12-bit decoder read every chain back
afterwards, which it could only do if the packed encode is right for both odd and even clusters.
**The FAT16-on-hardware row is weaker than it looks**: what hardware catches that an image does not
is how bytes reach the medium, and that path is entirely shared and unchanged. The FAT16 differences
are addressing and encoding, which an image exercises just as well. It was run because it was cheap,
not because the image result was in doubt.

`SPINTEST` was snapshotted before any of this and restored from that snapshot afterwards, verified
byte-for-byte by digest, so the measurement baseline below is the same volume it always was.

One thing was not verified: `make linux`, because no Docker daemon was running. The change touches no
platform file and adds no `#if os`, so there is nothing new for the seam to differ about — but that
is an argument, not a check.

## Where the run stands now

The re-baseline the driver change asked for. Spinning drive, raw node, `SPINTEST` rebuilt to the
recipe under "A measurement run" — 2 GiB, 16 KiB clusters, `small` profile at scale 7, giving
**42,149 files and 2,116 directories, 87,195 of 131,007 clusters in use (66% full)**.

| Phase | | Share | Before the cache work |
| --- | --- | --- | --- |
| Scan | 17.0s | 5.0% | 17.0s |
| Copying | 4m 17s | 76% | 4m 18s |
| Repointing | **40.3s** | 12% | 1m 6s |
| FAT writes | 22.2s | 6.6% | 19.7s |
| Barriers (336) | **10ms** | 0.0% | 10ms |
| **Total** | **5m 37s** | | **6m 1s** |

Replicated, and phase by phase, because the per-phase spread is what says which rows mean anything:

| | copying | repointing | FAT | barriers | total |
| --- | --- | --- | --- | --- | --- |
| Before (1 run) | 258s | 66.0s | 19.7s | 10ms | 361s |
| After, run 1 | 257s | 40.3s | 22.2s | 10ms | 337s |
| After, run 2 | 255s | 40.5s | 21.1s | 7ms | 334s |
| | spread 2.0s | **spread 0.2s** | spread 1.1s | | spread 3s |

**Repointing replicates to 0.2s against a 25.6s change**, which is 128 times the noise and about as
unambiguous as this drive gets. Copying's spread equals its change, 2.0s against 2.0s, so the 1,006
fused spans given up are confirmed free rather than merely cheap. The before column is a single run, so
the total is a range: 24 to 27 seconds.

It reconciles, which is the first thing to check of any phase table: copying plus repointing plus FAT
plus barriers is 5m 19.5s against the copy phase, and that plus the scan is the total. Nothing is
unaccounted for.

The right-hand column is the same volume and snapshot before "The cache was working, and only two
thirds working", and the shape of the difference is the point rather than the 24 seconds: **repointing
alone accounts for 107% of it**. That is what a change ought to look like when it is understood — the
saving lands in the one phase that reads directory blocks, not spread thinly across everything where it
could be variance. Copying is unchanged, which also retires the 1,006 fused spans that change gives up:
worth one second, inside noise.

FAT writes went the other way, and calling that variance was too quick: both replicates sit above the
before figure, at 22.2s and 21.1s against 19.7s, so +1.9s on average and both pointing the same way. Two
candidate mechanisms were checked and neither survives. Eviction is not it — `forget` is called outside
the `releasing` timing, so it cannot inflate this row. Nor is "a bigger cache makes every dictionary
operation dearer": FAT writing touches 28,042 blocks across two copies, so some 112,000 lookups and
insertions, and reaching 1.9s that way needs 17µs each, which is two orders of magnitude out.

What is left is the likeliest and dullest explanation — one before-run is not enough to establish a 1.9s
difference when the within-condition spread is 1.1s. It wants a before replicate to settle. Worth
recording rather than resolving: it is 0.6% of a run, sitting inside a 25.6s win, and the honest state of
it is "unexplained and small" rather than either "noise" or "a cost".

Two figures worth carrying forward:

- **336 barriers cost 10ms between them.** On the raw node there is nothing deferred for a flush to
  present, so this is the whole cost, and 168 generations are therefore free. "Barriers are priced per
  byte, not per call" argued this from a different measurement; this settles it. Anything proposing to
  reduce generation count is proposing to save ten milliseconds.
- **92,677 clusters copied for 87,195 clusters of data** — 6.3%, about 90 MB written twice, from 1,033
  staged hops. That is the one number in this table that looks wrong, and it is: the same volume recipe
  used to stage 15. See "The staging tail".

The schedule matches the post-rebuild figures recorded further down exactly — 168 generations, 1,033
staged — which is worth stating because this run was taken across a large refactor of the byte, event
and locking layers. None of it moved a planning decision.

| Script | What it does |
| --- | --- |
| `fatread.py` | Reads every file out of a FAT12/16/32 volume by following the FAT, so two volumes can be compared without mounting either |
| `contiguity.py` | Checks the *claim* rather than the data: every object one extent, free space one run. `fatread.py` proves nothing was lost; this proves the run was worth making, and exits non-zero when it was not |
| `make-test-volume.py` | Builds a fragmented volume of the right shape to measure against — `small` for the operation-bound shape the tool exists for, `mixed` as a bandwidth-bound control, `hollow` when the *schedule* is what is being measured rather than the copy path |
| `medium-baseline.py` | Reports a medium's sequential throughput and its per-operation latency, read-only |
| `ptyrun.py` | Runs the tool on a real pseudo-terminal of a chosen size, capturing every byte — the only way to exercise the block-map display, which switches itself off when output is redirected |
| `screenshot.py` | Replays a capture into a virtual screen: the frame as text, the grid as letters, a colour census, and `--html` for a look at it in colour |
| `ab-verify.py` | Runs two builds over the same volume on real hardware and proves they agree byte for byte — run this before trusting any change to how bytes reach the medium |
| `gap-cost.py` | Measures what a gap costs, so merging decisions come from the drive rather than an estimate |
| `span-gaps.py` | Reads the per-span detail a run emits and predicts how many transfers survive at a range of merge thresholds |
| `queue-depth.py` | Asks whether a device overlaps concurrent reads or serves them one at a time — run it before writing any concurrency |
| `dir-density.py` | How much of each directory cluster the scan actually needs, and what the medium charges per read size — finds the per-command floor |
| `flush-cost.py` | Prices a durability barrier per call against per dirty byte, which decides whether generation count is worth attacking |
| `plan-score.py` | Scores a plan from a dry run — operations after fusion, predicted seek cost — so planner changes can be ranked in seconds without a device |

## The one thing to get right

**Profile shape decides what you are measuring.** A volume of a few large files is
bandwidth-bound: the copy runs at whatever the medium can stream, and per-operation costs
disappear into it. A volume of thousands of small files is operation-bound, and that is the
shape this tool exists for — the card it was written for holds 273,296 files averaging 66 KiB.

One change — batching each generation's copies into a read pass and a write pass — measured
across three media and both profiles. Copy phase only, old build → new build:

| Medium | `small` profile | `mixed` profile |
| --- | --- | --- |
| SD card, 32 GB | 1m 23s → 1m 12s (**13%**) | 2m 28s → 2m 25s (2%) |
| USB 2.0 spinning drive, 320 GB | 1m 54s → 1m 32s (**19%**) | not measured |
| Image file on an SSD | — | **8% slower** |

Raw-device figures for the same runs: card 2m 53s → 2m 38s (9%), spindle 2m 49s → 2m 16s
(20%). All of these repeated to within a second or two across replicates.

Read that table before optimising anything. The `mixed` column and the SSD row say the change
is worthless or harmful; the `small` column says it is worth a fifth of the run on a spindle.
The `small` column is the one describing the volumes this tool is pointed at.

Note also that the spinning drive is the *faster* medium sequentially and still gains more,
because it is 30 times worse per operation. Sequential throughput tells you almost nothing
about what a change to the copy path will do; per-operation latency tells you nearly
everything.

A second change, grouping FAT entry writes by the block they land in rather than by runs of
consecutive clusters, was worth **39% of a run on a card and 19% on the spinning drive** — and
nothing at all when a page cache was underneath, since that had been merging the repeated writes to a
block for free. The run makes 14,844 FAT writes to 3,980 distinct blocks; `--verbose` reports both
figures, and the gap between them is the part worth attacking.

## Checking the block map

The display only appears when stderr is an interactive colour terminal, so a shell pipeline tests
the fallback and nothing else. `ptyrun.py` supplies a terminal; `screenshot.py` reads the result:

    python3 ptyrun.py 120 40 run.cap ./fatrabbit /dev/disk14
    python3 screenshot.py run.cap 120 40 200          # frame 200 as text
    python3 screenshot.py run.cap 120 40 1 --html out.html 8,60,200,545

The colour census is the part that catches real mistakes. A frame's text looks plausible whatever
the colours are doing, so read the counts: a volume 9% full drawing 90% of its cells as occupied is
wrong, and a category that only ever appears exactly twice is appearing in the legend and nowhere
else. That is how the original colouring was found to be useless — it keyed on fragmentation, and
on a volume of one-to-three-cluster files almost nothing is fragmented, because a file of one
cluster cannot be. The map now colours by whether data is where the run intends to leave it, which
is the thing that actually drains away.

`screenshot.py` also fails if any row overruns the window width. That is the fault worth automating:
one character too many and the terminal wraps, every later row lands one row low, and the frame
drifts without ever looking obviously broken.

Two things are worth testing on a slow medium specifically, because neither shows up on an image
file — an SSD is fast enough that the phases blur together:

    python3 ptyrun.py 120 40 stop.cap --interrupt 18,18.05 ./fatrabbit /dev/disk14
    python3 ptyrun.py 120 40 size.cap --resize 3:60x18,5:140x45 ./fatrabbit /dev/disk14

The first is the pair of stop paths — tidy, then immediate — and what matters is not the exit status
but that the terminal comes back: check the capture ends with `?1049l` *followed by* `?25h`, and that
the transcript is replayed after it. Cursor visibility is restored after the buffer switch and not
before, because tmux and some terminals restore it along with the switch and would hide it again.
The second covers a window that changes mid-run, including shrinking below the minimum, where the
frame is replaced by a notice rather than drawn wrong.

The map costs about 1% of a run, and finding that out took disentangling it from something else.

A watched run measured 6m 29s against 6m 14s plain — 15s, which looked like the price of drawing, and
which the engine has three synchronous couplings to explain: a status line composed per move (44,268 of
them), map updates per transfer (~58,000), and a renderer that is already on its own queue. Suppressing
each in turn says none of them:

| Variant | Total | Copying |
| --- | --- | --- |
| Full display | 5m 52s | 4m 7s |
| No status line | 5m 50s | 4m 5s |
| No map updates | 5m 50s | 4m 4s |
| Neither | 5m 48s | 4m 3s |

**4 seconds between the extremes, 2s per coupling, against run-to-run variance of about 7s.** `--plain`
measures 5m 48s, matching the last row exactly.

The 15s was a different fault wearing the display's clothes. `applyEntryPointers` reports per block, and
each report composes a string and touches the map under a lock — so the 4,203 redundant `..` edits
described below were also 4,204 display updates. Fixing the writes fixed the drawing with them. Two
lessons: an overhead that only appears in one mode is not necessarily *caused* by that mode, and a
15s figure measured across two builds is a difference between builds, not a difference between modes.

The 4s went with the event stream, which is the one thing the table above could not do for itself: it
suppressed each coupling to price it, and the rewrite removed all three. Nothing is composed and no
lock is taken on the engine's thread any more — a watched run measures **5m 48s** against 5m 50s and
5m 53s for the two redirected runs of the A/B, so drawing is no longer distinguishable from not
drawing. One run per mode, so treat it as "not slower" rather than as a figure; the point is that the
couplings the table was pricing no longer exist to be measured.

## Two kinds of colour, and the mistake is always the lifetime

The map draws contents in the foreground and activity in the background, so a cell can say what it
holds and what is being done to it at the same time. Between the two sit the *stages* — `collected`,
`written`, `repointed` — contents that exist only for the length of an operation. Every fault the map
has had since has been a stage with the wrong lifetime, and none of them was findable by reading the
code, because each did exactly what it said.

**A trail measured in frames is a claim about the medium.** `heatFrames` is 4, and at 8 Hz that is half
a second — calibrated when every operation finished well inside it. On a card with a slow region one
write runs past it, so the light goes out while the drive is still working and the map sits perfectly
still in the middle of the operation it exists to show. That is indistinguishable from a hang, and the
previous cell having already faded is what makes it look like the tool has stopped rather than slowed.
An operation in flight is now held lit until the medium answers, and the four frames are only the trail
behind a finished one. It costs nothing where it was already right: on a fast medium both edges land in
the same frame and the result is exactly what it was.

**One edge is not enough.** `Transfer` and `Barrier` carried `done`; `Work` did not, so a step of
bookkeeping said it had begun and nothing about when it stopped, and anything drawing had to infer the
end from the next step starting. That is wrong in both directions — a step shows as still running for
however long the gap turns out to be, and the gaps are real, because a gather served from the cache is
reported to nobody — while the last step of a pass has no successor to end it at all.

**A stage belongs to the operation that made it true, and ends at the event that ends the state.** The
repoint colour took three versions to get there, and each wrong one is a different way of getting a
lifetime wrong:

| Marked | Cleared | What happened |
| --- | --- | --- |
| gather completes | the instant the write returns | Never seen. A repoint pass on a warm cache is tens of milliseconds — under one frame — so the mark was put back before anything was drawn, and all that survived was the activity trail sitting over unchanged contents |
| gather completes | after a four-frame trail | Visible, and backwards. The gather reads a block and patches it *in memory*; the medium is untouched, so the colour claimed a change that had not happened |
| **write completes** | **when the pointers flush returns** | Correct. The write is where the block changes; the flush is where the change stops being provisional |

The last row makes `repointed` the exact sibling of `written`: written data is not the live copy until
the commit names it, and a flipped pointer is not real until the drive says it has it. It also draws
better than either wrong version, because the flush holds precisely the blocks that are marked, so they
sit under the pulse and resolve together when it answers.

**The legend names categories, not stages.** `collected`, `written` and `repointed` are each a lighter
member of the family of the activity that produces them, so the blue, yellow and purple squares on the
right name them already and the two ramps on the left teach the shading — listing them said the same
three things twice, in the row with the least space in the frame, crowding out the entries a reader
could not have worked out. Removing them took the full key from needing 160 columns to 120. The content
entries were also drawn unconditionally where the activity entries were droppable, which over-ran the
row by fifteen characters at the 60-column minimum this draws at: one character too many and the
terminal wraps, every later row lands one low, and the frame drifts without ever looking broken.

**Sampling frames will not find any of this.** A stage that lasts less than a frame appears in a handful
of frames out of hundreds, so `screenshot.py <n>` on a dozen guesses reports it as simply absent. Count
the drawn sequences in the capture instead — `data.count(b'\x1b[38;5;213m')` says whether it was ever
drawn at all, and walking the cursor-home boundaries says which frames it landed in. That is where
"drawn 223 times, in 21 of 584 frames, against 943 for the activity behind it" came from, and the
*ratio* is the diagnosis: a stage drawn far less often than its own activity is a stage being cleared
too early.

**And keep `screenshot.py`'s palette in step with `Palette`.** An unmapped colour draws as a space, so a
newly added state renders as empty volume — the measuring tool reporting a fault in the tool being
measured, which is the worst direction for a mistake to run. Its printed key had been missing `written`
since that state was added.

## The raw node, and nothing else

Every device run goes through `/dev/rdiskN`; a buffered path given on the command line is redirected
there. Measure against the raw node, restore against the raw node, and there is no second path to
hold in your head.

The reason is that a buffered run misreports itself. Writes are taken, acknowledged and deferred,
then charged to whichever flush comes next, so the work appears in the wrong place and at the wrong
time — which puts the access pattern, the one thing left worth tuning, out of sight. Buffered also
caps every device request at 16 KB whatever size it is handed, so transfer shapes chosen in the tool
never reach the medium at all.

It costs nothing to leave — it now pays. Standing in for the page cache took two changes: a read
sweep, patch and write sweep instead of read-modify-write per block, then holding the metadata blocks
between commits. That took repointing from 6m 39s to 1m 54s and the run from 13m 58s to 9m 17s, level
with buffered at the time. On the current build raw is ahead outright, **7m 35s against 7m 58s**, and
the phase table is the reason to care:

| Spinning drive, same volume and build | Raw | Buffered |
| --- | --- | --- |
| Copying | 4m 57s | 5m 21s |
| Barriers (100) | **4 ms** | 1m 3s |
| Repointing | 1m 38s | 1m 14s |
| FAT writes | 22.4s | 3.0s |
| **Total** | **7m 35s** | 7m 58s |

The barrier row is the whole argument. Buffered, it is a minute of writing presented at the flush;
raw, there is nothing to present, and that minute appears in the phases that actually incurred it.
Metadata still costs more here — repointing and FAT writes are 45s worse — and that is where a
buffered run was quietly getting help. It is visible now, which is the point.

### And what that means for Linux

Linux has no raw node. There is one node per disk, the page cache is under it, and the only way to
get out from behind it is `O_DIRECT` — which is not a flag but a contract: the buffer, the offset
and the length all have to be aligned to the logical block size, and `Data(count:)` is not
page-aligned, so it reaches into `rawRead`/`rawWrite`.

Whether that is worth doing was measured rather than argued, on this drive, by building Darwin with
Linux's two answers — `rawNode` the identity, and a block device counting as uncached so the
metadata cache stays on — and running it against `/dev/disk32`. That is Linux's exact configuration
on real hardware, which is the one thing a container cannot provide. Restore, run and capture all
went through the buffered node, never mixing the two, for the reason `ab-verify.py` gives.

| Spinning drive, same snapshot, same build, same day | Raw | Buffered, cache on |
| --- | --- | --- |
| Copying | 4m 16s (80%) | 5m 24s (73%) |
| Barriers (348) | **13 ms (0.0%)** | **47.1s (10%)** |
| Repointing | 39.7s (12%) | 1m 5s (14%) |
| FAT writes | **23.1s (7.2%)** | **2.1s (0.5%)** |
| **Total** | **5m 36s** | **7m 36s** |

Both produced byte-identical volumes, fsck clean, from identical plans — 31,768 transfers in 179
passes, 14,802 fused spans, 2,174 folded pointer fixes, on both sides. Nothing about the decision
changed; only how it reached the medium.

So the page cache is not a correctness problem, and `O_DIRECT` is not a safety requirement. It is an
honesty requirement, and the FAT row is the sharpest way to see it: 23.1s of writing became 2.1s.
That work did not get cheaper, it got hidden — absorbed by the cache and re-presented inside a
barrier that grew from 13ms to 47 seconds. A reader of the buffered report would conclude the FAT
writes cost two seconds. They cost twenty-three. This is the same failure the barrier row has always
described, except that here it is being proposed as a permanent arrangement for a whole platform.

Note that the buffered column above is *better* configured than the one in the table before it: that
one predates the metadata cache being keyed on the node rather than the path, so it ran without a
cache at all. This one has the cache helping and still loses two minutes.

One honest limit on the magnitudes. Buffered on Darwin also caps every device request at 16 KB, and
Linux does not, so the 36% is an upper bound and probably a loose one. What does not depend on that
cap is the displacement — work leaving the phase that incurred it and arriving at the flush — which
follows from having a page cache at all. Expect Linux to be faster than this column and to misreport
itself in the same shape.

## Proving two builds agree

    python3 ab-verify.py card.img /dev/rdisk22s1 ./fatrabbit-before ./fatrabbit-after

Restores the snapshot, checks the starting state really is the snapshot, runs each build, captures
what it left, and compares — bytes, file listings and fsck. About twenty minutes for a 1.5 GB
volume on a card, most of it restoring.

On a device rather than an image, which is the whole point. The one real corruption this project
has seen did not reproduce on an image: identical input, identical plan, identical transfer log for
the first fifteen thousand transfers, clean as a file and wrong on a card. An image A/B would have
passed it. If a change touches how bytes reach the medium, the medium has to be in the loop.

There is now a mechanism to go with that observation, and it is worse than "an image is faster": an
image *accepts requests a card refuses*, 2 MiB against 128 KiB, so an oversized transfer is legal on
one and silently wrong on the other. No amount of A/B-ing against an image can see that, because
neither side of the comparison provokes it. See the transfer-size section at the top.

Two builds are needed rather than one, because a build that is wrong the same way every time
verifies perfectly against itself. Pointed at the merged build and its replacement it reports:

    ./fatrabbit:            20294 files read back, fsck clean
    ./fatrabbit-copymerge:  20497 files read back, fsck COMPLAINS
    ./fatrabbit vs ./fatrabbit-copymerge: bytes DIFFER, files DIFFER
        87423488 ..  87457792   33 KB  cluster 5288
        ...

which is what took a day to establish by hand. Note that it also has to be run against the right
device node: the same pair agree byte for byte on `/dev/disk22s1` and disagree on `/dev/rdisk22s1`.
A detector that has never been shown to fail is not a detector, so check it against a build you know
is wrong before trusting it about one you hope is right.

## Watch what the device is asked for

Not what the tool asked for:

    iostat -d -w 2 -c 300 disk14        # while a run is going

On the raw node a request arrives at the size it was issued — 1024 KB reads stay 1024 KB. That is
the point of being here, and it is why transfer shape is worth thinking about at all.

The number that sizes the work left: during the copy phase the drive does 408 requests a second of
16 KB, which is 6.4 MB/s, against 20 MB/s for the same 16 KB requests issued sequentially. The
entire 3× is positioning between scattered requests, and it is worth about four minutes of a
nine-minute run.

## Count operations, not just seconds

Wall clock on the test spinner is a proxy, and a flattering one. It prices an adjacent transfer at
1.08 ms against 1.35 ms one cluster away — a per-command overhead so low that removing a third of the
commands moves the clock by 2%. That ratio is a fact about this drive, not about the hardware the tool
is for: a weak USB bridge, an old card reader, or any controller holding one command at a time
charges far more per command, and those are the same readers per-file contiguity exists to help.

So **the number of operations asked of the device is a first-class result**, reported alongside the
timings, and a change that reduces it is not retired because the clock barely moved. The standing
rule that a change earning nothing may not carry an unexplained association with lost data still
governs anything touching a mechanism with a corruption history — but "earning nothing" means neither
fewer operations nor less time, not merely little time.

## Where the copy phase's time goes, and why little of it is recoverable

A dry run reads every source and writes nothing, which splits the copy phase without any instrumentation:

| | Time | Rate | Against sequential (36 MiB/s) |
| --- | --- | --- | --- |
| Reads (1,330 MiB) | **2m 22s** | 9.4 MiB/s | **26%** |
| Writes (by difference) | ~1m 42s | 13.0 MiB/s | 36% |
| Copy phase | 4m 4s | | |

Writes run close to sequential because the destinations are packed contiguously — that is the layout this
tool creates, working in its own favour. Reads gather from wherever the old layout left things, so the
read side carries roughly 105s of pure positioning, about 30% of the whole run and the largest single
number left in it.

It resists the obvious attack. The data in the gaps between sources is not waste — it belongs to objects
that will move in a later generation — so reading through a gap fetches something genuinely wanted. What
kills it is *when*:

| Gap size | Gaps | Gap clusters | Wanted later | Median wait |
| --- | --- | --- | --- | --- |
| 1–2 clusters | 4,577 | 6,526 | 3% | 4 generations |
| 5–8 clusters | 2,435 | 15,224 | 40% | 4 generations |
| 9–32 clusters | 5,573 | 100,853 | ~54% | 4 generations |
| 33+ clusters | 7,977 | 3,190,016 | **10%** | 4 generations |

Reading through every gap of 32 clusters or fewer adds about 130,935 cluster-reads — 2.0 GiB, some 57s
at sequential rate — to save some 15,215 seeks worth about 21s. A net loss of 36s, before considering
that the surplus would have to be held for a median of four generations, far beyond the cache. Nearly
all the gap volume is in the 33+ bucket, where only a tenth is ever wanted at all.

That is the third independent method to reach the same answer: `gap-cost.py` measured it on the drive,
`span-gaps.py` modelled it from a plan, and this counts what the surplus would actually be used for. The
read side's scatter is a property of the volume as found, not of anything the run decides.

## Fusing adjacent transfers is nearly free

`span-gaps.py` reports that half a run's transfers begin exactly where another ends — 51% of writes
and 36% of reads, at zero extra bytes. Fusing the ones adjacent on *both* sides, which is the only
form with no gather and no mask in it (see `CopyBatch.fuseAdjacent`), delivers what it promises:

| Spinning drive, raw | Unfused | Fused |
| --- | --- | --- |
| Transfers | 44,405 | **28,978 (−35%)** |
| Copying | 4m 57s | **4m 46s** |
| **Total** | 7m 35s | **7m 25s** |

**A third of the commands gone, for no extra bytes read.** The clock moves 2% here for the reason
above, and because `inPlaceOrder` had already taken the seeks out: consecutive transfers were mostly
adjacent *before* fusing, so what remains to recover is per-command overhead on a drive that hardly
charges any.

An earlier expectation of 25% came from a gap-*merging* build measured before that layout change, and
did not survive it. Worth remembering when reading any pre-`inPlaceOrder` figure about transfer shape:
the seek it was recovering is already gone, so those numbers now overstate their case.

Verified byte-identical to the unfused build across a whole device, fsck clean, all 42,000 files
matching — which is more than the removed gap-merging version ever had. `ab-verify.py` runs against
any change to this code, on the grounds that it is the one mechanism here with a corruption history.

Laying siblings out in the order they physically sit — see `DefragPlanner.inPlaceOrder` — collects
some of that. Median distance between transfers falls from 224 KB to 48 KB, and with it:

| | Spinning drive | Card |
| --- | --- | --- |
| Copying | 6m 11s → **5m 19s** | 2m 36s → **2m 23s** |
| Barriers | 1m 23s → **1m 3s** | 47.1s → **36.5s** |
| Parked in spare space | 425 → **15** | 619 → 628 |
| Total | 9m 12s → **8m 2s** | 3m 27s → **3m 4s** |

The barrier column is the surprise, and it is not a rounding effect. The explanation first recorded
here — fewer objects waiting on somewhere to be vacated, therefore fewer generations to put barriers
between — is wrong, and "Barriers are priced per byte" below has the measurement that disproves it:
fifty barriers cost a second between them. What actually fell is the write-back, because laying an
object where it already sits makes the dirty pages contiguous, and a contiguous write-back is
cheaper than a scattered one carrying the same bytes.

## The scan's seeks are already optimal, and the devices serialise

The scan is the one phase never touched — 20.0s of a 9-minute run on the spinning drive, 3.5% of
it — and the obvious guess is that a depth-first tree walk reads directory clusters in whatever
scattered order the tree happens to hold. Measured, by logging every directory read in order, that
guess is wrong: **2,120 reads with zero backward jumps**, ascending, a median of 43 clusters
(0.7 MiB) apart. There is nothing to reorder. A breadth-first walk sorted within each level
produces the identical sequence.

What the phase actually costs is 2,120 separate 16 KiB requests at 9.42 ms each, which is a
rotation apiece and accounts for the 20.0s exactly. That leaves two levers, and both are dead:

**Concurrency buys nothing, on either medium.** The scan is the best case for it — 2,102 of the
2,120 addresses are known at once, straight out of the root — so if anything were going to gain,
this would. `queue-depth.py` against the same access pattern:

| Queue depth | 1 | 2 | 4 | 8 | 16 | 32 |
| --- | --- | --- | --- | --- | --- | --- |
| Spinning drive | 19.97s | 19.98s | 19.98s | 19.98s | 19.98s | 19.98s |
| SD card | 2.72s | 2.69s | 2.70s | 2.71s | 2.72s | 2.71s |

Flat to the hundredth of a second across a 32-fold range. Both are USB mass-storage devices
speaking BOT, which carries one command at a time, so every request waits for the last one
whatever the caller does. This is the general answer, not a fact about the scan: no part of this
tool can gain from issuing I/O concurrently on either medium.

**Coalescing measures slower.** Merging reads within a gap threshold, actually run rather than
modelled:

| Gap merged (clusters) | Requests | Bytes read | Elapsed |
| --- | --- | --- | --- |
| 0 (as it stands) | 2,104 | 33 MiB | **20.1s** |
| 32 | 1,495 | 313 MiB | 22.6s |
| 64 or more | 4 | 1,328 MiB | 34.4s |

A model using the medium's *sequential* rate says merging saves 6s; the medium delivers 39 MB/s
across that span, not the 100 assumed, and it loses 14s instead. Read the "Baseline the medium
first" table before predicting anything, and then measure it anyway.

It fails the operation-count test too, which is worth recording because that test was expected to
save it — 2,104 reads falling to 162 sounds exactly like the kind of trade "Count operations, not just
seconds" is meant to license:

| Merge gaps ≤ | Reads | Bytes read | Amplification | Spinner | Card (est.) |
| --- | --- | --- | --- | --- | --- |
| 0 (today) | 2,104 | 33 MiB | 1× | **20.2s** | **17.0s** |
| 24 clusters | 2,099 | 35 MiB | 1× | 20.0s | 17.1s |
| 32 clusters | 1,504 | 308 MiB | 9× | 22.5s | 27.3s |
| 64 clusters | 162 | 1,227 MiB | **37×** | 32.1s | 66.5s |

There is no threshold in between: the gaps are almost all about 43 clusters, so nothing merges below
32 and everything merges above 48. **13× fewer operations for 37× the bytes** is the only offer, and a
weak controller that charges heavily per command charges per byte as well — the card estimate is four
times worse. Operation count is a result, not a licence to move bytes for free.

The amplification is structural, but only given the layout: each directory is followed by its own
files, which makes directory clusters one-in-forty-four and evenly spread. That spacing is something
this tool *creates*, so the interesting question is not how to read a sparse set of clusters cheaply
but why they are sparse — see "Grouping directory clusters" below. Coalescing is the wrong lever;
the reading is only expensive because of where the writing put things.

So the *ordering* of the phase stays as it is. Worth recording because all three ideas are the ones
anybody would have next, and each looks good until it is measured.

What none of them asked is how many of the bytes in a read are wanted, and the answer turned out to
be 6.6% — see "The scan read sixteen times what it used" below. This section's conclusion held for
one volume and one question; "the scan is optimal" was the wrong thing to take from it.

## The scan read sixteen times what it used

The section above priced the scan's seeks three ways and found nothing. It never asked what was in
the transfers. A directory's entries are packed from the front and closed by an entry whose first
byte is 0x00 — the parser has always stopped there — so everything past that byte was fetched and
thrown away. `dir-density.py` on a 32 GB card, 273,035 files in 41,651 directories:

| | |
| --- | --- |
| Directory clusters read | 42,354 (98.3% of directories are a single cluster) |
| Bytes read | 662 MiB |
| Live entry bytes | **43.9 MiB — 6.6%** |

At 6.6 files per directory, a directory fills some 700 bytes of its 16 KiB cluster.

Whether that waste is worth anything is a question for the medium, not for arithmetic, and the
answer is the shape of the cost curve. Replaying the scan's own offsets in its own order:

| Read size | 16 KiB | 8 KiB | 4 KiB | 2 KiB | 1 KiB | 512 B | 16 KiB again |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Per read | 1.868 ms | 1.401 ms | 0.973 ms | 0.952 ms | 0.953 ms | 0.951 ms | 1.872 ms |

Cost is flat at ~0.95 ms below 4 KiB — the per-command floor — and the extra 12 KiB a full cluster
carries costs 0.92 ms, which is 17.8 MB/s: the card's sequential rate, straight off
`medium-baseline.py`. Those bytes were simply being paid for at list price. The repeated 16 KiB trial
lands within 0.004 ms of the first, so this is the curve and not a warm cache.

So the scan reads `min(4096, clusterSize)` and fetches the rest only when no terminator appears in
it. 4 KiB rather than less because it is the largest read the floor still covers, which makes its
coverage free: it finishes 96.6% of directories against 91.6% at 2 KiB.

| Dry run, 32 GB card | Before | After |
| --- | --- | --- |
| Scan | 1m 17s | **42.4s** |
| Whole run | 1m 18s | **43.2s** |
| Metadata reads | 42,361 | 43,762 |
| Cache peak | 661.8 MiB | **190.1 MiB** |

**1.82×**, for 1,401 extra reads — the 3.4% of directories that outgrow the probe. On this volume the
scan *is* the run, so it is 1.82× on the whole thing.

The cache figure is the second win and arguably the more important one. The ceiling is 1 GiB and the
note on `cacheLimit` guessed this volume would want "some 800 MiB"; it wanted 661.8 MiB, and once
admission is declined nothing is evicted, so the run goes cold for the rest of its length with
nothing saying so. 190.1 MiB puts that cliff out of reach rather than just beyond the horizon.

This is the mirror image of the coalescing result above, and both follow from one fact: on these
controllers bytes are expensive next to commands. Coalescing offered more bytes for fewer commands
and lost 14s. This takes fewer bytes for the same commands and wins 35s. The lever was never
"operations versus seconds" — it was that the bytes had a price nobody had checked.

It is a card win specifically, and the spinning drive is where that gets tested rather than
asserted. The same curve there is flat to within 1%:

| Read size | 16 KiB | 8 KiB | 4 KiB | 2 KiB | 1 KiB | 512 B |
| --- | --- | --- | --- | --- | --- | --- |
| Per read | 8.203 ms | 8.179 ms | 8.157 ms | 8.151 ms | 8.162 ms | 8.112 ms |

A read is a rotation and the payload is lost inside it, so there is nothing to take: 16 KiB costs
1.1% more than 512 B, and the scan measures **17.2s before against 17.1s after** across two runs
each — 33 MiB of reads falling to 8 MiB and the cache peak to 8.6 MiB from 33.2 MiB, for no time at
all. Recorded because the first draft of this section estimated 3% from the rotation figure and the
drive says 1%: the estimate was the right shape and still not worth keeping once the drive could be
asked. Nothing regresses, which is the part that mattered.

Verified with `ab-verify.py` on an image-backed device rather than an argument about prefixes:
byte-identical and fsck clean against the previous build on a volume of 10,455 moves across 282
generations with 1,113 staged, including a 3,000-file directory whose entries need eighteen clusters
— so the probe misses, the remainder is fetched, and long-name runs straddle every boundary — and
again under `--deMac`, which reaches `directoryBytes` by a second path.

Then on the spinning drive, because "the medium has to be in the loop" is this file's own rule and an
image A/B has already missed a real corruption once: 42,000 files over 2,101 directories, restored
from a snapshot for each build, **byte-identical and fsck clean**, 358s against 360s for the whole
run. Two seconds is the noise on this drive — the same margin the event-stream A/B saw — so read it
as "not slower", which for a change that only reads less is the whole claim.

Stopping early is only safe because the stop condition is the terminator: finding it means the
entries genuinely end inside what was read, so no entry and no long-name run is ever cut in half.

## The staging allowance scaled with the wrong number

`spareBudget` was a fraction of the *free* room, which has nothing to do with how much needs parking to
break a deadlock. On a volume with space to spare that granted an enormous allowance, so the schedule
parked objects that would have reached their homes unaided a generation or two later — visible on the
map as a band of data moved to the end of the volume and gradually fetched back, which is what it is.

Capped at 256 clusters per stall:

| Card-shaped volume, 44% full | Before | After |
| --- | --- | --- |
| Objects staged | 628 | **60** |
| Written then read back | 25 MiB | **4 MiB** |
| Objects moved | 22,065 | **21,497** |
| Clusters moved | 44,963 | **43,634** |
| Generations | 38 | 78 |

43,634 against 43,378 actually in use — within one budget of the floor. The 65%-full volume is
unchanged, having little spare room to be over-generous with, and an already-defragmented one still
moves nothing.

Smaller is not better: at 64 the schedule cannot clear a knot in one pass and re-parks objects it has
already moved, ending with 219 staged rather than 60. The cost is generations, 38 becoming 78, which
used to be the argument against and is now close to free — a barrier is 0.02s buffered and
unmeasurable raw, so fifty more are worth about a second.

Verified on both shapes: FAT region, used data region and boot record all byte-identical to the
uncapped build, every file identical, fsck clean. The same layout by less work.

**On hardware it buys no time at all**, which is worth recording plainly. The card-shaped volume written
to the spinning drive, so that staging means real seeks:

| | Uncapped | Capped |
| --- | --- | --- |
| Transfers | 16,314 | **15,650** |
| Read/write passes | 42 | 82 |
| Copying | 2m 8s | 2m 8s |
| Repointing | 32.1s | 31.2s |
| FAT writes | 10.7s | 11.6s |
| **Total** | **2m 59s** | **3m 0s** |

Copying is identical to the second despite moving 3% less data, because that phase is positioning-bound
rather than volume-bound; and the 40 extra generations add 80 FAT sweeps, which hands back the 0.9s
repointing gives up. `ab-verify.py` says 181s against 180s.

Kept anyway, on the grounds already established: 664 fewer transfers and 1,329 fewer cluster writes for
no cost. On flash those writes are wear rather than time, which is the medium this tool exists for. It
also removes the band of data that appeared parked at the end of the map, which is how the whole thing
was noticed. One caveat for the future: 80 more barriers is free only because a barrier on a raw node is
unmeasurable — on a medium where committing is expensive, this trade inverts.

## The staging tail

The current run parks 1,033 objects and copies 6.3% more clusters than the volume holds, against 15 on
the same recipe before the driver change. That looks like the largest remaining inefficiency and it is
not attackable — five ways of attacking it were scored and every one is worse. Recorded so the next
person spends ten minutes reading rather than a day measuring.

It is also half the cost it appears to be. Parking a cluster means writing it twice but reading it once:
the fetch-back is served from memory, measured at 85.8 MiB on this volume and not one byte of it from the
drive — see "The cache was working, and only two thirds working". So the 6.3% is 6.3% of extra *writes*,
which on flash is wear and on a spindle is a write-back that is largely sequential, and no extra reads at
all. That does not make it free, but it halves what the figure looks like it is saying.

**First, what it actually is.** Two things that look obvious from the per-generation lines are wrong:

- **Nothing is re-staged.** Four generations moving one object of 615 clusters reads like one object
  hitting `maxStagesPerObject` and being re-parked. Counted directly: zero objects are parked twice.
  Staging destinations are clusters no object's home covers, so a parked object is never in anybody's
  way. (This section was written when that was secured by taking staging from the top of the volume
  downwards while homes filled from the bottom. It is now tested directly against `homeOwnerAt` —
  see "The staging region belongs next to the layout, not at the far end" — which is the same
  guarantee and does not disturb any figure here.)
- **It is not a long grinding tail.** On a reproduction with 686 generations, **14 of them stall**; the
  other 672 place objects with no staging at all. Each stall parks about 140 small objects.

And then the figure that explains the whole thing: 14 stalls × the 256-cluster cap = 3,584, which is
*exactly* the extra clusters copied. Staging is entirely budget-limited. The loop stages every blocker
that fits until the allowance runs out, and never asks whether the knot is already broken — so the
amount parked is `cap × stalls` and has nothing to do with what was needed.

**A generation is not free, and the barrier row is why that is easy to get wrong.** "Barriers are priced
per byte, not per call" is about barriers, and reads as though it is about generations. From the current
figures, per generation:

| | |
| --- | --- |
| barrier pair | **0.06 ms** |
| FAT sweep | 117 ms |
| repointing | 393 ms |
| **a commit** | **510 ms** |

So 686 generations is about six minutes of commits. Anything that reduces staging by adding generations
is paying 510ms to save a few clusters.

**Five candidates, scored with `plan-score.py` against the same volume.** Extra clusters is
`moved − in use`; predicted is the copy phase only, and prices no commits at all, which is the trap:

| Candidate | Gens | Staged | Extra cl | Transfers | Predicted | Commits at 510ms |
| --- | --- | --- | --- | --- | --- | --- |
| **as it stands (cap 256)** | **686** | 1,967 | 3,584 | **27,025** | **202s** | **5.8 min** |
| cap 128 | 1,135 | 1,895 | 3,456 | 27,397 | 208s | 9.6 min |
| cap 64 | 1,824 | 1,819 | 3,328 | 27,666 | 212s | 15.5 min |
| smallest blockers first | 706 | 2,856 | 2,913 | 29,447 | 264s | 6.0 min |
| one knot per stall | 10,553 | 1,660 | 3,046 | 29,591 | 179s | **90 min** |

"One knot per stall" is the one worth understanding, because on the copy-phase model it is the *best* of
them — 179s against 202s, and the fewest staged hops. It gathers the blockers of a single waiting object
instead of all of them, which is precisely the "stop when the knot is broken" fix the budget analysis
above argues for. It also multiplies generations fifteenfold, and at 510ms a commit that is an hour and a
half. A scorer that models only the copy phase will recommend it.

**And there is no wear win either**, which is the argument that closes the cap off completely. Lowering
the cap writes fewer data clusters and more FAT blocks, at almost exactly one for one — FAT blocks are
512 bytes, so 32 to a 16 KiB cluster:

| | Extra data clusters | FAT blocks | Cluster-equivalents written |
| --- | --- | --- | --- |
| cap 256 | 3,584 | 43,228 | **4,935** |
| cap 128 | 3,456 | 47,026 | 4,926 |
| cap 64 | 3,328 | 51,236 | 4,929 |

Nine cluster-equivalents across a fourfold change in the cap. On flash, where this would have been the
strongest case for a smaller allowance, there is nothing there.

Only `smallest blockers first` breaks that pattern — 2,913 data clusters and 54,414 FAT blocks is 4,613
equivalents, some 6% less written. It costs 9% more operations and 31% more predicted copy time, so it
is a genuine bytes-against-operations trade rather than a win, and this file's standing rule is that
operation count is a result in its own right. Left alone on those grounds, not because it measured badly.

**Reproducing this.** The pathology needs the real volume shape, and an image gets it: 2 GiB at 16 KiB
clusters with `newfs_msdos -F 32 -c 32 -s 4194304`, then `make-test-volume.py <mount> small 7`, gives
131,007 clusters and the same fskit layout behaviour — 686 generations and 1,967 staged hops, the same
pathology amplified. `hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage` hands back
user-owned nodes, so none of this needs `sudo` or the drive. A dry run plus `plan-score.py` ranks a
candidate in about two minutes.

## The staging region belongs next to the layout, not at the far end

Staging destinations used to be taken from the top of the volume downwards, and the reason given was
the one in "The staging tail" above: homes fill from the bottom, so a parked object is never in
anybody's way. That is the right property secured the wrong way round. `homeOwnerAt` — which the
planner already builds so that releasing a cluster wakes exactly the object waiting on it — states it
exactly: a cluster no home covers can never be wanted by anybody. Test that directly and the guarantee
holds at *any* distance, so the whole free region above the layout is available at whichever end of it
we like. Both searches now start at the lowest such cluster and ascend.

**What prompted it.** A run captured mid-flight on a 31.2 GiB card, FAT32, 16 KiB clusters — some 2.04M
clusters, about 58% full. The layout frontier sat near cluster 1.19M and staging was going to 2.04M:
**850,000 clusters, 13 GiB, out and back on every stall**, with the *Clearing* band at the far corner of
the map being that region given up again. On a spindle that is a full stroke each way.

Two figures elsewhere in this file need qualifying at that scale. "The fetch-back is served from memory
— 85.8 MiB, not one byte of it from the drive" was measured on a 2 GiB volume; a 31 GiB volume's staged
set will not fit the cache, so the read-back is a real read from the far end and the change saves a
stroke each way rather than only on the write. And **`plan-score.py` cannot see this change at all**: it
sums gaps within each generation in source order and destination order and restarts at `cost_of(0)` at
every generation boundary, which is precisely where the stroke lives. Its verdict here is "no
regression", not "no win".

**Measured on the image reproduction** — 2 GiB, `newfs_msdos -F 32 -c 32 -s 4194304`, then
`make-test-volume.py <mount> small 7`: 131,007 clusters, 42,047 files, 85,105 clusters in use.

| | before | after |
| --- | --- | --- |
| Moves / clusters | 44,164 / 85,105 | **44,164 / 85,105** |
| Generations / staged hops | 45 / 13 | **45 / 13** |
| Transfers | 26,088 | 26,085 |
| Predicted copy cost | 208s | 208s |
| Staged destinations | 130,980…131,008 | **85,107…85,135** |
| Mean staged distance | 85,128 clusters | **39,253 (−54%)** |
| Furthest staged hop | 131,002 clusters | **85,107** |

The first two rows are the ones that had to come out identical, and they are the test that the
invariant is right rather than merely different: holding the layout fixed, nothing about which object
goes where has changed, only which scratch cluster a stall borrows. The three transfers are noise, as
in the cap sweep above. The residual 39,253 is the *sources* being spread through the used region —
what moved is the destination, from the last cluster to the first one past the layout, worth 45,901
clusters or 717 MiB of travel per hop on a volume this size.

`ab-verify.py`, both builds over restores of the same snapshot: **42,000 files read back identical,
`fsck_msdos` clean on both, and 18 byte ranges differing out of 2 GiB — every one of them inside a
staging region**, clusters 85,107…85,135 and 130,980…131,008. The highest cluster in use is 85,106, so
all eighteen are free, which is the only place two schedules are permitted to disagree. Nothing is
reported as metadata, so the boot record and both FAT copies are identical. `contiguity.py`: 44,100
objects, 0 fragmented, free space in 1 run.

That last row is the half of this worth more than the seeks, and it is the salvage pass rather than
staging. `freeRun` decides where a *stranded* object lives, not where it waits, and taken from the top
it left permanent data at the far end of the volume — which guarantees the free space is not one run,
and that is half of what the tool claims. From the floor it extends the compacted region instead.

**SPINTEST cannot show the seek win and should not be expected to.** A 2 GiB volume on a 320 GB drive
spans a fraction of a stroke, and USB 2.0 flattens the zone-rate difference besides; the whole effect
is the frontier-to-end distance, which is 45,901 clusters there and 850,000 on the card that prompted
it. The change is adopted on having been proved free and better-placed, not on a stopwatch. Run it
there as a regression gate and expect the phase table not to move.

### Two harness traps found doing this

- **A dry run stops on a volume with directories to relocate.** `-n --plain --verbose` exits 1 with a
  corruption error from `repairDotEntries`: the run writes nothing, so the destination genuinely holds
  no directory, and the hardening described under "The transfer size has to come from the device" duly
  refuses to write a `.` entry into it. Pre-existing and reproduced on `head`, and it lands *after* every
  line `plan-score.py` needs, so scoring is unaffected — but the recipe at the top of that script now
  exits non-zero, and anything checking exit status will read it as a failed capture.
- **Never copy an image file while it is attached.** `cp` of this 2 GiB image ran at 0.8 MB/s through
  the disk-image framework and was still going eleven minutes later, having written 518 MB. Detached,
  `dd bs=4m` finished in 1.5 seconds at 1.4 GB/s — 1,700 times faster. Snapshot before attaching, or
  detach first.

## One generation can hold nearly all the work, and splitting it is free

Reported from a heavy defrag on real hardware: **generation 1 was about 70,000 moves and generation 2
about 3,000**, and the first one took roughly half the run. Nothing was wrong — a generation holding
nearly all the work ought to take nearly all the time — but nothing commits until it ends, so half the
run was a map full of blue and yellow with none of it settling, and no way to tell progress from a hang.

The cause is structural rather than pathological. The compacted layout packs from cluster 2 upwards,
and the first generation takes every object whose home is already clear, so a volume whose free space
sits *below* its data has almost every home clear before anything moves. That is an ordinary state for
a card that has had a lot deleted from it.

**`small` cannot show this and will report no difference for anything to do with it.** It peels gently
— 12% in the first generation and a long taper — because it is 65% full with data spread everywhere,
so most homes are blocked. The `hollow` profile exists for this and nothing else: fill to the brim,
then empty the low 60% of directories, keeping every tenth as a blocker so there is still a tail. It
gives 33,566 of 37,340 moves in generation one and 3,351 in the next, which is the reported shape.

Splitting a generation is free of the thing that would make it expensive. Every destination in one was
free before it began and exactly one object claims each, so holding an object back moves it later to
exactly the same place — the same objects, the same destinations, the same count, nothing copied twice
and nothing staged that was not staged before. Confirmed in every row below: moves, clusters and staged
hops are identical across the whole sweep.

What a split adds is a commit, and the surprise is that on the shape it is aimed at it *removes* work:

| `hollow`, cap in clusters | Gens | Transfers | FAT writes | FAT blocks | Entry blocks |
| --- | --- | --- | --- | --- | --- |
| uncapped | 8 | 3,112 | 1,100 | 2,758 | 3,322 |
| 16384 | 9 | 2,974 | 764 | 2,346 | 3,140 |
| 8192 | 12 | 2,930 | 672 | 2,228 | 3,084 |
| **4096 (chosen)** | **18** | **2,901** | **626 (−43%)** | **2,172 (−21%)** | **3,060** |
| 2048 | 30 | 2,879 | 594 | 2,130 | 3,044 |
| 1024 | 54 | 2,890 | 654 | 2,186 | 3,072 |

Homes are assigned walking up the volume in object order and a generation is built in that same order,
so truncating one yields chunks contiguous in destination order — and the layout puts a directory
immediately before its own files, so two chunks rarely share a parent directory block. A single
enormous generation instead accumulates allocations across the whole low region and releases across the
whole high one, and writes both as one sprawling pair of sweeps. Note also that 4,096 clusters at 16 KiB
is 64 MiB, which is exactly `SafeDefragmenter.maxCopySpan`: at that cap a generation is at most one
read/write pass, which is why passes fall to 18 there and rise again either side.

Below about 2,048 it turns over and starts costing again, so there is a floor rather than a monotone win.

**And the cost lands on volumes that did not have the problem**, which is the row that decides the value:

| `small 7`, cap in clusters | Gens | Transfers | FAT writes | FAT blocks | Entry blocks |
| --- | --- | --- | --- | --- | --- |
| uncapped | 45 | 29,833 | 8,204 | 27,936 | 17,675 |
| 16384 | 45 | 29,833 | 8,204 | 27,936 | 17,675 |
| 8192 | 45 | 29,838 | 8,360 | 28,044 | 17,690 |
| **4096 (chosen)** | **52** | **29,836** | **8,704 (+6.1%)** | **28,300 (+1.3%)** | **17,725** |
| 2048 | 69 | 29,845 | 9,164 | 28,530 | 17,756 |

Nothing here exceeds 16,384 clusters, so that cap is free and also does nothing. 4,096 buys the
feedback at 6.1% more FAT writes — and FAT writes are 6.6% of a run in the phase table above, so that
is 1.4 seconds of 337, or **0.4% of a run**. Transfers move by three, which is noise. That is the whole
price, and it is paid to turn one commit at the halfway mark into a commit every 64 MiB.

Verified by running the uncapped and capped builds over clones of the same image: **the boot record,
both FAT copies and every allocated cluster are byte-identical**, all 35,881 files read back identically
with `fatread.py`, and `fsck_msdos` is clean on both with the same free count. 104 clusters differ and
every one of them is free — stale bytes left behind in space nothing references, which is where the two
schedules are allowed to disagree.

One caveat for the future, and it is the same one the staging cap carries: extra generations are cheap
because a barrier on a raw node is unmeasurable. On a medium where committing is expensive this trade
inverts, and the arithmetic to redo is generations × per-call flush cost from `flush-cost.py`.

### On the drive, where it costs 0.6% and earns 5%

Both shapes were then run on the spinner, which changed one conclusion and confirmed the rest. Note
first that **the drive schedules neither volume the way the image does** — `small 7` gives 168
generations and 1,033 staged hops here against 45 and 7 on the image, and `hollow` gives 35 against 8.
That is "The filesystem driver writes the test volume" again. The operation-count *ratios* travelled;
the absolute schedules did not, so the image sweep ranks candidates and does not describe this drive.

`small 7`, where only 7 of 168 generations exceed the cap and the largest is 8,576 clusters — close to
a pure worst case, all of the cost and none of the payoff:

| Spinner, raw | head | capped | |
| --- | --- | --- | --- |
| Copying | 4m 19s | 4m 16s | −3s |
| Barriers | 336 — 10ms | 348 — 11ms | +1ms |
| Repointing | 39.9s | 40.5s | +0.6s |
| FAT writes | 20.6s | **24.9s** | **+4.3s** |
| **Total** | **5m 37s** | **5m 39s** | +2s |
| FAT writes / blocks | 10,288 / 28,930 | 10,984 / 29,290 | +6.8% / +1.2% |
| Generations | 168 | 174 | +6 |

The FAT row is the part to believe, because the image predicted it independently at +6.1% and the drive
delivered +6.8%. **The +2s total is not a measurement.** Across five runs over the same snapshot, head
measured 342s and 337s, and capped measured 353s, 339s and 336s — the spread inside each condition is
wider than the gap between them, and the fastest run of the whole set is a capped one. The honest
reading is a 4.3s cost in one phase, 0.6% of a run at the outside, and nothing distinguishable in the
total.

That last 336s is also a *watched* run, with `--deMac`, which retires a question the display work
raised. Holding a light for the length of an operation means `begin` and `settle` on every transfer
rather than one mark, and the repoint colour keeps a dictionary of what it has covered — per-event work
on the drawing side, added to a path the event stream had already been tuned for. A watched run at 336s
against redirected runs at 337s and 339s says it costs nothing measurable, which is the same answer
"An event stream costs nothing on a device" got, re-checked after adding to it.

`hollow`, where it engages properly — and here it is *faster*, which the copy-phase model could not
have told you because the saving is entirely in the two metadata phases:

| Spinner, raw | head | capped | |
| --- | --- | --- | --- |
| Copying | 56.1s | 55.9s | −0.2s |
| Barriers | 70 — 1ms | 90 — 3ms | +2ms |
| Repointing | 6.1s | **3.1s** | **−49%** |
| FAT writes | 3.1s | **1.8s** | **−42%** |
| **Total** | **1m 17s** | **1m 13s** | **−4s (−5.2%)** |
| Transfers | 3,776 | 3,529 | −6.5% |
| FAT writes / blocks | 1,634 / 3,448 | 1,212 / 2,872 | −26% / −17% |
| Generations | 35 | 45 | +10 |

**Repointing halving is the result worth understanding**, and it was not predicted. Uncapped, one
generation hands `applyEntryPointers` 37,526 edits at once, spread over every directory block on the
volume, so both sweeps scan the whole volume and `windows` holds all of it in memory at the same time.
Split, each chunk's edits are localised — chunks are contiguous in destination order and a directory
sits immediately before its own files — so each sweep covers a small region. That is a locality win,
not a count win: blocks written fell only 8%, and the time fell by half.

Verified on the device with `ab-verify.py`, three builds so that two questions stay separate:

- **head vs the working tree with the cap lifted: bytes identical, files identical.** The event and
  display changes — `Work.done`, the `PassProgress` restructuring, the extra report calls inside
  `applyEntryPointers` — alter not one byte reaching the medium, and cost nothing measurable (338s
  against 342s).
- **head vs capped: one 512-byte range differs in 2 GiB**, at cluster 104,283, which is free — the
  highest allocated cluster is 87,196. Boot record and both FAT copies identical, all 42,000 files
  identical, fsck clean. On `hollow` the same comparison gives 104 differing clusters, none allocated.
  Stale bytes in unreferenced space is the only place two schedules are permitted to disagree.

## Read the generation lines, not just the phase table

The phase table said repointing was 1m 24s and left it there. The per-generation lines, which only a
watched or `--verbose` run shows, said something the table could not:

    Generation 48/50:  4 moves,  8 clusters —  41ms (3.1 MiB/s)
    Generation 49/50: 15 moves, 36 clusters — 8.7s (0.1 MiB/s)
    Generation 50/50: 26 moves, 55 clusters — 8.2s (0.1 MiB/s)

**16.8s for 91 clusters** — 4.5% of the run for 0.1% of the data, at a fortieth of the throughput of
every other generation. Attributing it took two rounds of instrumentation, and each round killed the
obvious answer:

| Suspect | Measurement | Answer |
| --- | --- | --- |
| Forced commits from cluster reuse | the note that fires when it happens | No — it never printed |
| Copying, allocation, barriers? | per-generation split of every phase | No — copy 179ms, alloc 2ms, barrier 0ms |
| Repointing, then | same split | **Yes — 8.4s and 8.1s** |
| Uncached reads in the sweep? | hits and misses inside `applyEntryPointers` | No — 2,063 of 2,102 cached |
| So what is it | edits and runs per call | **2,116 edits from 15 moves, 7.7s of writes** |

Fifteen moves produced 2,116 pointer edits across 2,102 blocks spread over the whole 1.3 GB. The
culprit was in the log: `root: 2,5,546,+2 more → 131004…131008 (staged)`. When a directory moves,
every subdirectory child's `..` entry must be rewritten — and on this volume all 2,102 directories sit
under the root, which the schedule parks in spare space and then fetches home, so it happens twice.

**And every one of those writes was redundant.** A `..` naming the root is stored as 0 by convention,
so when the root moves there is nothing to change. The code said so in a comment and then queued an
edit per child anyway, writing 0 over 0:

    let value: UInt32 = object.isRoot ? 0 : newStart
    for child in object.children where child.isDirectory { edits.append((offset, value)) }

Skipping the loop for the root:

| Spinner, raw | Before | After |
| --- | --- | --- |
| Generation 49 | 8.3s | **242ms** |
| Generation 50 | 7.9s | **118ms** |
| Repointing | 1m 24s | **1m 4s** |
| **Total** | **6m 14s** | **5m 48s** |

Two lessons, and the second is the general one. A comment describing an optimisation is not evidence
the optimisation is there. And the phase table aggregates across fifty generations, so a phase that is
cheap forty-eight times and pathological twice reads as uniformly mediocre — the per-generation lines
are where that shows, which makes the watched display a diagnostic tool and not only a pleasure.

## FileHandle is NSFileHandle wearing a Swift signature

`FileHandle.read(upToCount:)` reads like modern Swift and is not. The backtrace that found the memory
problem below says what it really is:

    FATVolume.rawRead | NSFileHandle.read(upToCount:)
      | -[NSConcreteFileHandle readDataUpToLength:error:]
      | -[NSConcreteFileHandle readDataOfLength:] | _malloc

Replacing it with `pread`/`pwrite` on the descriptor was expected to buy nothing — at 1% CPU this tool
is nowhere near syscall-bound — and it took **9% off the run**:

| Spinner, raw | FileHandle | POSIX |
| --- | --- | --- |
| Copying | 4m 44s | **4m 8s** |
| Repointing | 1m 25s | 1m 23s |
| FAT writes | 25.7s | 23.1s |
| **Total** | **6m 52s** | **6m 12s** |

All of it in the copy phase, which is where the gigabyte of reads is, and the syscall count was the
least of it. `FileHandle` allocated a fresh `NSData` per transfer and the bytes were then copied into
the buffer being assembled — about 29,000 allocations and 1.3 GB of `memcpy` that `pread` does not
need, because it fills storage we already own. Three other things came with it: no object to
autorelease, so the class of bug below cannot recur; one call where a seek and a read were two; and
POSIX rather than Foundation, which is the more portable half of the pair.

Peak RSS rises from 343 to 429 MiB, because `Data(count:)` commits the whole transfer buffer up front
rather than growing into it. Bounded and cheap at this size, and a fifth of what the same run cost
before the pool fix.

## Every read of the run was still in memory at the end of it

A run on a 2 GB volume finished holding **1,388 MiB of live allocations**, and it scaled with the
volume's data — 678 MiB in use gave 803 MiB resident, 1,330 MiB gave 1,481 MiB. Left alone that is a
ceiling on volume size rather than a slow leak: a 500 GB drive half full would have wanted 250 GB of
memory.

The sequence that found it, since each step ruled out a plausible and wrong answer:

| Question | Measurement | Answer |
| --- | --- | --- |
| Page-cache accounting on an image file? | Same run against `/dev/rdisk14`, which has no page cache | No — 1.75 GiB there too |
| The write path? | A dry run, which writes nothing | No — 1.75 GiB |
| `CopyBatch`'s buffer? | Budget set to 4, 16 and 64 MiB | No — 1,467 / 1,467 / 1,475 MiB |
| Which phase? | Peak logged at phase boundaries | The copy: 50 MiB before it, 1,450 after |
| High-water mark, since freed? | Resident *now* rather than `ru_maxrss` | No — still resident at exit |
| Allocator holding freed pages? | `malloc_zone_statistics`: in-use against held | No — 1,388 MiB of it live |
| So what holds it? | `heap` on a paused process | 26,288 live `NSConcreteData`, 925 MiB |
| Allocated where? | `MallocStackLogging=1`, then `malloc_history -allBySize` | `FileHandle.read` inside `rawRead` |

`FileHandle` answers with an autoreleased `NSData`, and a command-line tool drains no pool between
calls — the outermost one belongs to `main` and lives until the process exits. The confirming detail
was in the same `heap` dump: `@autoreleasepool content 53 × 8192` bytes is about 26,500 pointer slots,
against exactly 26,288 live objects.

A pool inside each transfer loop fixes it. Inside rather than around, or a single 64 MB transfer still
holds all its chunks at once:

| | Live at exit | Peak RSS |
| --- | --- | --- |
| Image, before | 1,388 MiB | 1,477 MiB |
| Image, after | **9 MiB** | **138 MiB** |
| Spinner, before | — | 1,721 MiB |
| Spinner, after | **29 MiB** | **343 MiB** |

Timing is unchanged at 6m 52s, and the output is byte-identical. Worth knowing for anything else built
on Foundation here: the absence of a pool is not the absence of a problem, it is the whole problem.

## One cache, at the only two places that reach the medium

With no page cache underneath, a re-read is a real transfer. The tool used to hold directory blocks
between commits, which helped only where it was consulted — one call site — and could never help a
block's *first* visit. Funnelling all device access through one read and one write, and caching there,
turns that into a general answer:

| Spinner, raw, same volume | Before | After |
| --- | --- | --- |
| Copying | 4m 49s | 4m 46s |
| Repointing | 1m 36s | **1m 23s** |
| Verifying `.`/`..` entries | **20.1s** | **96ms** |
| **Total** | **7m 28s** | **6m 52s** |

Instrumenting the old arrangement is what sized it: repointing served 11,555 read runs from the cache
and still asked the drive for **4,858 runs, 3,779 KiB** — every byte of it inside directory clusters
the scan had read minutes earlier. It could not hit them because it only started filling once
repointing began.

The `.`/`..` figure was not predicted and is the larger of the two. It reads 64 bytes from each of
2,115 relocated directories, and those blocks are in the cache because `updateBytes` wrote them
through when it patched them. Caching at the bottom pays out in places that never asked for it.

Two things make it safe rather than merely fast:

- **`metadata` and `bulk` are distinguished.** A run copies more than a gigabyte of file contents,
  read once and written once. Caching that would evict the 33 MiB of metadata many times over to
  serve a hit that never comes, so bulk passes straight through — though its writes still invalidate,
  because a data cluster can land where a directory block used to be. The existing method split
  already encoded this: `readRaw`, `writeRaw` and `copyBytes` are the bulk path and nothing else uses
  them.
- **The invariant is structural now.** Every transfer goes through `deviceRead` or `deviceWrite`, and
  a write always drops what is cached for those blocks before optionally putting back what it wrote.
  Previously four call sites maintained that by hand, with a comment warning whoever added a fifth.
  `drop` before `admit` matters: `admit` declines when the cache is full, and declining to store what
  was just written while leaving the old contents in place would hand a later reader bytes the medium
  no longer holds.

Verified byte-identical to the previous build across the whole device, fsck clean, 42,000 files
matching.

## The cache was working, and only two thirds working

It had no counters, which for a pure optimisation is the dangerous kind of silence: nothing fails when
it stops working, and nothing says so either — a cache that quietly stopped admitting halfway through
would read as a slow medium. `--verbose` now reports it, and the first thing that showed was that one
overall hit rate is not a meaningful number. Bulk reads consult the cache and are *meant* to miss, so
counting them alongside metadata buried the figure that matters:

| | Hits | Looks | Rate |
| --- | --- | --- | --- |
| Metadata | 11,198 | 16,282 | **68%** |
| Bulk | 1,445 | 28,743 | 5.0% |

The bulk row is the clue. Only 7 of those 1,445 hits were staged data; the other 1,438 were *directory*
clusters being copied, which the scan had already read as metadata. Which raises the question the split
answers: a directory's copy goes out as bulk, so **the new location was never kept** — the tool had those
exact bytes in hand, wrote them, and threw them away, and every later read of that directory missed.
There are three such readers, and they all run after the move: each child's `..` patch, every pointer
flip landing in it, and the dot-entry check at the end.

Giving the volume a `Retention` — the caller knows things it cannot see — takes metadata from 68% to
**87%**, and the accounting is what makes it a clear win rather than a trade. A metadata hit is a read
that does not happen, so it belongs in the operation count:

| | Before | After | |
| --- | --- | --- | --- |
| Metadata reads | 5,084 | 2,113 | **−2,971** |
| Bulk transfers | 28,743 | 29,749 | +1,006 |
| **Device operations** | **33,827** | **31,862** | **−1,965 (−5.8%)** |
| Peak cache | 34.0 MiB | 45.0 MiB | +11 MiB |

The +1,006 is fusion lost: retention has to match to fuse, and the layout puts a directory immediately
before its own files, so those spans are adjacent on both sides constantly. Allowing them to fuse and
keeping the result recovers all 1,006 — and takes the cache to **106.9 MiB**, because the file content
riding along with each directory is kept too. That is the version to *not* build: it spends 62 MiB
caching file content that nothing will read again, to save 3% of the operations.

**Nothing was ever evicted, and the stated reason did not cover it.** "Once full it stops admitting
rather than evicting, which keeps what the scan gathered first" is an argument about *which* blocks to
sacrifice under pressure. It had quietly become a reason never to release blocks that are provably dead.

A released cluster's blocks are not wrong — a write there drops them anyway — they are simply never going
to be asked for again, and only the engine knows a release has happened. So the commit tells the cache.
Staged data is the case that needs it: written for the sole purpose of being read back once, and sitting
in the spare region above the compacted layout, which the layout never writes to, so it is the one kind
never dropped incidentally and would otherwise be held until the process exited.

| | No eviction | Releasing on free |
| --- | --- | --- |
| Metadata | 14,200 of 16,313 (87%) | **14,200 of 16,313 (87%)** |
| Bulk | 2,118 of 29,823 | **2,118 of 29,823** |
| Released | — | **33.4 MiB** |
| Peak | 45.2 MiB | 41.5 MiB |

**Not one hit lost**, which is the measurement that matters: it is the evidence that everything let go
was already dead, since releasing anything still wanted would show up immediately as a lower metadata
rate. The peak falls only 8% because it is reached early, while metadata is still accumulating and little
has been freed — the 33.4 MiB is the figure to read, and it is memory that used to be held to the end for
nothing. This volume parks only 13 objects, so nearly all of that is superseded directory locations; a
run that parks a thousand would release some 90 MiB of staged data on top.

**The ceiling was the more interesting thing this turned up.** It was 256 MiB, described as headroom for
large drives, and it is too small for the drive this tool is actually aimed at. Directory data is about
2.5% of a volume, so the 32 GB card of 273,296 files in these notes wants some 800 MiB of it — and
scaling the 45 MiB measured above by volume agrees, at around 700 MiB. That run would have stopped
admitting a third of the way through and, because nothing is evicted, gone cold for the remainder: every
directory read after that point a real transfer, and nothing anywhere saying so. Raised to 1 GiB, which
needs no floor for small volumes because a cache keyed by offset cannot hold more than the volume it is
caching. `admissionsDeclined` counts the first refusal and is reported, because a no-eviction policy is
only defensible while the ceiling is genuinely out of reach.

Byte-identical volume, fsck clean. **On the drive it is worth 24 to 27 seconds of a 6m 1s run**, replicated
at 5m 37s and 5m 34s, and the shape
is better than the size: repointing goes 1m 6s to 40.3s, which is 107% of the total saving, so it lands
entirely in the one phase that reads directory blocks. The estimate from the cost curve before the run
was "of order 25 seconds", which is closer than that method deserves. Copying is unchanged, so the 1,006
fused spans given up cost one second — inside noise, and not the price this change asks.

**And staging's second read is free, measured at last.** The image could only park 6 to 13 objects, so
this was a claim the README had made since the feature was written and never once checked. On the drive,
which parks 1,033:

    Of staged data: 1296 hits, 85.8 MiB never re-read from the medium.

The plan copies 5,482 clusters more than the volume holds, and at 16 KiB that is 85.7 MiB predicted
against 85.8 MiB served — every byte parked in spare space came back out of memory. More hits than
objects because a fetch-back is split across the spans it was written in.

Eviction released 118.8 MiB over that run, of which 85.8 MiB is the staged data and the remaining ~33 MiB
is superseded directory locations — which matches the 33.4 MiB measured on a completely different volume
above. Two independent measurements agreeing on the incidental half is worth more than either alone.

One thing to be straight about: peak was 66.2 MiB and no admission was declined, so **this volume never
needed the ceiling raised**. Without eviction it would have reached perhaps 150–185 MiB, still inside the
old 256 MiB. The case for 1 GiB rests on the 32 GB card, which is an extrapolation from directory-data
share and not something measured here.

## Sibling order is the biggest lever, and it is already at its best

Which sibling comes first inside a directory is not observable, so it is free to change, and it is
worth about half the copy work. Scored with `plan-score.py` on a 64%-full volume of 42,000 files:

| Sibling order | Moves | Gens | Staged | Transfers | Predicted |
| --- | --- | --- | --- | --- | --- |
| **by start cluster (current)** | 44,164 | **38** | 13 | **23,505** | **194s** |
| directory order (the original) | 44,186 | 59 | 35 | 30,823 | 305s |
| by size, ascending | 44,156 | 56 | **5** | 32,921 | 264s |
| by size, descending | 44,178 | 54 | 27 | 32,848 | 268s |
| by start cluster, descending | 44,262 | 74 | 111 | 35,940 | 231s |

Note that the metrics disagree — `size-asc` parks the fewest objects and is among the worst on
transfers — so a scorer needs one objective rather than a basket of them. And note the move column
barely moves at all: 0.24% across every rule.

**Ordering by current position wins by construction, not by luck.** The objective is to move as
little as possible; the rule is to lay things out where they already are. Anything ignoring current
position must move more. It holds on every shape tried — 103s against 117–151s on a 44%-full volume —
and the third case is the decisive one. Pointed at a volume this tool has already laid out, ordering
by start cluster moves **nothing at all**, while every other rule rewrites the whole volume:

| Already-defragmented volume | Moves | Clusters |
| --- | --- | --- |
| by start cluster | **0** | **0** |
| directory order | 55,962 | 123,783 |
| by size, ascending | 74,752 | 148,369 |

That fixed point is why choosing the rule per run — running several planners and keeping the best
score, which the CPU headroom would easily allow — is a bad idea rather than a free one. A scorer
judges the layout in front of it, and the run changes that layout: pick one rule on the first run and
the volume is now in that order, so the second run may score differently and rewrite gigabytes again.
Idempotence is worth more than a rule that wins on one shape, particularly on flash.

## Grouping directory clusters moves the cost, it does not remove it

The scan reads 33 MiB in 2,104 operations because the 2,120 directory clusters sit one in every
forty-four — the layout puts each directory immediately before its own files. Group them instead,
directory region first and file data after in the same tree order, and the scan would read the same
33 MiB contiguously: about **0.9s in 33 operations at no amplification**, worth 16s of a 6m 12s run and
worth it again on every later run.

It does not survive scoring. `plan-score.py` on the same two volumes:

| Volume | Layout | Moves | Clusters | Staged | Transfers | Predicted copy |
| --- | --- | --- | --- | --- | --- | --- |
| 65% full | current | 44,164 | 85,134 | 13 | 23,505 | **194s** |
| 65% full | grouped | 44,155 | 85,119 | 4 | 24,400 | 208s (+7%) |
| 44% full | current | 22,065 | 44,963 | 628 | 13,311 | **103s** |
| 44% full | grouped | 22,857 | 46,644 | 1,420 | 14,646 | 114s (+11%) |

**The copy phase gives back what the scan saves.** 7% of a 4m 8s copy phase is about 18s against the
scan's 16s — a wash on the fuller volume, and a loss on the emptier one, which moves 1,681 more
clusters and stages 628 objects instead of 1,420.

The cause is the same effect that made `inPlaceOrder` the largest win here: lifting 2,116 directory
clusters to the front shifts every file behind them, so homes end up further from where objects
already sit. Grouping does not create work, it relocates it out of a phase that is 5% of the run into
one that is 69%.

So it is not done, and the layout keeps its stated property: a directory sits immediately before its
own files, and a subtree is one run. Worth recording that the appeal was real — better on time,
operations and bytes *for the scan in isolation* — and that measuring the whole run reversed it. A
phase small enough to be worth optimising is also small enough that the fix can cost more than the
phase.

## Barriers are priced per byte, not per call

The phase table reports barriers as a line of their own — `100 barriers 1m 3s (13%)` on a spinning
drive — which reads like a fixed overhead that fewer, larger generations would amortise away. It is
not. Almost none of that line is the flush; it is the deferred write-back of the data, and the data
is the same however many times you ask for it.

Work per generation decays geometrically, so the tail is where this looks most attractive: on the
test volume the last 18 of 38 generations move 2% of the data. Staging on low yield rather than only
on a dead stall — parking the blockers once little is left, instead of grinding the dependency chain
down a link at a time — halves the generation count outright:

| Spinning drive, buffered | Baseline | Tail staging |
| --- | --- | --- |
| Generations | 50 | **25** |
| Barriers | 100 — 1m 3s | 50 — **1m 2s** |
| Copying | 5m 21s | 5m 15s |
| Clusters moved | 85,564 | 87,984 (+2.8%) |
| **Total** | **7m 58s** | 7m 52s |

Half the barriers, one second cheaper. `flush-cost.py` prices the call itself at **0.02s, flat, and
independent of how much is dirty**, so fifty barriers removed is worth 50 × 0.02s = 1.0s — which is
what it was worth. That figure was taken buffered, where the rest of the line was write-back charged
to the flush; on the raw node the same measurement reads 0.00s, because nothing was deferred to begin
with.

Either way generation count is not a lever, and the change was reverted: 2.8% more data copied and
stale staged copies left in free space, for one second. Anything proposing to reduce barrier count
should multiply the count by the per-call figure first. That product is the entire prize.

## An event stream costs nothing on a device and everything on an idle loop

The engine now reports itself as events rather than by calling a display, and it emits
unconditionally: about 230,000 events a run, where the old code skipped the work entirely when
nothing was watching. On the medium that is free — a spinning drive run went 353s to 350s, and the
device came out byte-identical — because the engine spends its life waiting and a consumer on
another thread has all the time it needs.

It is not free where the engine never waits, and that is the case worth measuring against. A run
over an image is page-cached throughout, so the producer runs flat out:

| Image run, redirected | Before | After |
| --- | --- | --- |
| Scan | 278ms | 317ms |
| Total | 6.0s | 6.2s |
| Dry run, whole | 0.42s | 0.55s |

About 560ns an event, and the first attempt was thirty times that. It was an `AsyncStream` with an
unbounded buffer, which hands over one element per `await`: a producer in a tight loop and a
consumer awaiting element by element contend on the stream's own lock for every single event, and
the scan above took **4.2s**. Swapping the whole backlog out under one mutex fixed it — the batch
boundary falls out of "what is here now" rather than out of a count of what is outstanding, and the
consumer suspends once per batch instead of once per event. Anything added to the event vocabulary
should be timed on an image, not on a device, for exactly this reason.

## Nothing here is CPU-bound

Before reaching for threads anywhere, note what the process actually uses:

| Run | Wall clock | user | sys | CPU share |
| --- | --- | --- | --- | --- |
| Spinning drive | 9m 11s | 0.91s | 5.11s | **1.1%** |
| Spinning drive | 11m 27s | 1.08s | 6.98s | 1.2% |

Six seconds of CPU across nine minutes, and much of the system half is the I/O syscalls
themselves. Planning 44,268 moves does not reach the one-second threshold that makes it report its
own timing. Making every calculation in the tool instantaneous would recover about 1%, and there
is no computation to hide behind a barrier even if the device would allow it.

## Never touch /dev/diskN

Restore, verify, run and capture all through `/dev/rdiskN`. Mix the two and the buffered node's cache
answers with blocks the run never wrote: the device is right and the reads are wrong. That produced
four files of convincing garbage and a very convincing false report of corruption in a change that
was in fact correct. `ab-verify.py` normalises its device argument to the raw node for this reason.

## One unexplained failure, worth remembering

The reason to keep `ab-verify.py` in the loop rather than trusting a clean run.

A run on one 32 GB card corrupted the volume: 541 blocks wrong out of
three million, in twelve small regions, and 356 of those still held their pre-run content — writes
that never landed. It repeated exactly, the same blocks with the same contents, twice.

What it is not:

- **Not the media.** A write-and-verify pass over the whole 1.5 GiB region: zero bad blocks.
- **Not the transfer size.** Single writes up to 4 MB complete fully; 256 MB of sustained 1 MB
  writes verify clean; scattered large writes with barriers verify clean.
- **Not coherency.** Write-then-read, read-write-read, and sub-block reads inside a
  recently-written 48 KB region all return the right bytes, sixty trials each.
- **Not the restore procedure.** With the card flushed and the starting state verified byte for
  byte before the run, it still happens.
- **Not the plan.** Logging every transfer — copies, pointer flips and FAT writes — and diffing a
  file run against a card run shows the first 15,603 transfers identical. The divergence begins at
  a *read*, which returns different bytes on the card than the same read of the same offset in the
  same state on a file. Reading it twice returns the same wrong bytes, so the read is stable, and
  no logged write had touched that offset.

And it vanishes under observation. The pre-merge build is clean; a build that reads back every
write is clean; a build that reads everything twice is clean. Only the plain merged build fails,
and always in the same places.

The merging has since been removed, and with it gone: 0 wrong blocks where there were 541 three runs
running. The correlation is established in both directions; the mechanism never was. It could be a
fault in that code, or a device that answers a particular pattern of large transfers badly.

The lesson to carry: the fault was never shown to be the *path's*, only to have appeared there, and a
clean run proves very little on its own. Anything touching how bytes reach the medium goes through
`ab-verify.py` on hardware before it is believed. The signature to watch for is writes that never
landed, in small regions, repeatably, with reads afterwards stably returning the wrong bytes.

**Since resolved, probably.** The transfer-limit fault at the top of this file is very likely the
same thing, and the reasons to think so are the ones listed above as exonerations:

- *"The divergence begins at a read, which returns different bytes on the card than the same read of
  the same offset in the same state on a file."* That is the fault exactly. An image advertises a
  larger maximum than a card, so the same oversized read is legal on one and not the other.
- *"Not the transfer size."* That test asked whether large transfers **complete** — single writes up
  to 4 MB, 256 MB of sustained 1 MB writes — and they do. Completing is not the same as returning
  correct data, and no test here asked the device what size it would accept.
- *"It vanishes under observation … a build that reads everything twice is clean."* Reading twice is
  what `--verify-copies` does, and it is how the fault was eventually caught rather than avoided.
- *"The merging has since been removed, and with it gone: 0 wrong blocks where there were 541."*
  Merging made transfers **larger**. Removing it brought them back under the limit.

Not proven — that was a different card, and nothing was kept from it. But the correlation runs the
right way in every particular, and the one measurement nobody took was the cheap one: a single ioctl
asking what the device would accept.

That ioctl is now taken on every run. It also turned out not to be enough, which is the next section.

## The card that lied, and how long it took to prove it

A second card produced the same shape of fault *after* the transfer limit was being honoured, and
this one was kept. It is characterised exactly, reproducible in under a second, and the tool now
detects it at startup. The reason to write it up at length is not the fault; it is the six wrong
turns, because every one of them looked conclusive at the time.

**What the device does.** The reader states a maximum transfer of 131,072 bytes twice over and
consistently — `DKIOCGETMAXBYTECOUNTWRITE` says 131,072, `DKIOCGETMAXBLOCKCOUNTWRITE` says 256
against a 512-byte block. Both are wrong. One pattern breaks it:

    two or more back-to-back transfers at the maximum size, contiguous on the medium
    a discontiguity of exactly half that size
    one more transfer at the maximum size    <- this one goes astray

On the write side that last transfer becomes a single 65,536-byte write carrying the payload's
*second* half, deposited at the *first* half's address. The first half is never written anywhere, the
second half's own destination is never touched, `pwrite` returns 131,072, and nothing reports an
error — `Retries` and `Errors` in the driver's own statistics both stay at zero across 3.85 million
operations. On the read side the same pattern is far worse: a 131,072-byte read after that run-up
disagreed with the same range read in 4 KiB pieces at **361 of 400** positions, against roughly
**three bad writes in 107,801**.

The boundary is hard at 2¹⁶ and is not an overflow by a few bytes of command overhead: 130,560 fails
exactly as 131,072 does, as do 129,024, 122,880 and 98,304, and only at 65,536 does it come good.
Every gap other than half the size is fine. Every smaller size is fine at every gap.

Nothing else on the machine asks for that shape. macOS writes 131,072-byte transfers to the same
reader all day — measured, 4,168 of them in a 512 MB copy — and loses nothing, because a file copy
never lays writes out as a long contiguous run punctuated by a half-size hole. `CopyBatch.flush`
does, necessarily: it writes a generation's spans in destination order. One run of 727,778 writes
lost 338 clusters and a directory that way, and reported a single error an hour in.

**The six wrong turns.** Each of these was measured, and each came back clean:

- **The medium.** 30 GiB written in four patterns, ~190,000 transfers — sequential at 128 KiB,
  interleaved 1:1 with distant reads, sequential at 64 KiB, and a generation model with sources and
  destinations 202 clusters apart. Zero displacement. All of it in the unallocated tail, which is
  the part a run never hammers.
- **The tool's logic.** An image matching the card in extent, cluster size, fill level and *contents*
  moved 388,624 objects and 1,427,815 clusters with all 273,092 files byte-identical. It only became
  a fair test once `pwrite-trace.c` was made to cap what the device reports, since an image
  advertises 2 MiB and so never enters the regime the card runs in — which is why this family of
  fault had never once appeared against an image.
- **The tool's arithmetic.** A trace of all 727,778 writes showed the cap never exceeded, zero short
  transfers, and two records out of 638,847 not block-aligned (a 107-byte read of another file). The
  offsets were right; the data did not arrive.
- **Buffer alignment.** A promising theory — a 131,072-byte transfer spans 32 pages from an aligned
  buffer and 33 from a malloc'd one — and dead on arrival: all 1,815 of the tool's large writes come
  from page-aligned buffers, the same as macOS's. Replaying with `mmap` buffers failed identically,
  the same 412 blocks at the same offsets.
- **Scatter-gather limits.** No USB device on the machine publishes `IOMaximumSegmentCountWrite` or
  `IOMaximumSegmentByteCountWrite` — not this reader, not the built-in SDXC reader, not a Samsung
  portable drive. Only NVMe and internal buses do. So the number that would have revealed the real
  constraint is not obtainable by asking.
- **Retries.** `Retry Count = 20` with 30-second timeouts in the driver's `Protocol
  Characteristics` made a retried `WRITE(10)` attractive as a mechanism. The statistics say zero
  retries and zero errors.

**What actually found it.** Replaying the traced run's exact I/O sequence — same offsets, same order,
same barriers, no `fatrabbit` in the picture — lost 412 blocks, all displaced by exactly +65,536. The
same sequence with nothing above 65,536 lost none of 37,278,362 blocks checked. From there,
bisection: the failure survived a 4-transfer run-up and vanished at 2, which turned days of work into
a table that prints in a second.

**Two self-inflicted wounds, both worth remembering.**

- **Do not verify a haunted card with the size it mishandles.** A bulk hash pass at 128 KiB reported
  four corrupt files out of 273,050 that hashed correctly on a second attempt, and later raised a
  false alarm that aborted a test run. Every verification tool here now reads at 64 KiB.
- **A destructive tool must refuse, not warn.** `haunt.py` was run against a freshly restored 33 GB
  card to check its output formatting, and wrote its pattern across roughly 400 live directories. Its
  docstring said DESTRUCTIVE in capitals at the time. It now reads the FAT and refuses to write
  anywhere allocated unless given `--anywhere`. A warning that has to be read at the right moment is
  not a safeguard.

**Verified.** Four rounds on that card and reader, each freeing two different root directories to
force a fresh cascade: 4,756,981 clusters relocated, 1,269,511 objects moved, `0 objects still
fragmented` every round, and every surviving file byte-identical before and after. The volume
afterwards has no broken directories, no `.` mismatches, no bad chains, no cross-links, no size
mismatches and no orphans.

**And it is faster.** Throughput on that reader climbs monotonically to 64 KiB and then falls off a
cliff — 18.9 MB/s of writes at 64 KiB against 13.6 at 128, and 20.5 against 15.7 for reads. The
fastest size and the largest safe size are the same size, so the ceiling costs nothing. A size that
is anomalously slow is worth treating as a warning in its own right, which is why the probe times
what it tests.

The tools: [`haunt.py`](haunt.py) asks a device the question directly and prints the table;
[`pwrite-trace.c`](pwrite-trace.c) records every transfer beneath the tool and can cap what the
device reports, which is what makes an image a fair test; [`card-session.sh`](card-session.sh)
captures paired images and traces across a sequence of runs.

## Getting write access to a device

Device nodes are `root:operator`, so as an ordinary user you can neither read nor write them.
The narrowest fix, scoped to one device and undone by unplugging it or rebooting — the raw node is
the one that matters now, but take both, since `diskutil` and `fsck_msdos` want the other:

    sudo chown $(whoami) /dev/diskN /dev/rdiskN

Adding yourself to the `operator` group works too, but grants read and write on every disk in
the machine, permanently. Resolve `N` by volume name every time — `diskutil list external physical`
— rather than remembering it from last session. It changes.

## A measurement run

The test device is a 320 GB USB 2.0 spinning drive, formatted as a FAT32 superfloppy so that the
node survives reformatting — see "A note on device nodes". `-c 32` gives the 16 KiB clusters a large
FAT32 volume uses, and cluster size changes the per-move cost. `-s` is not optional: without it the
volume takes the whole 320 GB and comes out with 19.5M clusters and a 78 MB FAT, which is a different
volume from every figure recorded here and one a 2 GiB snapshot cannot capture. 4194304 sectors is
2 GiB, and gives the **131,007 clusters with data at offset 1,064,960** that every run below reports:

    diskutil unmountDisk /dev/disk8
    newfs_msdos -F 32 -c 32 -s 4194304 -v SPINTEST /dev/rdisk8
    diskutil mount /dev/disk8

Populate, then unmount so nothing is holding the device. The scale is not optional either — the
default of 1 gives 300 directories, where the measurements here are all of **scale 7**: 2,100
directories, 42,000 files, about two thirds full:

    python3 make-test-volume.py /Volumes/SPINTEST small 7
    diskutil unmount /dev/disk8

Snapshot the fragmented state, so every run starts from identical conditions. **Not into /tmp**: it
went away in an OS upgrade, and the section below is what that cost:

    mkdir -p ~/Documents/fatrabbit-snapshots
    dd if=/dev/rdisk8 of=~/Documents/fatrabbit-snapshots/spin-fragmented.img bs=1m count=2048

Device numbers are assigned in attach order and mean nothing across a reboot or a replug: after one
OS upgrade `disk14`, which several scripts had hardcoded, was a CoreSimulator runtime volume, and a
restore would have written two gigabytes of FAT32 over an APFS image. `Testing/watch-spinner.sh`
resolves the drive by volume name and checks the answer is FAT32 before writing to it. Do the same
by hand, or check twice.

Then, for each build being compared:

    dd if=~/Documents/fatrabbit-snapshots/spin-fragmented.img of=/dev/rdisk8 bs=4m   # restore, ~55s
    time ./fatrabbit /dev/rdisk8

Compare `Copying finished in …`, not the total: the scan and the planner are not what changed.
Repeat each build at least twice — these repeat to within a second or two, and a pair that
disagrees means something else is going on.

## The filesystem driver writes the test volume, and it changes under you

The absolute spinner figures above and throughout were taken on a volume built before macOS 26.6.2.
That volume's snapshot was lost with `/tmp` in the upgrade, and rebuilding it from the same recipe —
same profile, same scale, and `make-test-volume.py` seeds its RNG precisely so this is reproducible —
did **not** reproduce it:

| Same recipe, either side of the upgrade | Before | After |
| --- | --- | --- |
| Files / directories | 42,138 / 2,116 | 42,149 / 2,116 |
| Clusters in use | 85,529 (65%) | 87,195 (66%) |
| Moves | 44,268 | 45,295 |
| Generations | 50 | **168** |
| Staged hops | 15 | **1,033** |

The file set is identical by construction; what differs is where the filesystem put it. `mount` now
reports `fskit` for msdos, so allocation is being done by a different implementation, and a schedule
is extremely sensitive to it — three times the generations and seventy times the staging, which is
roughly 35% more copying to do.

What this does and does not invalidate is worth being exact about. **A/B comparisons are unaffected**:
they restore one snapshot, run two builds, and compare bytes, so whichever volume is in use cancels
out. What does not survive is comparing an absolute figure to one recorded on the other side of the
upgrade — total, per-phase, or MiB/s. Re-baseline before reading any of those as current, and treat a
volume rebuild as invalidating every absolute number, not as restoring them.

## Verifying

After every run, both of these:

    mkdir -p /tmp/fp
    fsck_msdos -n /dev/rdisk8
    python3 fatread.py ~/Documents/fatrabbit-snapshots/spin-fragmented.img \
        > ~/Documents/fatrabbit-snapshots/spin-before.txt      # once, and keep it
    python3 fatread.py /dev/rdisk8 > /tmp/fp/spin-after.txt
    diff ~/Documents/fatrabbit-snapshots/spin-before.txt /tmp/fp/spin-after.txt

The "before" listing goes beside the snapshot it describes rather than into `/tmp`: it is only as
reproducible as that volume is, which is to say not at all once the volume is gone. The "after" is
regenerated every run and can live anywhere — but the directory has to exist, because `/tmp` is emptied
by some upgrades and some reboots, and the run after that is the one where you least want the harness
to be the thing that broke. `watch-spinner.sh` creates it for the same reason.

A file-content diff is not a layout check — `fatread.py` reports hashes and sizes, which pass
unchanged when every object has moved. To prove a layout is identical, compare the FAT region and
the used data region byte for byte.

`fatread.py` deliberately does not mount anything. Mounting means checking the tool and the
OS driver together, against a cache that may still hold what was there before the run — and
it drags in `.fseventsd` and `.Spotlight-V100`, which macOS rewrites on every mount, so a
comparison of mounted trees fails for reasons that have nothing to do with the volume.

## Baseline the medium first

    python3 medium-baseline.py /dev/rdisk14s1

| Medium | Sequential read | Random 4 KiB | Seek penalty |
| --- | --- | --- | --- |
| SD card, 32 GB | 18.8 MB/s (8.9 write, via dd) | 7.26 ms | 30x |
| USB 2.0 spinning drive, 320 GB | 38.1 MB/s | 26.06 ms | 69x |

These explain the results rather than merely accompanying them. The card writes at 8.9 MB/s and
reads at 18.8, which caps a one-way copy at about 6 MB/s — and on the `mixed` volume the tool
was already reaching 4.9, so there was nothing left for any reordering to win. On the spindle,
a run of 6,486 spans alternating between source and destination is thousands of head movements,
and that is what the batching removed.

The random figure is measured across the whole device, so treat it as an upper bound: a run
works within the region actually in use — a few hundred megabytes here — where seeks are
shorter and rotational latency dominates. That is why the spindle gained a fifth rather than
several fold.

## A note on device nodes

Repartitioning recreates the slice nodes, so a `chown` on `/dev/diskNs1` is lost the moment
you run `diskutil eraseDisk`. The whole-disk nodes survive it. Formatting the whole device as
a FAT32 "superfloppy" — `newfs_msdos -F 32 -c 32 -v NAME /dev/rdiskN`, no partition table —
sidesteps the problem entirely and mounts fine on macOS, which is how the spinning-drive
measurements above were taken.

## Barriers were never barriers on real hardware

`F_FULLFSYNC` is the call that makes a flush mean something: fsync(2) hands data to the drive and
stops, leaving it free to sit in a volatile cache. Every device node refuses F_FULLFSYNC with
ENOTTY — card and spinning drive, raw node and buffered alike — and only regular files accept it.
The code took the refusal as a cue to fall back to fsync and carry on, so every barrier any run
ever made against real hardware was half a barrier, silently.

`DKIOCSYNCHRONIZECACHE`, `_IO('d', 22)` from `<sys/disk.h>`, is the device-level equivalent and is
accepted by all of them. Both calls are needed: fsync to get the data out of the kernel, the ioctl
to get the drive to commit it.

It is not free, which is how you know it was doing nothing before. On the card the barriers went
from 40s to 47s across 106 of them, and the run from 3m 12s to 3m 28s — 8% for a guarantee the tool
already claimed to provide. Check it with:

    python3 -c "import os,fcntl; fd=os.open('/dev/rdisk4s1',os.O_RDWR); fcntl.fcntl(fd,51)"
