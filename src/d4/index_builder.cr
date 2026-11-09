require "json"
require "./write_control"

module D4
  # Builds embedded indexes by copying a local D4 to a temporary file in the
  # same directory, then publishing the fully indexed result on success.
  class IndexBuilder
    GRANULARITY = 65_536_i64

    def self.build(path : String | Path, *, track : String? = nil,
                   kinds : Array(IndexKind) = [IndexKind::SecondaryFrames, IndexKind::Sum],
                   control : WriteControl = WriteControl.new) : Nil
      raise ArgumentError.new("no index kinds requested") if kinds.empty?
      target = path.to_s
      temporary = ::File.tempfile(".d4-index-", ".tmp", dir: ::File.dirname(target))
      begin
        ::File.open(target, "rb") do |input|
          control.copy(input, temporary, WriteStage::BuildingIndexes, input.size)
        end
        temporary.close
        append(temporary.path, track: track, kinds: kinds, control: control)
        control.check!
        ::File.chmod(temporary.path, ::File.info(target).permissions)
        control.update(WriteProgress.new(WriteStage::Publishing))
        ::File.rename(temporary.path, target)
      ensure
        temporary.close unless temporary.closed?
        ::File.delete(temporary.path) if ::File.exists?(temporary.path)
      end
    end

    # Appends in place. A failure can leave unreachable trailing bytes; use
    # `build` when the original file must remain byte-for-byte unchanged.
    def self.append(path : String | Path, *, track : String? = nil,
                    kinds : Array(IndexKind) = [IndexKind::SecondaryFrames, IndexKind::Sum],
                    control : WriteControl = WriteControl.new) : Nil
      raise ArgumentError.new("no index kinds requested") if kinds.empty?
      control.update(WriteProgress.new(WriteStage::BuildingIndexes))
      D4.open(path, track: track) do |file|
        control.check!
        selected = file.default_track
        root = Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
        directory = root
        ancestors = [] of Tuple(Format::Directory, Format::Entry)
        selected.name.split('/').each do |component|
          next if component.empty?
          entry = directory.entry(component, 1_u8)
          ancestors << {directory, entry}
          directory = Format::Directory.open(file.source, entry.offset, file.options.max_metadata_bytes)
        end
        old_index = directory.entry?(".index")
        old_entries = if old_index
                        raise CorruptIndexError.new(".index is not a directory") unless old_index.directory?
                        Format::Directory.open(file.source, old_index.offset, file.options.max_metadata_bytes).entries
                      else
                        [] of Format::Entry
                      end
        ::File.open(path, "r+b") do |output|
          output.seek(0, IO::Seek::End)
          index_offset = output.pos.to_i64
          root_items = directory.entries.reject { |entry| entry.name == ".index" }.map do |entry|
            DirectoryEncoder::Item.new(entry.kind, entry.name, entry.offset, entry.size)
          end
          root_items << DirectoryEncoder::Item.new(1_u8, ".index", index_offset, Format::DIRECTORY_FRAME_SIZE.to_i64)
          raise UnsupportedFeatureError.new("track directory has no room for .index") unless DirectoryEncoder.build(directory.offset, root_items).size == Format::DIRECTORY_FRAME_SIZE

          output.write(Bytes.new(Format::DIRECTORY_FRAME_SIZE))
          index_items = old_entries.reject do |entry|
            (entry.name == "secondary_frame_index" && kinds.includes?(IndexKind::SecondaryFrames)) ||
              (entry.name == "sum_index" && kinds.includes?(IndexKind::Sum))
          end.map do |entry|
            copy_index_entry(file.source, entry, output, control)
          end

          if kinds.includes?(IndexKind::SecondaryFrames)
            offset = output.pos.to_i64
            write_sfi(file, directory, output, control)
            index_items << DirectoryEncoder::Item.new(2_u8, "secondary_frame_index", offset, output.pos.to_i64 - offset)
          end
          if kinds.includes?(IndexKind::Sum)
            offset = output.pos.to_i64
            write_sum(selected, output, control)
            index_items << DirectoryEncoder::Item.new(2_u8, "sum_index", offset, output.pos.to_i64 - offset)
          end
          index_directory = DirectoryEncoder.build(index_offset, index_items)
          raise UnsupportedFeatureError.new("index directory is too large") unless index_directory.size == Format::DIRECTORY_FRAME_SIZE
          index_end = output.pos.to_i64
          output.seek(index_offset, IO::Seek::Set)
          output.write(Format.bytes(index_directory))
          root_items[-1] = DirectoryEncoder::Item.new(1_u8, ".index", index_offset, index_end - index_offset)
          ancestor_patches = ancestors.flat_map do |parent, entry|
            control.check!
            directory_size_patches(file, parent, entry, index_end - entry.offset)
          end
          control.check!
          output.seek(directory.offset, IO::Seek::Set)
          output.write(Format.bytes(DirectoryEncoder.build(directory.offset, root_items)))
          ancestor_patches.each do |patch_offset, bytes|
            output.seek(patch_offset, IO::Seek::Set)
            output.write(bytes)
          end
          output.flush
        end
      end
    end

    # Patch only the size field: ancestor directories can span noncontiguous
    # frames, so re-encoding them in place could overwrite unrelated objects.
    private def self.directory_size_patches(file : D4::File, directory : Format::Directory,
                                            entry : Format::Entry, size : Int64) : Array(Tuple(Int64, Bytes))
      skip = 10_i64
      directory.entries.each do |candidate|
        break if candidate.name == entry.name
        skip += 19_i64 + candidate.name.bytesize
      end
      encoded = IO::Memory.new
      write_u64(encoded, size.to_u64)
      bytes = encoded.to_slice
      patches = [] of Tuple(Int64, Bytes)
      copied = 0
      stream = Format::FrameStream.new(file.source, directory.offset,
        Format::DIRECTORY_FRAME_SIZE.to_i64, file.options.max_metadata_bytes)
      while payload = stream.next_payload
        if skip >= payload.size
          skip -= payload.size
          next
        end
        count = Math.min(8 - copied, payload.size - skip).to_i
        patches << {stream.payload_offset + skip, bytes[copied, count]}
        copied += count
        break if copied == 8
        skip = 0_i64
      end
      raise FormatError.new("truncated directory entry size") unless copied == 8
      patches
    end

    private def self.copy_index_entry(source : Source, entry : Format::Entry, output : IO,
                                      control : WriteControl) : DirectoryEncoder::Item
      raise UnsupportedFeatureError.new("cannot preserve non-blob index entry #{entry.name.inspect}") unless entry.blob?
      # Directory offsets are unsigned, so retained blobs must also follow the
      # new directory. SFI addresses remain relative to the unchanged .stab.
      offset = output.pos.to_i64
      copied = 0_i64
      buffer = Bytes.new(Math.min(entry.size, 65_536_i64).to_i)
      while copied < entry.size
        control.check!
        count = Math.min(entry.size - copied, buffer.size).to_i
        chunk = buffer[0, count]
        source.read_exact_at(entry.offset + copied, chunk)
        output.write(chunk)
        copied += count
      end
      DirectoryEncoder::Item.new(entry.kind, entry.name, offset, entry.size)
    end

    private def self.write_sfi(file : D4::File, directory : Format::Directory, output : IO,
                               control : WriteControl) : Nil
      secondary = directory.entry(".stab", 1_u8)
      stab = Format::Directory.open(file.source, secondary.offset, file.options.max_metadata_bytes)
      metadata = stab.entry(".metadata", 0_u8)
      raw = Format::FrameStream.read(file.source, metadata.offset, metadata.size, file.options.max_metadata_bytes)
      info = SecondaryMetadataParser.parse(raw)
      compressed = info.compressed
      count_position = output.pos
      write_u64(output, 0_u64)
      count = 0_u64
      names = file.default_track.chromosomes.map(&.name)
      partitions = info.partitions
      partitions.each_with_index do |partition, part_index|
        count += write_sfi_partition(file, stab, partition, part_index, partitions.size,
          compressed, names, output, control)
      end
      end_position = output.pos
      output.seek(count_position, IO::Seek::Set)
      write_u64(output, count)
      output.seek(end_position, IO::Seek::Set)
    end

    private def self.write_sfi_partition(file, stab, partition, part_index, partition_count,
                                         compressed, names, output, control) : UInt64
      name = partition.chromosome
      control.update(WriteProgress.new(WriteStage::BuildingIndexes, name,
        part_index.to_i64, partition_count.to_i64))
      chrom_id = names.index(name) || raise FormatError.new("secondary partition has unknown chromosome")
      chromosome_size = file.default_track.chromosomes[chrom_id].size.to_u32
      stream = stab.entry(part_index.to_s, 0_u8)
      offset = stream.offset
      frame_size = stream.size
      first = true
      carry = Bytes.empty
      last_entry = nil.as(Int64?)
      frame_buffer = Bytes.empty
      visited = Set(Int64).new
      count = 0_u64
      loop do
        control.check!
        raise FormatError.new("cyclic secondary frame stream") unless visited.add?(offset)
        validate_secondary_frame!(frame_size, file.options.max_decoded_frame_bytes)
        frame_buffer = Bytes.new(frame_size.to_i) if frame_buffer.size < frame_size
        frame = frame_buffer[0, frame_size.to_i]
        file.source.read_exact_at(offset, frame)
        start_pos, stop_pos, skip, carry = secondary_span(frame[16, frame.size - 16],
          compressed, first, carry, output, last_entry, chromosome_size)
        raise FormatError.new("secondary frame span exceeds chromosome") if start_pos > stop_pos || stop_pos > chromosome_size
        if stop_pos > start_pos
          raise UnsupportedFeatureError.new("SFI cannot address frames before the secondary directory") if offset < stab.offset
          last_entry = output.pos.to_i64
          write_sfi_entry(output, chrom_id.to_u32, start_pos, stop_pos,
            offset - stab.offset, frame_size, skip, first)
          count += 1
        end
        link = Format::Endian.i64_le(frame, 0)
        break if link == 0
        next_size = Format::Endian.u64_le(frame, 8)
        validate_secondary_link!(offset, link, next_size, file.source.size)
        frame_size = next_size.to_i64
        offset += link
        first = false
      end
      raise FormatError.new("truncated secondary record") unless carry.empty?
      count
    end

    private def self.secondary_span(payload, compressed, first, carry, output, last_entry, chromosome_size)
      if compressed
        header = first ? 13 : 12
        raise FormatError.new("truncated compressed frame") if payload.size < header
        {Format::Endian.u32_le(payload, first ? 1 : 0),
         Format::Endian.u32_le(payload, first ? 5 : 4), 0, carry}
      else
        start_pos, stop_pos, skip, next_carry, overhang = raw_span(payload, carry, chromosome_size)
        patch_overhang(output, last_entry, overhang) if overhang
        {start_pos, stop_pos, skip, next_carry}
      end
    end

    private def self.patch_overhang(output, last_entry, overhang) : Nil
      raise UnsupportedFeatureError.new("index cannot address a frame containing only a partial record") unless last_entry
      end_position = output.pos
      output.seek(last_entry + 8, IO::Seek::Set)
      write_u32(output, overhang)
      output.seek(end_position, IO::Seek::Set)
    end

    private def self.validate_secondary_frame!(frame_size, maximum) : Nil
      invalid = frame_size < 16 || frame_size > maximum || frame_size > Int32::MAX
      raise FormatError.new("invalid secondary frame size") if invalid
    end

    private def self.validate_secondary_link!(offset, link, next_size, source_size) : Nil
      invalid = next_size > Int32::MAX || next_size < 16
      raise FormatError.new("invalid linked secondary frame") if invalid
      # Frame links are signed, unlike directory and SFI offsets. Validate
      # before adding so either direction remains safe at integer boundaries.
      if link > 0
        raise FormatError.new("invalid linked secondary frame") if link >= source_size - offset
      else
        raise FormatError.new("invalid linked secondary frame") if link < -offset
      end
      raise FormatError.new("invalid linked secondary frame") if next_size.to_i64 > source_size - (offset + link)
    end

    private def self.raw_span(payload : Bytes, carry : Bytes, chromosome_size : UInt32) : Tuple(UInt32, UInt32, Int32, Bytes, UInt32?)
      first = 0_u32
      last = 0_u32
      have_first = false
      cursor = 0
      overhang = nil.as(UInt32?)
      if !carry.empty?
        missing = 10 - carry.size
        raise FormatError.new("secondary record spans more than two frames") if payload.size < missing
        record = Bytes.new(10)
        record[0, carry.size].copy_from(carry)
        record[carry.size, missing].copy_from(payload[0, missing])
        encoded = Format::Endian.u32_le(record, 0)
        raise FormatError.new("invalid split secondary record") if encoded == 0
        overhang = secondary_record_end(encoded, Format::Endian.u16_le(record, 4), chromosome_size)
        cursor = missing
      end
      skip = cursor
      while cursor + 10 <= payload.size
        encoded = Format::Endian.u32_le(payload, cursor)
        break if encoded == 0
        unless have_first
          first = encoded - 1
          have_first = true
        end
        last = secondary_record_end(encoded, Format::Endian.u16_le(payload, cursor + 4), chromosome_size)
        cursor += 10
      end
      remaining = payload[cursor, payload.size - cursor]
      next_carry = if remaining.any? { |byte| byte != 0_u8 }
                     raise FormatError.new("invalid secondary record alignment") if remaining.size >= 10
                     remaining.dup
                   else
                     Bytes.empty
                   end
      {first, last, skip, next_carry, overhang}
    end

    private def self.secondary_record_end(encoded : UInt32, length : UInt16, chromosome_size : UInt32) : UInt32
      ending = encoded.to_u64 + length
      raise FormatError.new("secondary record end exceeds chromosome") if ending > chromosome_size
      ending.to_u32
    end

    private def self.write_sfi_entry(io : IO, chrom_id : UInt32, start_pos : UInt32, stop_pos : UInt32,
                                     offset : Int64, size : Int64, skip : Int32, first : Bool) : Nil
      write_u32(io, chrom_id)
      write_u32(io, start_pos)
      write_u32(io, stop_pos)
      write_u64(io, offset.to_u64)
      write_u64(io, size.to_u64)
      io.write_byte(skip.to_u8)
      io.write_byte(first ? 1_u8 : 0_u8)
    end

    private def self.write_sum(track : Track, output : IO, control : WriteControl) : Nil
      write_u32(output, GRANULARITY.to_u32)
      write_u32(output, 0_u32)
      scratch = Slice(Int32).new(65_536)
      track.chromosomes.each_with_index do |chromosome, chromosome_index|
        control.update(WriteProgress.new(WriteStage::BuildingIndexes, chromosome.name,
          chromosome_index.to_i64, track.chromosomes.size.to_i64))
        position = 0_i64
        current_sum = 0_i64
        track.scan_values(Region.new(chromosome.name, 0, chromosome.size), scratch) do |_, values, count|
          control.check!
          count.times do |index|
            current_sum += values[index]
            position += 1
            if position % GRANULARITY == 0
              write_u64(output, current_sum.to_f64.unsafe_as(UInt64))
              current_sum = 0_i64
            end
          end
        end
        write_u64(output, current_sum.to_f64.unsafe_as(UInt64)) if position % GRANULARITY != 0
      end
    end

    private def self.write_u32(io : IO, value : UInt32) : Nil
      bytes = Bytes.new(4)
      4.times { |index| bytes[index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
      io.write(bytes)
    end

    private def self.write_u64(io : IO, value : UInt64) : Nil
      bytes = Bytes.new(8)
      8.times { |index| bytes[index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
      io.write(bytes)
    end
  end

  def self.build_indexes(path : String | Path, *, track : String? = nil,
                         kinds : Array(IndexKind) = [IndexKind::SecondaryFrames, IndexKind::Sum],
                         control : WriteControl = WriteControl.new) : Nil
    IndexBuilder.build(path, track: track, kinds: kinds, control: control)
  end
end
