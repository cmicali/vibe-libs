# waveform/Waveform

The waveform engine: the summary of an audio stream, the reads every display is drawn from, the raster that draws them, and the archive. The engine is plain C++17 over Accelerate and Compression: `WaveformSummary`, `WaveformBandSplit`, and `WaveformRaster`. Beside it, in Objective-C++, `AudioWaveform.h` names the summary for an app, mixes a decode's channels to mono, and archives the summary as a cache entry. It names no app type. It came from Vibe, the engine from its `Packages/WaveformCore`. It depends on `core/Common` alone, for that file's log. The rest of the waveform pieces follow in Phase 3's step 7 (`docs/plan.md`).

The headers sit beside the sources, and each states its contract. The namespace is `wavecore`, a name no variable takes, so a local `waveform` cannot shadow it. `AudioWaveform` is the summary's name outside the engine.

## How an app uses it

List `VibeLibsWaveform`. The template compiles the C++ sources at `-O3` in every configuration, searches the headers, and links Accelerate and `libcompression`. `AudioWaveform.mm` takes the target's own flags. The headers are C++, so only C++ and Objective-C++ can include them. **The app builds C++ as C++17 or later.** XcodeGen's default is gnu++14, where `std::clamp` is missing and the sources fail to compile.

```cpp
#include "WaveformSummary.hpp"
#include "WaveformRaster.hpp"

// Build: feed the decoded audio's mono mix in order.
wavecore::SummaryBuilder builder(/*bands*/ false, expectedFrames, sampleRate);
builder.append(mono, frameCount);
std::unique_ptr<wavecore::Summary> summary = builder.finish(/*complete*/ true);

// Read: the two zoom steps under a window of pixels, then each step's columns.
double framesPerPixel = double(summary->totalFrames()) / widthInPixels;
wavecore::StepWindow window = wavecore::StepWindowForPixels(summary->totalFrames(), framesPerPixel,
                                                            /*columnsPerPixel*/ 1, x0, x1);
for (const wavecore::StepPart &part : window.parts) {
    std::vector<wavecore::Column> columns(part.count);
    summary->columns(part.framesPerColumn(), part.first, part.count, columns.data());
}

// Archive.
std::vector<uint8_t> bytes = summary->encode();
std::unique_ptr<wavecore::Summary> restored = wavecore::Summary::decode(bytes.data(), bytes.size());
```

## The summary

**Every value is a function of absolute time.** A bin is a fixed span of frames counted from the start of the stream. So a bin never moves when the length turns out different, and two reads of the same frames always agree. Bins are 256 frames. A file too short to fill 8,192 of them takes a finer power of two, and a file too long to fit 2^18 a coarser one (`BinFramesForLength`). 2^18 bins of 256 frames are about 25 minutes at 44.1 kHz. **So a summary costs at most about 3.5 MB, 9.5 MB with bands, however long the file.** A long file needs no zoom near its samples, so coarser bins cost it nothing it needs. A 66-minute mix keeps 23 ms bins. A 6-hour file at 256 frames a bin took hundreds of megabytes. Each bin keeps the mono mix's peaks and sum of squares, and optionally three bands' sums. **A summary keeps the mix alone.** A display that draws one lane needs no channel's own peaks, and a second channel cost about 65% more disk. A builder appends a decode's stream in order. It measures a whole bin of the mix in one pass rather than three vDSP calls.

**A builder derives the pyramid and the loudest windows as bins arrive. A snapshot copies its bounded levels.** A bin's loudest window is derived once the bins half a window past it are in. A level then takes each whole group of four bins below it. The builder's finish closes the short groups, so its summary is identical to one built whole. A snapshot copies the finest level of at most `kSnapshotBins` (32,768) and the completed groups above it. It derives only the unfinished edge groups. **TRAP: a snapshot never copies every bin.** It once did, and its cost grew with the decode. Once one took longer than the 0.1 s between snapshots, every block took one, and a long file's decode ran at the snapshots' pace. A level above the base holds only whole groups. So a snapshot of one trails the last bin by under a second of a stream hours long.

**Peaks are stored as float16.** A float16 peak is exact to about a twentieth of a percent, and it halves a long file's memory.

## The reads

Every read takes frames, never bins.

