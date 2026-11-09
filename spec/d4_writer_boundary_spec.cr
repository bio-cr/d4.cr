require "./spec_helper"

describe "D4 writer coordinate boundaries" do
  it "rejects unrepresentable directory entries before encoding any bytes" do
    [
      {-1_i64, 0_i64, 0_i64},
      {10_i64, 9_i64, 0_i64},
      {0_i64, 10_i64, -1_i64},
      {0_i64, Int64::MAX, 1_i64},
    ].each do |base, offset, size|
      output = [42_u8]
      item = D4::DirectoryEncoder::Item.new(2_u8, "blob", offset, size)
      expect_raises(ArgumentError) { item.append_to(output, base) }
      output.should eq([42_u8])
    end
    item = D4::DirectoryEncoder::Item.new(2_u8, "blob", Int64::MAX, 0_i64)
    output = [] of UInt8
    item.append_to(output, 0_i64)
    D4::Format::Endian.u64_le(D4::Format.bytes(output), 2).should eq(Int64::MAX.to_u64)
  end

  it "validates Int64 chromosome lengths at writer creation" do
    path = File.join(Dir.tempdir, "d4-crystal-int64-chromosomes-#{Random.rand(1_000_000)}.d4")
    begin
      expect_raises(ArgumentError, /non-negative/) do
        D4.create(path, chromosomes: [D4::Chromosome.new("chr", -1_i64)])
      end
      expect_raises(D4::UnsupportedFeatureError, /UInt32::MAX/) do
        D4.create(path, chromosomes: [D4::Chromosome.new("chr", UInt32::MAX.to_i64 + 1)])
      end
      expect_raises(D4::UnsupportedFeatureError, /UInt32::MAX/) do
        D4::Chromosome.new("chr", UInt64::MAX)
      end
      # Configuration of a long chromosome must not allocate its primary table.
      maximum = D4::Chromosome.new("chr", UInt32::MAX)
      maximum.size.should eq(UInt32::MAX.to_i64)
      writer = D4.create(path, chromosomes: [maximum])
      writer.abort

      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 4_i64)]) do |small_writer|
        small_writer.write_value("chr", 3, 7_i32)
      end
      D4.open(path) do |file|
        file.chromosome_size("chr").should eq(4_i64)
        file.values("chr").should eq([0, 0, 0, 7])
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects overflowing positions without advancing writer state" do
    temporary = File.tempfile("d4-writer-boundary", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    writer = D4.create(path,
      chromosomes: [D4::Chromosome.new("chr", 2_i64)],
      dictionary: D4::Dictionary.new(0_i32, 2_i32))
    begin
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", Int64::MAX, [1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", Int64::MAX, [1_i32].each)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", Int64::MAX, [1.0_f64].each, rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_interval("chr", Int64::MAX, Int64::MAX, 1_i32)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_interval("chr", Int64::MAX, Int64::MAX, 1.0_f64, rounding: D4::Rounding::Floor)
      end
      # Array-like input has a known count, so reject the entire range before
      # it can advance the primary/secondary writer state.
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", 1, [1_i32, 1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", 1, Slice[1_i32, 1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", 1, [1.0_f64, 1.0_f64], rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", 1, Slice[1.0_f64, 1.0_f64], rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /scaled value must be finite/) do
        writer.write_scaled_values("chr", 0, [1.0_f64, Float64::NAN], rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", UInt64::MAX, [1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", UInt64::MAX, [1_i32].each)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", UInt64::MAX, [1.0_f64].each, rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_interval("chr", UInt64::MAX, UInt64::MAX, 1_i32)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_interval("chr", 0, UInt64::MAX, 1_i32)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_interval("chr", UInt64::MAX, UInt64::MAX, 1.0_f64, rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid point coordinate/) do
        writer.write_value("chr", UInt64::MAX, 1_i32)
      end

      array_count = writer.write_values("chr", 0, [1_i32])
      array_count.should be_a(Int64)
      array_count.should eq(1_i64)
      slice_count = writer.write_values("chr", 1, Slice[1_i32])
      slice_count.should be_a(Int64)
      slice_count.should eq(1_i64)
      writer.write_values("chr", 2, [] of Int32).should eq(0)
      writer.write_values("chr", 2, ([] of Int32).each).should eq(0)
      writer.write_scaled_values("chr", 2, ([] of Float64).each, rounding: D4::Rounding::Floor).should eq(0)
      expect_raises(ArgumentError, /invalid write range/) { writer.write_values("chr", -1, [] of Int32) }
      expect_raises(ArgumentError, /invalid write range/) { writer.write_values("chr", -1, ([] of Int32).each) }
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", -1, ([] of Float64).each, rounding: D4::Rounding::Floor)
      end
      writer.finish

      D4.open(path, &.values("chr").should(eq([1_i32, 1_i32])))
    ensure
      writer.abort unless writer.closed?
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects frame payload sizes that cannot be represented safely" do
    D4::FrameEncoder.size_for(0).should eq(D4::Format::DIRECTORY_FRAME_SIZE.to_i64)
    D4::FrameEncoder.exact_size_for(0).should eq(D4::Format::FRAME_HEADER_SIZE.to_i64)
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.size_for(-1) }
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.size_for(UInt64::MAX) }
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.size_for(Int64::MAX) }
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.exact_size_for(UInt64::MAX) }
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.exact_size_for(Int64::MAX) }
  end

  it "writes enumerable input in bounded chunks and returns a 64-bit count" do
    temporary = File.tempfile("d4-writer-stream", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path,
        chromosomes: [D4::Chromosome.new("raw", 70_000_i64), D4::Chromosome.new("scaled", 70_000_i64)],
        dictionary: D4::Dictionary.new(0_i32, 2_i32), denominator: 2.0) do |writer|
        # The iterator generates more than one chunk without holding all
        # chromosome values in an array.
        values = (0...70_000).each.map do |index|
          index == 65_535 || index == 65_536 ? 9_i32 : (index.odd? ? 1_i32 : 0_i32)
        end
        written = writer.write_values("raw", 0, values)
        written.should be_a(Int64)
        written.should eq(70_000_i64)
        scaled = (0...70_000).each.map { |index| index.odd? ? 0.5_f64 : 0.0_f64 }
        writer.write_scaled_values("scaled", 0, scaled, rounding: D4::Rounding::Floor).should eq(70_000_i64)
      end
      D4.open(path) do |file|
        file.value("raw", 65_535).should eq(9_i32)
        file.value("raw", 65_536).should eq(9_i32)
        file.value("raw", 69_999).should eq(1_i32)
        file.sum("raw").should eq(35_017_i64)
        file.value("scaled", 69_999).should eq(1_i32)
        file.sum("scaled").should eq(35_000_i64)
      end
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end
end
