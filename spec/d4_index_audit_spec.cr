require "./spec_helper"

private def audit_put_u64(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = (value >> (8 * index)).to_u8! }
end

private def audit_record(left : UInt32, length : UInt16, value : Int32) : Bytes
  bytes = IO::Memory.new
  bytes.write_bytes(left, IO::ByteFormat::LittleEndian)
  bytes.write_bytes(length, IO::ByteFormat::LittleEndian)
  bytes.write_bytes(value, IO::ByteFormat::LittleEndian)
  bytes.to_slice
end

private def audit_secondary_chain(path : String, *, cycle : Bool = false, before_directory : Bool = false) : Nil
  D4.create(path, chromosomes: [D4::Chromosome.new("chr", 10)],
    dictionary: D4::Dictionary.new([0_i32])) { }
  D4.open(path) do |file|
    root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
    stab = D4::Format::Directory.open(file.source, root.entry(".stab", 1_u8).offset, file.options.max_metadata_bytes)
    File.open(path, "r+b") do |output|
      output.seek(0, IO::Seek::End)
      second_offset = output.pos.to_i64
      first_offset = second_offset + 26
      directory_offset = stab.offset
      if before_directory
        tail = Bytes.new((file.source.size - stab.offset).to_i)
        file.source.read_exact_at(stab.offset, tail)
        output.seek(stab.offset + 26)
        output.write(tail)
        first_offset = output.pos.to_i64
        second_offset = stab.offset
        directory_offset += 26
      end
      second = Bytes.new(26)
      second[16, 10].copy_from(audit_record(4_u32, 0_u16, 9))
      if cycle
        audit_put_u64(second, 0, (first_offset - second_offset).to_u64)
        audit_put_u64(second, 8, 26_u64)
      end
      first = Bytes.new(26)
      audit_put_u64(first, 0, (second_offset - first_offset).unsafe_as(UInt64))
      audit_put_u64(first, 8, 26_u64)
      first[16, 10].copy_from(audit_record(2_u32, 0_u16, 7))
      output.seek(second_offset)
      output.write(second)
      output.seek(first_offset)
      output.write(first)
      ending = output.pos.to_i64
      items = stab.entries.map do |entry|
        entry.name == "0" ? D4::DirectoryEncoder::Item.new(0_u8, "0", first_offset, 26_i64) : D4::DirectoryEncoder::Item.new(entry.kind, entry.name, entry.offset + directory_offset - stab.offset, entry.size)
      end
      output.seek(directory_offset)
      output.write(D4::Format.bytes(D4::DirectoryEncoder.build(directory_offset, items)))
      root_items = root.entries.map do |entry|
        if entry.name == ".stab"
          D4::DirectoryEncoder::Item.new(entry.kind, entry.name, directory_offset, ending - directory_offset)
        else
          D4::DirectoryEncoder::Item.new(entry.kind, entry.name, entry.offset, entry.size)
        end
      end
      output.seek(root.offset)
      output.write(D4::Format.bytes(D4::DirectoryEncoder.build(root.offset, root_items)))
    end
  end
end

