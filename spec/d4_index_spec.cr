require "spec"
require "../src/d4"

class CountingD4Source < D4::Source
  getter bytes_read : Int64 = 0_i64

  def initialize(path : String)
    @source = D4::LocalSource.new(path)
  end

  def size : Int64
    @source.size
  end

  def read_at(offset : Int64, buffer : Bytes) : Int32
    count = @source.read_at(offset, buffer)
    @bytes_read += count
    count
  end

  def reset : Nil
    @bytes_read = 0_i64
  end

  def close : Nil
    @source.close
  end

  def closed? : Bool
    @source.closed?
  end
end

class CountingLocalD4Source < D4::LocalSource
  getter bytes_read : Int64 = 0_i64

  def read_at(offset : Int64, buffer : Bytes) : Int32
    count = super(offset, buffer)
    @bytes_read += count
    count
  end
end

private def put_le(bytes : Bytes, offset : Int32, value : UInt64, width : Int32) : Nil
  width.times { |index| bytes[offset + index] = (value >> (index * 8)).to_u8! }
end

private def secondary_record(left : Int32, length : Int32, value : Int32) : Bytes
  record = Bytes.new(10)
  put_le(record, 0, (left + 1).to_u64, 4)
  put_le(record, 4, (length - 1).to_u64, 2)
  put_le(record, 6, value.unsafe_as(UInt32).to_u64, 4)
  record
end

private def embedded_index_blobs(path : String) : Hash(String, Bytes)
  D4.open(path) do |file|
    root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
    indexed = root.entry(".index", 1_u8)
    directory = D4::Format::Directory.open(file.source, indexed.offset, file.options.max_metadata_bytes)
    blobs = Hash(String, Bytes).new
    directory.entries.each do |entry|
      entry.blob?.should be_true
      entry.offset.should be >= indexed.offset + D4::Format::DIRECTORY_FRAME_SIZE
      (entry.offset + entry.size).should be <= indexed.offset + indexed.size
      bytes = Bytes.new(entry.size.to_i)
      file.source.read_exact_at(entry.offset, bytes)
      blobs[entry.name] = bytes
    end
    blobs
  end
end

private def rewrite_sfi_with_legacy_leading_flag(path : String) : Nil
  source = D4::LocalSource.new(path)
  entry_offset = 0_i64
  bytes = Bytes.empty
  begin
    root = D4::Format::Directory.open_root(source, 4_194_304_i64)
    index_root = D4::Format::Directory.open(source, root.entry(".index", 1_u8).offset, 4_194_304_i64)
    entry = index_root.entry("secondary_frame_index", 2_u8)
    entry_offset = entry.offset
    bytes = Bytes.new(entry.size.to_i)
    source.read_exact_at(entry.offset, bytes)
    count = D4::Format::Endian.u64_le(bytes, 0).to_i
    count.times do |number|
      offset = 8 + number * 30
      standard = bytes[offset, 30].dup
      legacy = Bytes.new(30)
      legacy[0] = standard[29]
      legacy[1, 4].copy_from(standard[0, 4])
      legacy[5, 4].copy_from(standard[4, 4])
      legacy[9, 4].copy_from(standard[8, 4])
      legacy[13, 8].copy_from(standard[12, 8])
      legacy[21, 8].copy_from(standard[20, 8])
      legacy[29] = standard[28]
      bytes[offset, 30].copy_from(legacy)
    end
  ensure
    source.close
  end
  File.open(path, "r+b") do |output|
    output.seek(entry_offset, IO::Seek::Set)
    output.write(bytes)
  end
end