- **`column` is exact.** Its extremes are the union of the base bins it touches. So a straddling bin's peaks count whole, and a peak is never lost. Unions do not depend on order, so they are read bottom up through the pyramid. At each level, the read takes the bins left at either end until both ends align with the level above. **A column carries no sums.** No display read them. The bins' sums stay inside the summary, where the loudest windows, the tent, and the archive read them.
- **`columns` is a grid counted from frame 0.** Column k covers [kF, (k+1)F). So a window, a scroll, or a zoom anchor never moves a column's frames.
- **`loudest` is a column's level.** It is the RMS of the loudest `kTransientSeconds` window centred on a bin the column covers, in the mix and in each band. Each bin's window is derived from the sums with the pyramid, so the archive does not carry it. The pyramid keeps each level's maximum. Like the extremes it is a union. So no hit is averaged into the frames around it, and no column edge can hide one. A column over the whole stream gives a normalize reference no view can move.
- **`tentBandMeanSquares`** reads the bands under a tent per column, through double running sums kept per pyramid level.

**Deep zoom reads the stream's own frames** (`Detail`, the summary's `detail()`). A holder fills it with blocks of 65,536 frames of the mix on demand, from any thread, while reads run. A grid of columns finer than a bin reads the detail block by block. Columns whose samples lie in blocks it holds read the samples, and the rest read the bins. When it read whole, one block still loading dropped every column to the bins. Vibe's iOS picture then flashed each time a scroll reached a new block. Only the column across a block's edge needs both blocks. It reads through the line joining the samples at their frames' centers. So a column narrower than a frame holds the line's span across it. At sample zoom the picture is that line. It keeps the newest 16 blocks. A copy starts without them. A read that misses blocks leaves them for the holder to take (`takeLackedBlocks`). Each insert is counted, so a reader knows to read again. **TRAP: a read crosses at most eight blocks, half those held.** Reads that need more than are held evict a block they need with each one read in, and ask for it again forever.

The pyramid and its loudest windows are built where a summary is made: by its builder as bins arrive, by a snapshot, or by a decode. So a reader on main never builds them. A summary appended by hand builds them on first read. The tent's running sums are built on first use. All are kept, behind one lock. A shared summary never changes. **TRAP: never append to a summary after a read.** Its pyramid would no longer describe it. Only builders and archive decodes append, before the summary is shared.

## The raster

`WaveformRaster.hpp` turns columns into device pixels, one pixel column at a time. So a picture's working memory is one column whatever its width.

