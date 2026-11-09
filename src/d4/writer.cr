require "json"
require "file/tempfile"
require "compress/deflate"
require "./write_control"

module D4
  class Writer
    getter control : WriteControl

    def initialize(@path : String | Path, *, chromosomes : Array(Chromosome),
                   dictionary : Dictionary, denominator : Float64 = 1.0,
                   @default_value : Int32 = 0_i32, @options : WriteOptions = WriteOptions.new,
                   @control : WriteControl = WriteControl.new)
      ensure_destination_available
      @metadata = Metadata.new(chromosomes, dictionary, denominator)
      @primary_spool = nil.as(::File?)
      @secondary_spool = nil.as(::File?)
      @secondary_starts = Hash(String, Int64).new
      @secondary_counts = Hash(String, Int64).new(0_i64)
      @primary_buffer = Bytes.new(65_536)
      @primary_used = 0
      @secondary_buffer = Bytes.new(65_530)
      @secondary_used = 0
      @pending_bits = 0_u64
      @bit_count = 0
      @record = Bytes.new(10)
      @encoded_position = 0_i64
      @encoded_chromosome_index = 0
      @chromosome_indices = Hash(String, Int32).new
      @current_chromosome_index = -1
      @next_position = Hash(String, Int64).new(0_i64)
      @closed = false
      @finished = false
      @metadata.chromosomes.each_with_index { |chromosome, index| @chromosome_indices[chromosome.name] = index }
    end

    def write_values(chromosome : String, position : Int, values : Array(Int32) | Slice(Int32)) : Int64 # ameba:disable Metrics/CyclomaticComplexity
      ensure_open
      metadata = @metadata
      start = checked_write_coordinate(position)
      validate_write_range(metadata, chromosome, start, values.size.to_i64)
      raise Error.new("writes must be monotonic and non-overlapping") if start < @next_position[chromosome]
      index = @chromosome_indices[chromosome]
      raise Error.new("writes must follow chromosome declaration order") if index < @current_chromosome_index
      return 0_i64 if values.empty?
      advance_primary(metadata, index, start)
      dictionary = metadata.dictionary
      width = dictionary.bit_width
      cursor = start
      if width == 0
        values.each do |value|
          @control.check! if cursor % 65_536 == 0
          append_secondary(chromosome, cursor, cursor + 1, value) unless dictionary.encode(value)
          cursor += 1
        end
      elsif dictionary.type.simple_range? && width <= 8 && @bit_count == 0
        cursor = append_dense_range(chromosome, cursor, values, dictionary, width)
      else
        fallback_code = (1_u32 << width) - 1_u32
        values.each do |value|
          @control.check! if cursor % 65_536 == 0
          code = dictionary.encode(value)
          append_primary_code(code || fallback_code, width)
          append_secondary(chromosome, cursor, cursor + 1, value) unless code
          cursor += 1
        end
      end
      @encoded_position = cursor
      @current_chromosome_index = index
      @next_position[chromosome] = cursor
      values.size.to_i64
    end

    # Known-size input follows the prevalidated bulk path above. Lazy input
    # is held in fixed-size chunks even for multi-gigabyte files.
    def write_values(chromosome : String, position : Int, values : Enumerable(Int32)) : Int64
      ensure_open
      metadata = @metadata
      start = checked_write_coordinate(position)
      validate_write_range(metadata, chromosome, start, 0_i64)
      chromosome_size = metadata.chromosome_size(chromosome)
      chromosome_index = @chromosome_indices[chromosome]
      cursor = start
      chunk = Array(Int32).new(65_536)
      values.each do |value|
        @control.check! if chunk.size % 1_024 == 0
        # Check the next coordinate before accepting it into the buffered
        # chunk. This preserves the lazy overload's guarantee that an
        # overlong input does not write past a chromosome boundary.
        available = chromosome_size - cursor
        raise ArgumentError.new("invalid write range") if chunk.size.to_i64 >= available
        if chunk.empty?
          raise Error.new("writes must be monotonic and non-overlapping") if cursor < @next_position[chromosome]
          raise Error.new("writes must follow chromosome declaration order") if chromosome_index < @current_chromosome_index
        end
        chunk << value
        if chunk.size.to_i64 == Math.min(65_536_i64, available)
          cursor += write_values(chromosome, cursor, chunk)
          chunk.clear
        end
      end
      cursor += write_values(chromosome, cursor, chunk) unless chunk.empty?
      cursor - start
    end

    private def append_dense_range(chromosome : String, cursor : Int64, values : Array(Int32) | Slice(Int32),
                                   dictionary : Dictionary, width : Int32) : Int64
      low = dictionary.low
      high = dictionary.high
      fallback_code = (1_u32 << width) - 1_u32
      index = 0
      while index + 8 <= values.size
        @control.check! if index % 65_536 == 0
        bits = 0_u64
        8.times do |part|
          value = values[index + part]
          code = if value >= low && value < high
                   (value.to_i64 - low).to_u32
                 else
                   append_secondary(chromosome, cursor + index + part, cursor + index + part + 1, value)
                   fallback_code
                 end
          bits |= code.to_u64 << (part * width)
        end
        flush_primary_buffer if @primary_used + width > @primary_buffer.size
        width.times do |byte|
          @primary_buffer[@primary_used + byte] = (bits >> (byte * 8)).to_u8!
        end
        @primary_used += width
        index += 8
      end
      while index < values.size
        value = values[index]
        code = if value >= low && value < high
                 (value.to_i64 - low).to_u32
               else
                 append_secondary(chromosome, cursor + index, cursor + index + 1, value)
                 fallback_code
               end
        append_primary_code(code, width)
        index += 1
      end
      cursor + values.size
    end

    def write_intervals(chromosome : String, intervals : Enumerable(RawInterval)) : Int64
      ensure_open
      count = 0_i64
      intervals.each do |interval|
        append_run(chromosome, interval.left, interval.right, interval.value)
        count += 1
      end
      count
    end

    def close : Nil
      return if @closed
      begin
        emit
      ensure
        @closed = true
        cleanup_spool
      end
    end

    def finish : Nil
      close
    end

    def flush : Nil
      ensure_open
      flush_primary_buffer
      flush_secondary_buffer
      @primary_spool.try(&.flush)
      @secondary_spool.try(&.flush)
    end

    def finished? : Bool
      @closed && @finished
    end

    def abort : Nil
      @closed = true
      cleanup_spool
    end

    def closed? : Bool
      @closed
    end

    def write_interval(chromosome : String, left : Int, right : Int, value : Int32) : Nil
      ensure_open
      append_run(chromosome, checked_write_coordinate(left), checked_write_coordinate(right), value)
    end

    def write_value(chromosome : String, position : Int, value : Int32) : Nil
      coordinate = checked_write_coordinate(position, "invalid point coordinate")
      raise ArgumentError.new("invalid point coordinate") if coordinate < 0 || coordinate >= UInt32::MAX
      write_interval(chromosome, coordinate, coordinate + 1, value)
    end

    def write_scaled_interval(chromosome : String, left : Int, right : Int, value : Float64, *, rounding : Rounding) : Nil
      write_interval(chromosome, left, right, quantize(value, rounding))
    end

    # Quantize known-size input before delegating to the prevalidated dense
    # writer. This avoids publishing a prefix when a later value is invalid.
    def write_scaled_values(chromosome : String, position : Int, values : Array(Float64) | Slice(Float64), *, rounding : Rounding) : Int64
      ensure_open
      metadata = @metadata
      start = checked_write_coordinate(position)
      validate_write_range(metadata, chromosome, start, values.size.to_i64)
      quantized = Array(Int32).new(values.size)
      values.each { |value| quantized << quantize(value, rounding) }
      write_values(chromosome, start, quantized)
    end

    def write_scaled_values(chromosome : String, position : Int, values : Enumerable(Float64), *, rounding : Rounding) : Int64
      ensure_open
      metadata = @metadata
      start = checked_write_coordinate(position)
      validate_write_range(metadata, chromosome, start, 0_i64)
      chromosome_size = metadata.chromosome_size(chromosome)
      chromosome_index = @chromosome_indices[chromosome]
      cursor = start
      chunk = Array(Int32).new(65_536)
      values.each do |value|
        @control.check! if chunk.size % 1_024 == 0
        quantized = quantize(value, rounding)
        available = chromosome_size - cursor
        raise ArgumentError.new("invalid write range") if chunk.size.to_i64 >= available
        if chunk.empty?
          raise Error.new("writes must be monotonic and non-overlapping") if cursor < @next_position[chromosome]
          raise Error.new("writes must follow chromosome declaration order") if chromosome_index < @current_chromosome_index
        end
        chunk << quantized
        if chunk.size.to_i64 == Math.min(65_536_i64, available)
          cursor += write_values(chromosome, cursor, chunk)
          chunk.clear
        end
      end
      cursor += write_values(chromosome, cursor, chunk) unless chunk.empty?
      cursor - start
    end

    private def validate_write_range(metadata : Metadata, chromosome : String, position : Int64, count : Int64) : Nil
      chromosome_size = metadata.chromosome_size(chromosome)
      raise ArgumentError.new("invalid write range") if position < 0 || count < 0 || position > chromosome_size || count > chromosome_size - position
    end

    # Public coordinate arguments use Crystal's broad `Int` union, which
    # includes UInt64 and Int128. Do the representability check before
    # converting to Int64 so an out-of-range unsigned coordinate produces the
    # same ArgumentError as any other invalid write range, not OverflowError.
    private def checked_write_coordinate(value : Int, message : String = "invalid write range") : Int64
      raise ArgumentError.new(message) if value < Int64::MIN || value > Int64::MAX
      value.to_i64
    end

    private def quantize(value : Float64, rounding : Rounding) : Int32
      denominator = @metadata.denominator
      scaled = value * denominator
      raise ArgumentError.new("scaled value must be finite") unless scaled.finite?
      rounded = case rounding
                in .nearest_away?
                  scaled >= 0 ? (scaled + 0.5).floor : (scaled - 0.5).ceil
                in .floor?
                  scaled.floor
                in .ceil?
                  scaled.ceil
                in .toward_zero?
                  scaled.trunc
                end
      raise ArgumentError.new("quantized value exceeds Int32") unless Int32::MIN <= rounded <= Int32::MAX
      rounded.to_i32
    end

    private def append_run(chromosome : String, left : Int64, right : Int64, value : Int32) : Nil
      @control.check!
      metadata = @metadata
      chrom = metadata.chromosome(chromosome)
      raise ArgumentError.new("invalid write range") if left < 0 || right < left || right > chrom.size
      index = @chromosome_indices[chromosome]
      raise Error.new("writes must follow chromosome declaration order") if index < @current_chromosome_index
      expected = @next_position[chromosome]
      raise Error.new("writes for #{chromosome.inspect} must be monotonic and non-overlapping") if left < expected
      return if left == right
      advance_primary(metadata, index, left)
      code = metadata.dictionary.encode(value)
      append_primary_run(code || ((1_u32 << metadata.dictionary.bit_width) - 1_u32), right - left, metadata.dictionary.bit_width)
      append_secondary(chromosome, left, right, value) unless code
      @encoded_position = right
      @current_chromosome_index = index
      @next_position[chromosome] = right
    end

    private def advance_primary(metadata : Metadata, index : Int32, left : Int64) : Nil
      chromosomes = metadata.chromosomes
      while @encoded_chromosome_index < index
        current = chromosomes[@encoded_chromosome_index]
        append_default(metadata, current.size - @encoded_position, current.name, @encoded_position)
        finish_primary_chromosome
        @encoded_chromosome_index += 1
        @encoded_position = 0_i64
      end
      append_default(metadata, left - @encoded_position, chromosomes[index].name, @encoded_position)
      @encoded_position = left
    end

    private def append_default(metadata : Metadata, length : Int64, chromosome : String, left : Int64) : Nil
      return if length == 0
      code = metadata.dictionary.encode(@default_value)
      append_primary_run(code || ((1_u32 << metadata.dictionary.bit_width) - 1_u32), length, metadata.dictionary.bit_width)
      append_secondary(chromosome, left, left + length, @default_value) unless code
    end

    private def append_primary_run(code : UInt32, length : Int64, width : Int32) : Nil
      return if width == 0
      remaining = length
      remaining = append_primary_blocks(code, remaining, width) if remaining >= 64
      while remaining > 0
        append_primary_code(code, width)
        remaining -= 1
      end
    end

    private def append_primary_blocks(code : UInt32, remaining : Int64, width : Int32) : Int64
      while remaining > 0 && @bit_count != 0
        append_primary_code(code, width)
        remaining -= 1
      end
      pattern = primary_pattern(code, width)
      while remaining >= 8
        @control.check!
        blocks = Math.min(remaining // 8, (@primary_buffer.size - @primary_used) // width).to_i
        if blocks == 0
          flush_primary_buffer
          next
        end
        copy_primary_pattern(pattern, blocks * width)
        remaining -= blocks.to_i64 * 8
      end
      remaining
    end

    private def primary_pattern(code : UInt32, width : Int32) : Bytes
      pattern = Bytes.new(width)
      8.times do |value_index|
        width.times do |shift|
          bit = value_index * width + shift
          pattern[bit // 8] |= 1_u8 << (bit % 8) if (code & (1_u32 << shift)) != 0
        end
      end
      pattern
    end

    private def copy_primary_pattern(pattern : Bytes, count : Int32) : Nil
      width = pattern.size
      section = @primary_buffer[@primary_used, count]
      section[0, width].copy_from(pattern)
      copied = width
      while copied < count
        step = Math.min(copied, count - copied)
        section[copied, step].copy_from(section[0, step])
        copied += step
      end
      @primary_used += count
      flush_primary_buffer if @primary_used == @primary_buffer.size
    end

    private def append_primary_code(code : UInt32, width : Int32) : Nil
      @pending_bits |= code.to_u64 << @bit_count
      @bit_count += width
      while @bit_count >= 8
        @primary_buffer[@primary_used] = @pending_bits.to_u8!
        @primary_used += 1
        flush_primary_buffer if @primary_used == @primary_buffer.size
        @pending_bits >>= 8
        @bit_count -= 8
      end
    end

    private def finish_primary_chromosome : Nil
      if @bit_count > 0
        @primary_buffer[@primary_used] = @pending_bits.to_u8
        @primary_used += 1
        flush_primary_buffer if @primary_used == @primary_buffer.size
        @pending_bits = 0_u64
        @bit_count = 0
      end
    end

    private def flush_primary_buffer : Nil
      return if @primary_used == 0
      @control.check!
      spool = @primary_spool ||= ::File.tempfile(".d4-primary-", ".tmp", dir: ::File.dirname(@path.to_s))
      spool.write(@primary_buffer[0, @primary_used])
      @primary_used = 0
    end

    private def append_secondary(chromosome : String, left : Int64, right : Int64, value : Int32) : Nil
      cursor = left
      while cursor < right
        length = Math.min(65_536_i64, right - cursor)
        unless @secondary_starts.has_key?(chromosome)
          flush_secondary_buffer
          @secondary_starts[chromosome] = @secondary_spool.try(&.pos) || 0_i64
        end
        encode_record(@record, cursor, length, value)
        @secondary_buffer[@secondary_used, 10].copy_from(@record)
        @secondary_used += 10
        flush_secondary_buffer if @secondary_used == @secondary_buffer.size
        @secondary_counts[chromosome] += 1
        cursor += length
      end
    end

    private def flush_secondary_buffer : Nil
      return if @secondary_used == 0
      @control.check!
      spool = @secondary_spool ||= ::File.tempfile(".d4-secondary-", ".tmp", dir: ::File.dirname(@path.to_s))
      spool.write(@secondary_buffer[0, @secondary_used])
      @secondary_used = 0
    end

    private def ensure_open : Nil
      raise ClosedError.new("D4 writer is closed") if @closed
      @control.check!
    end

    private def emit : Nil
      @control.update(WriteProgress.new(WriteStage::Finalizing))
      metadata = @metadata
      chromosomes = metadata.chromosomes
      while @encoded_chromosome_index < chromosomes.size
        @control.update(WriteProgress.new(WriteStage::Finalizing,
          chromosomes[@encoded_chromosome_index].name, @encoded_chromosome_index.to_i64, chromosomes.size.to_i64))
        current = chromosomes[@encoded_chromosome_index]
        append_default(metadata, current.size - @encoded_position, current.name, @encoded_position)
        finish_primary_chromosome
        @encoded_chromosome_index += 1
        @encoded_position = 0_i64
      end
      flush_primary_buffer
      flush_secondary_buffer
      header = build_header(metadata)
      secondary_metadata = build_secondary_metadata(metadata)

      root_payload_length = directory_payload_length([{".metadata", 0_u8}, {".ptab", 2_u8}, {".stab", 1_u8}])
      root_size = FrameEncoder.size_for(root_payload_length)
      header_storage_size = FrameEncoder.size_for(header.bytesize)
      stab_payload_length = directory_payload_length(([{".metadata", 0_u8}] + metadata.chromosomes.map_with_index { |_, index| {index.to_s, 0_u8} }))
      stab_size = FrameEncoder.size_for(stab_payload_length)

      root_offset = 8_i64
      header_offset = root_offset + root_size
      primary_offset = header_offset + header_storage_size
      primary_size = metadata.chromosomes.sum(0_i64) { |chromosome| (chromosome.size * metadata.dictionary.bit_width + 7) // 8 }
      stab_offset = primary_offset + primary_size
      stab_metadata_offset = stab_offset + stab_size
      root_entries = [
        DirectoryEncoder::Item.new(0_u8, ".metadata", header_offset, Format::DIRECTORY_FRAME_SIZE.to_i64),
        DirectoryEncoder::Item.new(2_u8, ".ptab", primary_offset, primary_size),
        DirectoryEncoder::Item.new(1_u8, ".stab", stab_offset, stab_size),
      ]
      ensure_destination_available
      target = @path.to_s
      temporary = ::File.tempfile(".d4-", ".tmp", dir: ::File.dirname(target))
      begin
        @control.check!
        temporary.write(Format::MAGIC)
        temporary.write(Bytes.new(4))
        temporary.write(Format.bytes(DirectoryEncoder.build(root_offset, root_entries)))
        temporary.write(Format.bytes(FrameEncoder.build(header.to_slice)))
        if spool = @primary_spool
          spool.flush
          spool.rewind
          @control.copy(spool, temporary, WriteStage::WritingPrimary, spool.size)
        end
        temporary.write(Bytes.new(stab_size.to_i))
        temporary.write(Format.bytes(FrameEncoder.build(secondary_metadata.to_slice)))
        stab_entries = [DirectoryEncoder::Item.new(0_u8, ".metadata", stab_metadata_offset, Format::DIRECTORY_FRAME_SIZE.to_i64)]
        metadata.chromosomes.each_with_index do |chromosome, index|
          @control.update(WriteProgress.new(WriteStage::WritingSecondary, chromosome.name,
            index.to_i64, metadata.chromosomes.size.to_i64))
          stream_offset = temporary.pos.to_i64
          frame_size = if level = @options.compression.level
                         write_compressed_secondary(temporary, chromosome, level)
                       else
                         write_secondary(temporary, chromosome)
                       end
          stab_entries << DirectoryEncoder::Item.new(0_u8, index.to_s, stream_offset, frame_size)
        end
        # Rust maps the entire secondary directory, including its child streams.
        # The root entry must describe that whole extent, not just the 512-byte
        # directory frame; otherwise Rust's mapped reader can index past the map.
        secondary_end = temporary.pos.to_i64
        temporary.seek(stab_offset, IO::Seek::Set)
        temporary.write(Format.bytes(DirectoryEncoder.build(stab_offset, stab_entries)))
        root_entries[2] = DirectoryEncoder::Item.new(1_u8, ".stab", stab_offset, secondary_end - stab_offset)
        temporary.seek(root_offset, IO::Seek::Set)
        temporary.write(Format.bytes(DirectoryEncoder.build(root_offset, root_entries)))
        temporary.flush
        temporary.close
        IndexBuilder.append(temporary.path, kinds: @options.indexes, control: @control) unless @options.indexes.empty?
        @control.update(WriteProgress.new(WriteStage::Publishing))
        if @options.overwrite?
          ::File.rename(temporary.path, target)
        else
          ::File.link(temporary.path, target)
          ::File.delete(temporary.path)
        end
        @finished = true
      ensure
        temporary.close unless temporary.closed?
        ::File.delete(temporary.path) if ::File.exists?(temporary.path)
      end
    end

    private def cleanup_spool : Nil
      [@primary_spool, @secondary_spool].each do |spool|
        next unless spool
        spool.close unless spool.closed?
        ::File.delete(spool.path) if ::File.exists?(spool.path)
      end
      @primary_spool = nil
      @secondary_spool = nil
    end

    private def ensure_destination_available : Nil
      target = @path.to_s
      if !@options.overwrite? && (::File.exists?(target) || ::File.symlink?(target))
        raise Error.new("destination already exists: #{target}")
      end
    end

    private def each_secondary_record(chromosome : Chromosome, & : Bytes -> Nil) : Nil
      count = @secondary_counts[chromosome.name]
      return if count == 0
      spool = @secondary_spool || raise Error.new("secondary spool is unavailable")
      spool.flush
      spool.seek(@secondary_starts[chromosome.name], IO::Seek::Set)
      record = Bytes.new(10)
      count.times do |index|
        @control.check! if index % 6_553 == 0
        spool.read_fully(record)
        yield record
      end
    end

    private def frame_size_for_count(count : Int64) : Int64
      Format::FRAME_HEADER_SIZE.to_i64 + Math.min(count, 6_553_i64) * 10
    end

    private def write_secondary(io : IO, chromosome : Chromosome) : Int64
      remaining = @secondary_counts[chromosome.name]
      first_size = frame_size_for_count(remaining)
      in_frame = 0_i64
      write_secondary_frame_header(io, remaining)
      each_secondary_record(chromosome) do |record|
        if in_frame == 6_553
          write_secondary_frame_header(io, remaining)
          in_frame = 0
        end
        io.write(record)
        remaining -= 1
        in_frame += 1
      end
      first_size
    end

    private def write_compressed_secondary(io : IO, chromosome : Chromosome, level : Int32) : Int64
      raw = Bytes.new(65_530)
      count = 0
      first = true
      first_pos = 0_i64
      last_pos = 0_i64
      pending = nil.as(Bytes?)
      each_secondary_record(chromosome) do |record|
        capacity = first ? 48 : 6_553
        if count == capacity
          frame = compressed_frame(raw[0, count * 10], count, first_pos, last_pos, first, level)
          write_linked_frame(io, pending, frame) if pending
          pending = frame
          first = false
          count = 0
        end
        first_pos = Format::Endian.u32_le(record, 0).to_i64 - 1 if count == 0
        last_pos = Format::Endian.u32_le(record, 0).to_i64 + Format::Endian.u16_le(record, 4).to_i64
        raw[count * 10, 10].copy_from(record)
        count += 1
      end
      if count > 0 || first
        frame = compressed_frame(raw[0, count * 10], count, first_pos, last_pos, first, level)
        write_linked_frame(io, pending, frame) if pending
        pending = frame
      end
      io.write(pending || raise Error.new("missing compressed secondary frame"))
      512_i64
    end

    private def compressed_frame(raw : Bytes, count : Int32, first_pos : Int64, last_pos : Int64,
                                 first : Bool, level : Int32) : Bytes
      compressed = IO::Memory.new
      Compress::Deflate::Writer.open(compressed, level: level, &.write(raw))
      compressed_bytes = compressed.to_slice
      raw_fallback = first && compressed_bytes.size > 483
      data = raw_fallback ? raw : compressed_bytes
      header = first ? 13 : 12
      frame = Bytes.new(first ? 512 : Format::FRAME_HEADER_SIZE + header + data.size)
      position = Format::FRAME_HEADER_SIZE
      if first
        frame[position] = raw_fallback ? 1_u8 : 0_u8
        position += 1
      end
      first_encoded = first_pos.to_u32
      last_encoded = last_pos.to_u32
      4.times do |i|
        frame[position + i] = ((first_encoded >> (8 * i)) & 0xff).to_u8
        frame[position + 4 + i] = ((last_encoded >> (8 * i)) & 0xff).to_u8
        frame[position + 8 + i] = ((count.to_u32 >> (8 * i)) & 0xff).to_u8
      end
      frame[position + 12, data.size].copy_from(data)
      frame
    end

    private def write_linked_frame(io : IO, previous : Bytes, following : Bytes) : Nil
      offset = previous.size.to_u64
      size = following.size.to_u64
      8.times do |i|
        previous[i] = ((offset >> (8 * i)) & 0xff).to_u8
        previous[8 + i] = ((size >> (8 * i)) & 0xff).to_u8
      end
      io.write(previous)
    end

    private def write_secondary_frame_header(io : IO, remaining : Int64) : Nil
      size = frame_size_for_count(remaining)
      next_count = remaining - Math.min(remaining, 6_553_i64)
      header = Bytes.new(16)
      if next_count > 0
        8.times { |i| header[i] = ((size.to_u64 >> (8 * i)) & 0xff).to_u8 }
        next_size = frame_size_for_count(next_count)
        8.times { |i| header[8 + i] = ((next_size.to_u64 >> (8 * i)) & 0xff).to_u8 }
      end
      io.write(header)
    end

    private def encode_record(record : Bytes, left : Int64, length : Int64, value : Int32) : Nil
      encoded = (left + 1).to_u32
      size = (length - 1).to_u16
      value_bits = value.unsafe_as(UInt32)
      4.times { |i| record[i] = ((encoded >> (8 * i)) & 0xff).to_u8 }
      2.times { |i| record[4 + i] = ((size >> (8 * i)) & 0xff).to_u8 }
      4.times { |i| record[6 + i] = ((value_bits >> (8 * i)) & 0xff).to_u8 }
    end

    private def build_header(metadata : Metadata) : String
      JSON.build do |json|
        json.object do
          json.field "chrom_list" do
            json.array { metadata.chromosomes.each { |chromosome| json.object { json.field "name", chromosome.name; json.field "size", chromosome.size } } }
          end
          json.field "dictionary" do
            json.object do
              if metadata.dictionary.type.simple_range?
                json.field "SimpleRange" do
                  json.object { json.field "low", metadata.dictionary.low; json.field "high", metadata.dictionary.high }
                end
              else
                json.field "Dictionary" do
                  json.object do
                    json.field "i2v_map" do
                      values = metadata.dictionary.values || raise Error.new("value-map dictionary is unavailable")
                      json.array { values.each { |value| json.number value } }
                    end
                  end
                end
              end
            end
          end
          if metadata.denominator == 1.0
            json.field "denominator", "One"
          else
            json.field "denominator" { json.object { json.field "Value", metadata.denominator } }
          end
        end
      end
    end

    private def build_secondary_metadata(metadata : Metadata) : String
      JSON.build do |json|
        json.object do
          json.field "format", "SimpleKV"
          json.field "record_format", "range"
          json.field "partitions" do
            json.array { metadata.chromosomes.each { |chromosome| json.array { json.string chromosome.name; json.number 0; json.number chromosome.size } } }
          end
          if level = @options.compression.level
            json.field "compression" { json.object { json.field "Deflate", level } }
          else
            json.field "compression", "NoCompression"
          end
        end
      end
    end

    private def directory_payload_length(entries : Array(Tuple(String, UInt8))) : Int64
      1_i64 + entries.sum(0_i64) { |entry| 1 + 1 + 8 + 8 + entry[0].bytesize + 1 }
    end
  end

  module FrameEncoder
    def self.size_for(payload_size : Int) : Int64
      capacity = (Format::DIRECTORY_FRAME_SIZE - Format::FRAME_HEADER_SIZE).to_i64
      payload = checked_payload_size(payload_size)
      max_frames = Int64::MAX // Format::DIRECTORY_FRAME_SIZE
      raise ArgumentError.new("frame payload size is too large") if payload > max_frames * capacity
      frames = Math.max(1_i64, (payload + capacity - 1) // capacity)
      frames * Format::DIRECTORY_FRAME_SIZE
    end

    def self.build(payload : Bytes) : Array(UInt8)
      frame_size = Format::DIRECTORY_FRAME_SIZE
      capacity = frame_size - Format::FRAME_HEADER_SIZE
      frames = Math.max(1, (payload.size + capacity - 1) // capacity)
      output = Array(UInt8).new(frames * frame_size, 0_u8)
      frames.times do |frame|
        offset = frame * frame_size
        if frame + 1 < frames
          write_u64(output, offset, frame_size.to_u64)
          write_u64(output, offset + 8, frame_size.to_u64)
        end
        start = frame * capacity
        count = Math.min(capacity, payload.size - start)
        count.times { |index| output[offset + Format::FRAME_HEADER_SIZE + index] = payload[start + index] }
      end
      output
    end

    def self.exact_size_for(payload_size : Int) : Int64
      payload = checked_payload_size(payload_size)
      raise ArgumentError.new("frame payload size is too large") if payload > Int64::MAX - Format::FRAME_HEADER_SIZE
      Format::FRAME_HEADER_SIZE.to_i64 + payload
    end

    def self.build_exact(payload : Bytes) : Array(UInt8)
      output = Array(UInt8).new(Format::FRAME_HEADER_SIZE + payload.size, 0_u8)
      payload.size.times { |index| output[Format::FRAME_HEADER_SIZE + index] = payload[index] }
      output
    end

    private def self.write_u64(output : Array(UInt8), offset : Int32, value : UInt64) : Nil
      8.times { |index| output[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
    end

    private def self.checked_payload_size(value : Int) : Int64
      raise ArgumentError.new("frame payload size must fit non-negative Int64") if value < 0 || value > Int64::MAX
      value.to_i64
    end
  end

  module DirectoryEncoder
    class Item
      def initialize(@kind : UInt8, @name : String, @offset : Int64, @size : Int64); end

      def append_to(output : Array(UInt8), base : Int64) : Nil
        raise ArgumentError.new("directory base must be non-negative") if base < 0
        raise ArgumentError.new("directory entry precedes its directory") if @offset < base
        raise ArgumentError.new("directory entry size is invalid") if @size < 0 || @size > Int64::MAX - @offset
        output << 1_u8 << @kind
        append_u64(output, (@offset - base).to_u64)
        append_u64(output, @size.to_u64)
        @name.each_byte { |byte| output << byte }
        output << 0_u8
      end

      private def append_u64(output : Array(UInt8), value : UInt64) : Nil
        8.times { |index| output << ((value >> (index * 8)) & 0xff_u64).to_u8 }
      end
    end

    def self.build(offset : Int64, entries : Array(Item)) : Array(UInt8)
      payload = Array(UInt8).new
      entries.each(&.append_to(payload, offset))
      payload << 0_u8
      FrameEncoder.build(Format.bytes(payload))
    end
  end
end