describe "embedded D4 indexes" do
  it "reports overflowing linked frame offsets as malformed D4 data" do
    frame = Bytes.new(D4::Format::FRAME_HEADER_SIZE)
    put_le(frame, 0, Int64::MAX.to_u64, 8)
    put_le(frame, 8, D4::Format::FRAME_HEADER_SIZE.to_u64, 8)
    source = D4::MemorySource.new(frame)
    stream = D4::Format::FrameStream.new(source, 0_i64, D4::Format::FRAME_HEADER_SIZE,
      D4::Format::FRAME_HEADER_SIZE.to_i64)

    expect_raises(D4::FormatError, /linked frame offset/) { stream.next_payload }
  end

  it "keeps a small local secondary frame index in memory" do
    blob = Bytes.new(8 + 30)
    put_le(blob, 0, 1_u64, 8)
    put_le(blob, 8 + 8, 10_u64, 4)
    put_le(blob, 8 + 20, 16_u64, 8)
    blob[8 + 29] = 1_u8
    temporary = File.tempfile("d4-small-secondary-index", ".bin")
    begin
      temporary.write(blob)
      temporary.flush
      source = CountingLocalD4Source.new(temporary.path)
      begin
        entry = D4::Format::Entry.new(2_u8, 0_i64, blob.size.to_i64, "secondary_frame_index")
        index = D4::SecondaryFrameIndex.new(source, entry, 0_i64, [D4::Chromosome.new("chr", 10)])
        loaded = source.bytes_read
        100.times do
          index.find("chr", 5_i64).try { |address| {address.offset, address.size} }.should eq({0_i64, 16_i64})
        end
        source.bytes_read.should eq(loaded)
        source.close
        expect_raises(D4::ClosedError) { index.find("chr", 5_i64) }
      ensure
        source.close
      end
    ensure
      temporary.close
      File.delete(temporary.path) if File.exists?(temporary.path)
    end
  end

  it "continues through indexed secondary partitions" do
    metadata = %({"record_format":"range","compression":"NoCompression","partitions":[["chr",0,100],["chr",100,200]]})
    io = IO::Memory.new
    metadata_offset = io.pos.to_i64
    metadata_frame = D4::Format.bytes(D4::FrameEncoder.build_exact(metadata.to_slice))
    io.write(metadata_frame)
    streams = [{10, 10, 99}, {150, 20, 120}].map do |left, length, value|
      offset = io.pos.to_i64
      frame = Bytes.new(26)
      frame[16, 10].copy_from(secondary_record(left, length, value))
      io.write(frame)
      {offset, frame.size.to_i64}
    end
    index_offset = io.pos.to_i64
    index = Bytes.new(8 + 2 * 30)
    put_le(index, 0, 2_u64, 8)
    [{10, 20}, {150, 170}].each_with_index do |(start, stop), number|
      offset = 8 + number * 30
      put_le(index, offset + 4, start.to_u64, 4)
      put_le(index, offset + 8, stop.to_u64, 4)
      put_le(index, offset + 12, streams[number][0].to_u64, 8)
      put_le(index, offset + 20, streams[number][1].to_u64, 8)
      index[offset + 29] = 1_u8
    end
    io.write(index)
    source = D4::MemorySource.new(io.to_slice)
    directory = D4::Format::Directory.new(0_i64, [
      D4::Format::Entry.new(0_u8, metadata_offset, metadata_frame.size.to_i64, ".metadata"),
      D4::Format::Entry.new(0_u8, streams[0][0], streams[0][1], "0"),
      D4::Format::Entry.new(0_u8, streams[1][0], streams[1][1], "1"),
    ])
    index_entry = D4::Format::Entry.new(2_u8, index_offset, index.size.to_i64, "secondary_frame_index")
    frame_index = D4::SecondaryFrameIndex.new(source, index_entry, 0_i64, [D4::Chromosome.new("chr", 200)])
    table = D4::SecondaryTable.new(source, directory, D4::ReadOptions.new, frame_index)
    [{0_i64, 200_i64, [{10_i64, 20_i64, 99_i32}, {150_i64, 170_i64, 120_i32}]},
     {50_i64, 180_i64, [{150_i64, 170_i64, 120_i32}]},
     {120_i64, 180_i64, [{150_i64, 170_i64, 120_i32}]},
     {160_i64, 165_i64, [{150_i64, 170_i64, 120_i32}]}].each do |start, stop, expected|
      records = table.record_iterator(D4::Region.new("chr", start, stop))
      actual = [] of Tuple(Int64, Int64, Int32)
      while records.next_fields
        actual << {records.left, records.right, records.value}
      end
      actual.should eq(expected)
    end
  end

  it "skips empty compressed secondary frames" do
    io = IO::Memory.new
    first = Bytes.new(29)
    first[16] = 1_u8
    io.write(first)
    second = Bytes.new(39)
    second[16] = 1_u8
    put_le(second, 25, 1_u64, 4)
    second[29, 10].copy_from(secondary_record(150, 20, 120))
    io.write(second)
    source = D4::MemorySource.new(io.to_slice)
    entries = [D4::Format::Entry.new(0_u8, 0_i64, 29_i64, "0"),
               D4::Format::Entry.new(0_u8, 29_i64, 39_i64, "1")]
    records = D4::SecondaryRecordIterator.new(source, entries, true, D4::Region.new("chr", 0, 200), 1_000_i64)
    records.next_fields.should be_true
    {records.left, records.right, records.value}.should eq({150_i64, 170_i64, 120_i32})
    records.next_fields.should be_false
  end

  it "streams indexes larger than the local cache limit" do
    count = 131_073
    blob = Bytes.new(8 + count * 8)
    blob[0] = 1_u8
    temporary = File.tempfile("d4-sum-large-index", ".bin")
    begin
      temporary.write(blob)
      temporary.flush
      source = CountingLocalD4Source.new(temporary.path)
      begin
        entry = D4::Format::Entry.new(2_u8, 0_i64, blob.size.to_i64, "sum_index")
        index = D4::SumIndex.new(source, entry, [D4::Chromosome.new("chr", count.to_i64)])
        index.full_blocks("chr", 0_i64, 1_i64).should eq(0_i64)
        source.bytes_read.should be <= 16_i64
      ensure
        source.close
      end
    ensure
      temporary.close
      File.delete(temporary.path) if File.exists?(temporary.path)
    end
  end

  it "validates only queried bins while caching local sum entries" do
    blob = Bytes.new(8 + 3 * 8)
    blob[0] = 1_u8
    encoded = 1.0_f64.unsafe_as(UInt64)
    2.times do |index|
      8.times { |byte| blob[8 + index * 8 + byte] = (encoded >> (byte * 8)).to_u8! }
    end
    blob[24, 8].fill(0xff_u8)
    temporary = File.tempfile("d4-sum-cache", ".bin")
    begin
      temporary.write(blob)
      temporary.flush
      source = D4::LocalSource.new(temporary.path)
      begin
        entry = D4::Format::Entry.new(2_u8, 0_i64, blob.size.to_i64, "sum_index")
        index = D4::SumIndex.new(source, entry, [D4::Chromosome.new("chr", 3_i64)])
        2.times { index.full_blocks("chr", 0_i64, 2_i64).should eq(2_i64) }
        expect_raises(D4::CorruptIndexError) { index.full_blocks("chr", 2_i64, 3_i64) }
        source.close
        expect_raises(D4::ClosedError) { index.full_blocks("chr", 0_i64, 2_i64) }
      ensure
        source.close
      end
    ensure
      temporary.close
      File.delete(temporary.path) if File.exists?(temporary.path)
    end
  end

  it "sums across index read chunks and validates later entries" do
    count = 8_193
    blob = Bytes.new(8 + count * 8)
    blob[0] = 1_u8
    encoded = 1.0_f64.unsafe_as(UInt64)
    count.times do |index|
      8.times { |byte| blob[8 + index * 8 + byte] = (encoded >> (byte * 8)).to_u8! }
    end
    source = D4::MemorySource.new(blob, copy: false)
    entry = D4::Format::Entry.new(2_u8, 0_i64, blob.size.to_i64, "sum_index")
    index = D4::SumIndex.new(source, entry, [D4::Chromosome.new("chr", count.to_i64)])
    index.full_blocks("chr", 0_i64, count.to_i64).should eq(count.to_i64)
    blob[8 + 8_192 * 8, 8].fill(0xff_u8)
    expect_raises(D4::CorruptIndexError) { index.full_blocks("chr", 0_i64, count.to_i64) }
  end

  it "reads Rust-built packed indexes and falls back for an incomplete final SUM bin" do
    path = File.join(__DIR__, "fixtures", "rust-indexed-sparse-100k.d4")
    D4.open(path) do |file|
      track = file.default_track
      track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
      track.has_index?(D4::IndexKind::Sum).should be_true
      file.value("chr", 99_900).should eq(100)
      file.sum("chr", index: D4::IndexPolicy::Require).should eq(448_000_i64)
      file.sum("chr", 65_500, 70_000, index: D4::IndexPolicy::Require).should eq(
        file.sum("chr", 65_500, 70_000, index: D4::IndexPolicy::Scan))
    end
  end

  it "builds both indexes while writing and reads late secondary records" do
    temporary = File.tempfile("d4-index-spec", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      options = D4::WriteOptions.new(indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum])
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 131_072_i64)],
        dictionary: D4::Dictionary.new([0_i32]), options: options) do |writer|
        20_000.times { |position| writer.write_value("chr", position, position.even? ? 1_i32 : 2_i32) }
      end
      D4.open(path) do |file|
        root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
        indexed = root.entry(".index", 1_u8)
        parts = D4::Format::Directory.open(file.source, indexed.offset, file.options.max_metadata_bytes)
        parts.entries.each do |entry|
          (entry.offset + entry.size).should be <= (indexed.offset + indexed.size)
        end
        file.default_track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
        file.default_track.has_index?(D4::IndexKind::Sum).should be_true
        file.value("chr", 19_999).should eq(2_i32)
        file.sum("chr", 14_000, 20_000, index: D4::IndexPolicy::Require).should eq(9_000_i64)
        file.sum("chr", 0, 131_072, index: D4::IndexPolicy::Require).should eq(30_000_i64)
      end
      counting = CountingD4Source.new(path)
      D4.open(counting, sync_close: true) do |file|
        counting.reset
        file.value("chr", 19_999).should eq(2_i32)
        counting.bytes_read.should be < 100_000_i64
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "writes standard SFI entries and reads legacy leading-flag entries safely" do
    temporary = File.tempfile("d4-index-layout", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path,
        chromosomes: [D4::Chromosome.new("first", 1_000_i64), D4::Chromosome.new("second", 30_000_i64)],
        dictionary: D4::Dictionary.new([0_i32]),
        options: D4::WriteOptions.new(indexes: [D4::IndexKind::SecondaryFrames])) do |writer|
        writer.write_value("first", 0, 7_i32)
        writer.write_values("second", 0, Array(Int32).new(30_000, 9_i32))
      end

      source = D4::LocalSource.new(path)
      begin
        root = D4::Format::Directory.open_root(source, 4_194_304_i64)
        index_root = D4::Format::Directory.open(source, root.entry(".index", 1_u8).offset, 4_194_304_i64)
        entry = index_root.entry("secondary_frame_index", 2_u8)
        first = Bytes.new(8 + 30)
        source.read_exact_at(entry.offset, first)
        # d4-format's packed FrameIndexEntry starts with chrom_id and ends
        # with first_frame. Older Crystal output used the reverse placement.
        first[8].should eq(0_u8)
        first[8 + 29].should eq(1_u8)
      ensure
        source.close
      end

      # The large second stream makes the old leading-flag layout's first
      # entry superficially valid as the standard layout. It used to make
      # indexed access seek into record bytes and fail with a bad frame link.
      rewrite_sfi_with_legacy_leading_flag(path)
      D4.open(path) do |file|
        file.value("second", 1).should eq(9_i32)
        file.value("second", 10_000).should eq(9_i32)
        file.value("second", 25_000).should eq(9_i32)
      end
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects a structurally plausible SFI layout that does not name frames" do
    # In the old leading-flag layout, standard decoding turns a first-frame
    # entry for chromosome N into chromosome 1 + 256*N. With 258 chromosomes
    # both decodings are monotonic and in range. Padding also makes the
    # incorrectly shifted address/size pass structural bounds checks, so the
    # physical .stab-frame comparison is the only safe discriminator.
    chromosomes = Array(D4::Chromosome).new(258) { |index| D4::Chromosome.new("chr#{index}", 1_000_i64) }
    temporary = File.tempfile("d4-index-physical-layout", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path,
        chromosomes: chromosomes,
        dictionary: D4::Dictionary.new([0_i32]),
        options: D4::WriteOptions.new(indexes: [D4::IndexKind::SecondaryFrames])) do |writer|
        writer.write_value("chr0", 0, 7_i32)
        writer.write_value("chr1", 0, 9_i32)
      end
      File.open(path, "ab", &.write(Bytes.new(4_194_304)))

      rewrite_sfi_with_legacy_leading_flag(path)
      # The raw SFI constructor has no secondary directory to use for the
      # physical check. It must fail closed instead of choosing standard
      # layout just because that candidate happens to be structurally valid.
      source = D4::LocalSource.new(path)
      begin
        root = D4::Format::Directory.open_root(source, 4_194_304_i64)
        secondary = root.entry(".stab", 1_u8)
        index_root = D4::Format::Directory.open(source, root.entry(".index", 1_u8).offset, 4_194_304_i64)
        entry = index_root.entry("secondary_frame_index", 2_u8)
        expect_raises(D4::CorruptIndexError, /ambiguous SFI entry layout/) do
          D4::SecondaryFrameIndex.new(source, entry, secondary.offset, chromosomes)
        end
      ensure
        source.close
      end
      # The false standard candidate points into the zero padding. It must
      # be rejected as `false`, rather than raising while the valid leading
      # candidate is being considered.
      D4.open(path) do |file|
        file.value("chr0", 0).should eq(7_i32)
        file.value("chr1", 0).should eq(9_i32)
      end
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "adds indexes safely to an existing D4 and preserves its values" do
    original = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")
    temporary = File.tempfile("d4-index-existing", ".d4")
    path = temporary.path
    begin
      File.open(original, "rb") { |input| IO.copy(input, temporary) }
      temporary.close
      before = File.read(path)
      expect_raises(D4::TrackSelectionError) { D4.build_indexes(path, track: "missing") }
      File.read(path).should eq(before)
      D4.build_indexes(path)
      D4.open(path) do |file|
        file.default_track.has_index?(D4::IndexKind::Sum).should be_true
        file.sum("chr", index: D4::IndexPolicy::Require).should eq(file.sum("chr", index: D4::IndexPolicy::Scan))
      end
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  [
    {"adds SUM while preserving SFI", "rust-input-10nt.d4", [D4::IndexKind::SecondaryFrames], D4::IndexKind::Sum, "secondary_frame_index"},
    {"adds SFI while preserving SUM", "rust-input-10nt.d4", [D4::IndexKind::Sum], D4::IndexKind::SecondaryFrames, "sum_index"},
    {"rebuilds SUM while preserving Rust SFI", "rust-indexed-sparse-100k.d4", ([] of D4::IndexKind), D4::IndexKind::Sum, "secondary_frame_index"},
    {"rebuilds SFI while preserving Rust SUM", "rust-indexed-sparse-100k.d4", ([] of D4::IndexKind), D4::IndexKind::SecondaryFrames, "sum_index"},
  ].each do |description, fixture, initial, requested, preserved|
    it description do
      temporary = File.tempfile("d4-index-partial", ".d4")
      path = temporary.path
      begin
        File.open(File.join(__DIR__, "fixtures", fixture), "rb") { |input| IO.copy(input, temporary) }
        temporary.close
        D4.build_indexes(path, kinds: initial) unless initial.empty?
        original_blobs = embedded_index_blobs(path)
        expected_sum = D4.open(path) { |file| file.sum("chr", index: D4::IndexPolicy::Scan) }
        expected_value = D4.open(path) { |file| file.value("chr", file.chromosomes.first.size - 1) }

        2.times do
          previous_size = File.size(path)
          D4.build_indexes(path, kinds: [requested])
          blobs = embedded_index_blobs(path)
          blobs[preserved].should eq(original_blobs[preserved])
          D4.open(path) do |file|
            root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
            root.entry(".index", 1_u8).offset.should eq(previous_size)
            file.default_track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
            file.default_track.has_index?(D4::IndexKind::Sum).should be_true
            file.sum("chr", index: D4::IndexPolicy::Require).should eq(expected_sum)
            file.sum("chr", index: D4::IndexPolicy::Scan).should eq(expected_sum)
            file.value("chr", file.chromosomes.first.size - 1).should eq(expected_value)
          end
        end
      ensure
        temporary.close unless temporary.closed?
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "leaves the original file unchanged when index building is cancelled" do
    original = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")
    temporary = File.tempfile("d4-index-cancel", ".d4")
    path = temporary.path
    begin
      File.open(original, "rb") { |input| IO.copy(input, temporary) }
      temporary.close
      before = File.read(path)
      controls = [] of D4::WriteControl
      controls << D4::WriteControl.new do |event|
        controls.first.cancel if event.stage.building_indexes?
      end
      expect_raises(D4::CancelledError) { D4.build_indexes(path, control: controls.first) }
      File.read(path).should eq(before)
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects an overflowing secondary link while building indexes" do
    temporary = File.tempfile("d4-index-overflowing-link", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 6_554_i64)],
        dictionary: D4::Dictionary.new([0_i32])) do |writer|
        writer.write_values("chr", 0, Array.new(6_554, 1_i32))
      end
      source = D4::LocalSource.new(path)
      begin
        root = D4::Format::Directory.open_root(source, 4_194_304_i64)
        secondary = D4::Format::Directory.open(source, root.entry(".stab", 1_u8).offset, 4_194_304_i64)
        stream = secondary.entry("0", 0_u8)
        File.open(path, "r+b") do |output|
          link = Bytes.new(8)
          put_le(link, 0, Int64::MAX.to_u64, 8)
          output.seek(stream.offset, IO::Seek::Set)
          output.write(link)
        end
      ensure
        source.close
      end

      expect_raises(D4::FormatError, /invalid linked secondary frame/) { D4.build_indexes(path) }
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "indexes DEFLATE secondary frames" do
    temporary = File.tempfile("d4-index-deflate", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      options = D4::WriteOptions.new(compression: D4::Compression.deflate,
        indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum])
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 20_000_i64)],
        dictionary: D4::Dictionary.new([0_i32]), options: options) do |writer|
        20_000.times { |position| writer.write_value("chr", position, position.even? ? 1_i32 : 2_i32) }
      end
      D4.open(path) do |file|
        file.value("chr", 19_999).should eq(2_i32)
        file.sum("chr", index: D4::IndexPolicy::Require).should eq(30_000_i64)
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "builds indexes in a selected track of a multi-track Rust file" do
    original = File.join(__DIR__, "fixtures", "rust-multitrack.d4")
    temporary = File.tempfile("d4-index-multi", ".d4")
    path = temporary.path
    begin
      File.open(original, "rb") { |input| IO.copy(input, temporary) }
      temporary.close
      D4.build_indexes(path, track: "input2")
      D4.open(path, track: "input2") do |file|
        file.default_track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
        file.default_track.has_index?(D4::IndexKind::Sum).should be_true
        file.sum("1", 0, 2, index: D4::IndexPolicy::Require).should eq(0_i64)
      end
      D4.open(path, track: "input") { |file| file.default_track.has_index?(D4::IndexKind::Sum).should be_false }
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects a corrupted sum entry even in automatic mode" do
    temporary = File.tempfile("d4-index-corrupt", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 131_072_i64)],
        dictionary: D4::Dictionary.new([0_i32]),
        options: D4::WriteOptions.new(indexes: [D4::IndexKind::Sum])) { |_| }
      source = D4::LocalSource.new(path)
      begin
        root = D4::Format::Directory.open_root(source, 4_194_304_i64)
        index = D4::Format::Directory.open(source, root.entry(".index", 1_u8).offset, 4_194_304_i64)
        blob = index.entry("sum_index", 2_u8)
        File.open(path, "r+b") do |output|
          output.seek(blob.offset + 8, IO::Seek::Set)
          output.write(Bytes.new(8, 0xff_u8))
        end
      ensure
        source.close
      end
      D4.open(path) do |file|
        expect_raises(D4::CorruptIndexError) { file.sum("chr", index: D4::IndexPolicy::Auto) }
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