- **A view reads columns only at zoom steps.** Step s holds columns of 2^(s/2) frames on the grid from frame 0. `StepWindowForPixels` picks the step no coarser than the frames a column should cover, the next coarser one, and how near the view is to each. It also picks the columns of each under a window of pixels. A resize, a zoom, or a scroll inside a step reads the same columns. So a view that keeps its samples needs no new reads.
- **Each pixel is a continuous function of the view.** `ForEachColumnShare` lands each column in the pixels it overlaps by its share. The two steps are crossfaded by the window's `coarse`. Columns reduced per pixel instead re-partition the track on every resize, and fine texture reshuffles. Sonic Visualiser avoids that by allowing only fixed zoom levels. The steps avoid it at every zoom.
- **`RemapStepSamples` moves samples from one window's layout to another's** by the track's frames, the same step first. A view that eases its samples keeps easing through a zoom or a scroll.
- **`ColumnCoverage` is exact.** A span covers each row by its part, and a span costs its two ends whatever its height. It writes a premultiplied white mask. It holds four neighbouring columns. Between the rows their spans touched, kept as a bit a row, all four are constant. So a run fills one 16-byte store a row, and an uncovered row is skipped. Its sums run in the same order as a pass over every row. So a change here must leave every picture byte for byte the same.
- **`ColumnPaint` paints spans in order.** A row takes each color by the area it shows there, never coverage over coverage. So edges that coincide do not stack into a bolder line. It writes only the rows a span covers, so its picture starts cleared. Coincident span edges share one sorted position. They divide no area.
- **A picture's cost is its stores.** There are two measured dead ends. Drawing through a 16-column tile and copying its rows out was slower, because a column's rows already stay in the cache across neighbouring columns. Merging four 3-Band columns' runs was slower too, because their edges differ and the runs fragment. Vibe's `VibeBenchComponents` dumps every picture of its `ui-waveform` benchmarks for a byte comparison (Vibe's `vibe-perf` skill).

Rows are written from the top with a signed stride. So a caller whose layer shows its contents flipped writes bottom-up.

## The archive

`encode` writes a header and the float16 planes: peaks, and each bin's RMS. A long bin's sum overflows float16, and a quiet bin's mean square rounded to zero in it. So a -80 dBFS sine lost its level on a cache reload. **Each value's low byte and high byte go in separate streams.** The low bytes, the bottom of the mantissa, are mostly noise. LZFSE made them larger and spent half its decode on them. So they take LZ4, which gives up on noise quickly and still shrinks silence. The high bytes repeat, so they take LZFSE. A stream that would not shrink is stored as it is, so a stream as long as its input is never compressed. It was measured on 95 real tracks against LZFSE over both halves after a delta filter. The archive is 2% smaller. It encodes in 30% less time and decodes in half. A delta filter on the split high bytes made them larger. LZBITMAP on the high bytes encoded four times faster but made the archive 7% larger. `decode` refuses anything malformed or non-finite, since the archive has no checksum. It takes any power-of-two bin size, because a long file's bins are coarser than 256 frames. Refusing them filed every long file for nothing, and each load decoded it again. **TRAP: an archive's bytes need not be aligned.** Copy the header out, never cast it.

**LZFSE is Apple's, from the system's Compression library, chosen by measurement.** zstd, lz4, brotli, and zlib-ng were each built and run on the archive's own planes, before they were split, from real tracks: a 24-s loop up to a 66-minute mix. Every codec landed between 0.70 and 0.90 of the raw size, because the peaks are close to noise. zstd at level 19, its window capped so the compressor stays near 5 MB, was 2.4 to 4.5% smaller than LZFSE and decoded faster. But it adds about 420 KB of code to each app. LZMA and brotli at their highest levels were 2% smaller again, but decoded 5 to 35 times slower. lz4 and zlib-ng were larger than LZFSE. LZFSE decodes a typical track's archive in about 0.2 ms with no third-party code. The codec is one call in each direction if the trade changes.

## The name, the mono mix, and the cache entry

`AudioWaveform.h` is the Objective-C++ face of the engine.

- **`AudioWaveform`** is `wavecore::Summary` under the name an app's code uses.
- **`AudioWaveformMonoMix`** averages a decode's interleaved channels into one. The summary and every analyzer on the same pass read that one mix. Mono input comes back as the buffer itself, with no copy.
- **`CodableAudioWaveform`** is the cache entry. It owns the summary, and it carries the results of the observers that rode the summary's decode, by identifier.

**The entry keeps the summary's own archive under the `summary` key**, beside the results. Only a complete summary is filed, and an incomplete one is refused on read. **The entry describes itself.** Its results are one dictionary from identifier to result, under the `results` key. That dictionary is an archive of its own, written with secure coding and read with an allow list of the property-list classes. So a reader needs no list of names, and an entry holds only what its decode ran. Results that will not read reject the entry, as a bad summary does. The entry checks only that a result is a property list. What a value means is its observer's to read.

**`kCodableAudioWaveformVersion` is the entry's format**, 7 today. It is encoded in every entry, and a cache may name its store after it, so both move together. An entry of another version is refused. Format 6 named a tempo and a key in fields of their own, so a format 6 entry is a miss like any older one. **An observer is versioned by its identifier, never by this number.** A changed algorithm takes a new identifier, and old entries then lack its result.

## Tests

`Tests/waveform/Waveform/` holds Vibe's tests of the summary and the raster. They cover the bin sizes, the builder against a summary built whole, the snapshots, exact columns at every range, the loudest windows, the tent, deep zoom's reads and the blocks a read lacks, the archive's round trip and its refusals, and the raster's steps, shares, coverage, and paint. `AudioWaveformMonoMixTests` and `CodableAudioWaveformTests` are Vibe's tests of `AudioWaveform.h`. They cover the mix's pass-through and its average of two or more channels, and the entry's round trip, its refusals, and the results it files. The minimal consumer summarizes a tone, files it as a cache entry, and draws it, as an app would.

`swift test` ran these tests in Vibe while the code was a Swift package. That ended with the move. They run here, in `WaveformTests`.

**Measuring.** A change that could move cost is measured in Vibe, with its `vibe-perf` skill, before and after. A change that could move a picture is drawn with its `vibe-waveform` skill at both commits, and the pictures are compared with `cmp`.
