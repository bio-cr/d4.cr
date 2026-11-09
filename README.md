# d4.cr

[![test](https://github.com/bio-cr/d4.cr/actions/workflows/test.yml/badge.svg)](https://github.com/bio-cr/d4.cr/actions/workflows/test.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fbio-cr%2Fd4.cr%2Flines)](https://tokei.kojix2.net/github/bio-cr/d4.cr)
[![DOI](https://zenodo.org/badge/1413142768.svg)](https://doi.org/10.5281/zenodo.24074199)

d4.cr is a Crystal library for [D4](https://github.com/38/d4-format) files. It reads local and remote files, including files with multiple tracks, and writes single-track files.

## Install

Add to `shard.yml`, then run `shards install`. Crystal 1.21 or later is required.

```yaml
dependencies:
  d4:
    github: bio-cr/d4.cr
```

## Read values and intervals

```crystal
require "d4"

D4.open("depth.d4") do |file|
  p file.chromosomes.map(&.name)
  p file.value("chr1", 100)
  p file.values("chr1", 100, 110)

  file.each_interval("chr1", 100, 110) do |interval|
    puts "#{interval.left}\t#{interval.right}\t#{interval.value}"
  end
end
```

Coordinates are zero-based. `start` is included and `stop` is excluded. Raw values are `Int32`; chromosome sizes and interval positions are `Int64`.

## Write one track

```crystal
chromosomes = [D4::Chromosome.new("chr1", 1_000_i64)]

D4.create("depth.d4", chromosomes: chromosomes,
  dictionary: D4::Dictionary.new(0_i32, 8_i32)) do |writer|
  writer.write_values("chr1", 0, [1_i32, 2_i32, 3_i32])
  writer.write_interval("chr1", 100, 200, 5_i32)
end
```

The dictionary puts values in `0...8` in the primary table; other `Int32` values go to the secondary table. Unwritten positions default to `0`. Write chromosomes in declaration order and positions in increasing, non-overlapping order. Existing files are preserved unless `WriteOptions.new(overwrite: true)` is set.

## Summarize a region

```crystal
region = D4::Region.new("chr1", 100_i64, 200_i64)

D4.open("depth.d4") do |file|
  p file.sum(region)
  p file.summary(region).mean
  p file.histogram(region, value_range: 0_i32...100_i32).counts
  p file.coverage(region, thresholds: [1_i32, 10_i32]).counts
  p file.scaled.mean("chr1", 100, 200)
end
```

`scaled` divides stored values by the track's metadata denominator.

## Read multiple tracks

```crystal
D4.open("multi.d4") do |file|
  p file.track_names
  p file.track("sample_a").value("chr1", 100)

  matrix = file.matrix(["sample_a", "sample_b"])
  matrix.each_row(D4::Region.new("chr1", 100_i64, 105_i64)) do |row|
    puts "#{row.position}: #{row.values}"
  end
end
```

For file-level reads of a multi-track file, open it with `track: "sample_a"`. Matrix tracks must have the same chromosomes and lengths.

## Stream large regions

```crystal
D4.open("large.d4") do |file|
  nonzero = 0_i64
  buffer = Slice(Int32).new(65_536)
  file.default_track.scan_values("chr1", buffer) do |_start, values, _count|
    values.each { |value| nonzero += 1 if value != 0 }
  end
  puts nonzero
end
```

`values` materializes an array and defaults to a 64 MiB limit. `scan_values` reuses the buffer; process its slice before the next callback. `Writer#write_values` also accepts a lazy `Enumerable(Int32)`.

## Compression and indexes

```crystal
options = D4::WriteOptions.new(
  compression: D4::Compression.deflate,
  indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum]
)

D4.create("indexed.d4",
  chromosomes: [D4::Chromosome.new("chr1", 1_000_i64)],
  options: options) do |writer|
  writer.write_interval("chr1", 100, 200, 5_i32)
end

# For an existing local file without indexes:
D4.build_indexes("plain.d4")
```

`build_indexes` makes a temporary copy in the same directory, so allow disk space for another copy of the file. `D4::WriteControl` supports progress callbacks and cancellation during writing and index building.

## Read over HTTP

```crystal
require "d4/http"

source = D4::HTTPSource.new("https://example.org/depth.d4")
D4.open(source, sync_close: true) do |file|
  p file.sum("chr1", 0, 1000)
end
```

The server must support HTTP byte-range requests. Pass a `HTTPSource`, not a URL string, to `D4.open`.

## Origin and license

Hao Hou, Brent Pedersen, and Aaron Quinlan introduced D4 in their [paper](https://doi.org/10.1038/s43588-021-00085-0). The [original Rust project](https://github.com/38/d4-format) provides d4tools. d4.cr is a separate Crystal implementation by kojix2; Brent Pedersen also wrote [d4-nim](https://github.com/brentp/d4-nim).

d4.cr is MIT licensed; see [LICENSE](LICENSE). Upstream test fixtures are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