describe "D4 index relocation and integer boundaries" do
  [:plain, :nested, :fragmented].each do |layout|
    it "updates all ancestor extents after indexing #{layout} tracks" do
      temporary = File.tempfile("d4-index-ancestors", ".d4")
      path = temporary.path
      begin
        data = File.read(File.join(__DIR__, "fixtures", "rust-multitrack.d4")).to_slice
        nested = layout != :plain
        if nested
          temporary.write(data[0, 8])
          size = data.size.to_i64 + 1024
          root_items = [
            D4::DirectoryEncoder::Item.new(1_u8, "group", 520_i64, size - 520),
          ]
          if layout == :fragmented
            # This entry makes group's eight-byte size straddle the frame
            # boundary. The continuation frame lives after the track data.
            root_items.unshift(D4::DirectoryEncoder::Item.new(2_u8, "p" * 463, 520_i64, 0_i64))
          end
          root_bytes = D4::Format.bytes(D4::DirectoryEncoder.build(8_i64, root_items))
          audit_put_u64(root_bytes, 0, (size - 8).to_u64) if layout == :fragmented
          temporary.write(root_bytes[0, 512])
          temporary.write(D4::Format.bytes(D4::DirectoryEncoder.build(520_i64, [
            D4::DirectoryEncoder::Item.new(1_u8, "tracks", 1032_i64, size - 1032),
          ])))
          temporary.write(data[8, data.size - 8])
          temporary.write(root_bytes[512, 512]) if layout == :fragmented
        else
          temporary.write(data)
        end
        temporary.close
        prefix = nested ? "group/tracks/" : ""
        track = "#{prefix}input2"
        sibling = "#{prefix}input"
        expected = D4.open(path, track: sibling) { |file| file.values("1", 9_999, 10_004) }
        [[D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum], [D4::IndexKind::Sum], [D4::IndexKind::SecondaryFrames]].each do |kinds|
          D4.build_indexes(path, track: track, kinds: kinds)
          D4.open(path, track: track) do |file|
            directory = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
            ancestors = [] of D4::Format::Entry
            track.split('/').each do |component|
              entry = directory.entry(component, 1_u8)
              ancestors << entry
              directory = D4::Format::Directory.open(file.source, entry.offset, file.options.max_metadata_bytes)
            end
            index = directory.entry(".index", 1_u8)
            ancestors.each { |entry| (entry.offset + entry.size).should be >= index.offset + index.size }
            file.default_track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
            file.sum("1", 0, 10_004, index: D4::IndexPolicy::Require).should eq(file.sum("1", 0, 10_004, index: D4::IndexPolicy::Scan))
          end
          D4.open(path, track: sibling) do |file|
            file.values("1", 9_999, 10_004).should eq(expected)
            file.default_track.has_index?(D4::IndexKind::Sum).should be_false
          end
        end
      ensure
        temporary.close unless temporary.closed?
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "indexes valid backward secondary links without changing values" do
    temporary = File.tempfile("d4-index-backward", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      audit_secondary_chain(path)
      expected = [0, 7, 0, 9, 0, 0, 0, 0, 0, 0]
      D4.open(path) { |file| file.values("chr").should eq(expected) }
      D4.build_indexes(path)
      D4.open(path) do |file|
        file.values("chr").should eq(expected)
        file.value("chr", 3).should eq(9)
        file.sum("chr", index: D4::IndexPolicy::Require).should eq(16)
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects cyclic secondary links without publishing the temporary file" do
    temporary = File.tempfile("d4-index-cycle", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      audit_secondary_chain(path, cycle: true)
      before = File.read(path)
      expect_raises(D4::FormatError, /cyclic secondary frame/) do
        D4.build_indexes(path, kinds: [D4::IndexKind::SecondaryFrames])
      end
      File.read(path).should eq(before)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reports secondary addresses before .stab as unsupported without unsigned overflow" do
    temporary = File.tempfile("d4-index-before-stab", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      audit_secondary_chain(path, before_directory: true)
      # Signed stream links can reach this frame, but the SFI's unsigned
      # offsets relative to .stab cannot represent its address.
      D4.build_indexes(path, kinds: [D4::IndexKind::Sum])
      D4.open(path) { |file| file.sum("chr", index: D4::IndexPolicy::Require).should eq(16) }
      before = File.read(path)
      expect_raises(D4::UnsupportedFeatureError, /before the secondary directory/) do
        D4.build_indexes(path, kinds: [D4::IndexKind::SecondaryFrames])
      end
      File.read(path).should eq(before)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects backward links that would underflow the source address" do
    temporary = File.tempfile("d4-index-underflow", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      audit_secondary_chain(path)
      D4.open(path) do |file|
        root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
        stab = D4::Format::Directory.open(file.source, root.entry(".stab", 1_u8).offset, file.options.max_metadata_bytes)
        File.open(path, "r+b") do |output|
          output.seek(stab.entry("0", 0_u8).offset)
          output.write_bytes(Int64::MIN, IO::ByteFormat::LittleEndian)
        end
      end
      before = File.read(path)
      expect_raises(D4::FormatError, /invalid linked secondary frame/) do
        D4.build_indexes(path, kinds: [D4::IndexKind::SecondaryFrames])
      end
      File.read(path).should eq(before)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects SFI counts whose header plus entries would overflow Int64" do
    blob = Bytes.new(8)
    audit_put_u64(blob, 0, (Int64::MAX // D4::SecondaryFrameIndex::ENTRY_SIZE).to_u64)
    source = D4::MemorySource.new(blob)
    entry = D4::Format::Entry.new(2_u8, 0_i64, 8_i64, "secondary_frame_index")
    expect_raises(D4::CorruptIndexError, /SFI size mismatch/) do
      D4::SecondaryFrameIndex.new(source, entry, 0_i64, [D4::Chromosome.new("chr", 10)])
    end
  end

  it "rejects raw secondary record ends that cannot fit the SFI representation" do
    temporary = File.tempfile("d4-index-record-end", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", UInt32::MAX)],
        dictionary: D4::Dictionary.new([0_i32])) do |writer|
        writer.write_value("chr", UInt32::MAX.to_i64 - 1, 7)
      end
      # The valid maximum endpoint must remain indexable.
      D4.build_indexes(path, kinds: [D4::IndexKind::SecondaryFrames])
      D4.open(path) { |file| file.value("chr", UInt32::MAX.to_i64 - 1).should eq(7) }
      D4.open(path) do |file|
        root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
        stab = D4::Format::Directory.open(file.source, root.entry(".stab", 1_u8).offset, file.options.max_metadata_bytes)
        File.open(path, "r+b") do |output|
          output.seek(stab.entry("0", 0_u8).offset + 20)
          output.write(Bytes[1, 0])
        end
      end
      before = File.read(path)
      expect_raises(D4::FormatError, /secondary record/) do
        D4.build_indexes(path, kinds: [D4::IndexKind::SecondaryFrames])
      end
      File.read(path).should eq(before)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  [D4::Compression.none, D4::Compression.deflate].each do |compression|
    it "rejects secondary frame spans beyond the chromosome (compression=#{compression.level})" do
      temporary = File.tempfile("d4-index-span", ".d4")
      path = temporary.path
      temporary.close
      File.delete(path)
      begin
        D4.create(path, chromosomes: [D4::Chromosome.new("chr", 10)],
          dictionary: D4::Dictionary.new([0_i32]),
          options: D4::WriteOptions.new(compression: compression)) do |writer|
          writer.write_value("chr", 9, 7)
        end
        D4.open(path) do |file|
          root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
          stab = D4::Format::Directory.open(file.source, root.entry(".stab", 1_u8).offset, file.options.max_metadata_bytes)
          File.open(path, "r+b") do |output|
            output.seek(stab.entry("0", 0_u8).offset + (compression.level ? 21 : 16))
            output.write_bytes(11_u32, IO::ByteFormat::LittleEndian)
          end
        end
        before = File.read(path)
        expect_raises(D4::FormatError, /secondary.*(record|span)/) do
          D4.build_indexes(path, kinds: [D4::IndexKind::SecondaryFrames])
        end
        File.read(path).should eq(before)
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end
end
