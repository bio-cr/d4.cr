require "set"

module D4
  module Format
    MAGIC                = Bytes[0x64_u8, 0x34_u8, 0xdd_u8, 0xdd_u8]
    FRAME_HEADER_SIZE    =  16
    DIRECTORY_FRAME_SIZE = 512

    def self.bytes(values : Array(UInt8)) : Bytes
      result = Bytes.new(values.size)
      values.each_with_index { |value, index| result[index] = value }
      result
    end

    class Entry
      getter kind : UInt8
      getter offset : Int64
      getter size : Int64
      getter name : String

      def initialize(@kind : UInt8, @offset : Int64, @size : Int64, @name : String); end

      def stream? : Bool
        @kind == 0_u8
      end

      def directory? : Bool
        @kind == 1_u8
      end

      def blob? : Bool
        @kind == 2_u8
      end
    end

    class FrameStream
      @max_frame : Int64
      # Physical location of the payload most recently returned by next_payload.
      getter payload_offset : Int64 = 0_i64

      def initialize(@source : Source, @offset : Int64, @size : Int64, @limit : Int64, max_frame : Int64? = nil)
        @max_frame = max_frame || @limit
        @visited = Set(Int64).new
        @total = 0_i64
        @done = false
        @buffer = Bytes.empty
      end

      def next_payload : Bytes? # ameba:disable Metrics/CyclomaticComplexity
        return if @done
        if @size < FRAME_HEADER_SIZE || @size > Int32::MAX || @size - FRAME_HEADER_SIZE > @max_frame || @offset < 0 || @size > @source.size - @offset
          raise FormatError.new("frame exceeds source")
        end
        raise FormatError.new("cyclic frame stream") unless @visited.add?(@offset)
        payload_size = @size - FRAME_HEADER_SIZE
        @total += payload_size
        raise AllocationLimitError.new("frame stream exceeds configured limit") if @total > @limit
        @buffer = Bytes.new(@size.to_i) if @buffer.size < @size
        frame = @buffer[0, @size.to_i]
        @source.read_exact_at(@offset, frame)
        @payload_offset = @offset + FRAME_HEADER_SIZE
        link = Endian.i64_le(frame, 0)
        linked_size = Endian.u64_le(frame, 8)
        if link == 0
          @done = true
        else
          raise FormatError.new("invalid linked frame size") if linked_size < FRAME_HEADER_SIZE || linked_size > Int32::MAX
          # Check the addition before performing it. A corrupted positive
          # link near Int64::MAX used to raise OverflowError here instead of
          # being reported as an invalid D4 frame.
          if link > 0
            raise FormatError.new("linked frame offset is invalid") if link >= @source.size - @offset
          elsif link < 0
            raise FormatError.new("linked frame offset is invalid") if link < -@offset
          end
          next_offset = @offset + link
          raise FormatError.new("linked frame offset is invalid") if next_offset < 0 || next_offset >= @source.size
          @offset = next_offset
          @size = linked_size.to_i64
        end
        frame[FRAME_HEADER_SIZE, payload_size.to_i]
      end

      def self.read(source : Source, offset : Int64, first_size : Int64, limit : Int64) : Bytes
        output = Array(UInt8).new
        stream = new(source, offset, first_size, limit)
        while payload = stream.next_payload
          payload.each { |byte| output << byte }
        end
        Format.bytes(output)
      end
    end

    class Directory
      getter offset : Int64
      getter entries : Array(Entry)

      def initialize(@offset : Int64, @entries : Array(Entry)); end

      def self.open_root(source : Source, limit : Int64) : Directory
        magic = Bytes.new(8)
        source.read_exact_at(0, magic)
        unless magic[0, 4] == MAGIC
          raise FormatError.new("invalid D4 file magic")
        end
        open(source, 8_i64, limit)
      end

      def self.open(source : Source, offset : Int64, limit : Int64) : Directory # ameba:disable Metrics/CyclomaticComplexity
        payload = FrameStream.read(source, offset, DIRECTORY_FRAME_SIZE, limit)
        entries = Array(Entry).new
        names = Set(String).new
        cursor = 0
        while cursor < payload.size && payload[cursor] != 0_u8
          raise FormatError.new("truncated directory entry") if cursor + 18 > payload.size
          raise FormatError.new("invalid directory entry marker") unless payload[cursor] == 1_u8
          kind = payload[cursor + 1]
          raise FormatError.new("invalid directory entry kind") unless kind <= 2_u8
          relative = Endian.u64_le(payload, cursor + 2)
          size = Endian.u64_le(payload, cursor + 10)
          name_start = cursor + 18
          name_end = name_start
          while name_end < payload.size && payload[name_end] != 0_u8
            name_end += 1
          end
          raise FormatError.new("unterminated directory entry name") if name_end >= payload.size
          name = String.new(payload[name_start, name_end - name_start])
          raise FormatError.new("empty directory entry name") if name.empty?
          raise FormatError.new("directory entry offset exceeds Int64") if relative > Int64::MAX || size > Int64::MAX
          raise FormatError.new("duplicate directory entry #{name.inspect}") unless names.add?(name)
          raise FormatError.new("directory entry exceeds source") if relative > source.size - offset || size > source.size - offset - relative.to_i64
          raise FormatError.new("invalid stream frame size") if kind != 2_u8 && size < FRAME_HEADER_SIZE
          entries << Entry.new(kind, offset + relative.to_i64, size.to_i64, name)
          cursor = name_end + 1
        end
        new(offset, entries)
      end

      def entry?(name : String) : Entry?
        @entries.find { |entry| entry.name == name }
      end

      def entry(name : String, kind : UInt8) : Entry
        entry = entry?(name)
        raise FormatError.new("D4 directory entry #{name.inspect} is missing") unless entry
        raise FormatError.new("D4 directory entry #{name.inspect} has the wrong kind") unless entry.kind == kind
        entry
      end
    end

    module Endian
      def self.u16_le(bytes : Bytes, offset : Int32) : UInt16
        check_bytes(bytes, offset, 2)
        (bytes[offset].to_u16 | (bytes[offset + 1].to_u16 << 8))
      end

      def self.u32_le(bytes : Bytes, offset : Int32) : UInt32
        check_bytes(bytes, offset, 4)
        value = 0_u32
        4.times { |i| value |= bytes[offset + i].to_u32 << (i * 8) }
        value
      end

      def self.u64_le(bytes : Bytes, offset : Int32) : UInt64
        check_bytes(bytes, offset, 8)
        value = 0_u64
        8.times { |i| value |= bytes[offset + i].to_u64 << (i * 8) }
        value
      end

      def self.i64_le(bytes : Bytes, offset : Int32) : Int64
        u64_le(bytes, offset).unsafe_as(Int64)
      end

      def self.append_u16_le(output : Array(UInt8), value : UInt16) : Nil
        2.times { |i| output << ((value >> (i * 8)) & 0xff_u16).to_u8 }
      end

      def self.append_u32_le(output : Array(UInt8), value : UInt32) : Nil
        4.times { |i| output << ((value >> (i * 8)) & 0xff_u32).to_u8 }
      end

      def self.append_i32_le(output : Array(UInt8), value : Int32) : Nil
        append_u32_le(output, value.unsafe_as(UInt32))
      end

      private def self.check_bytes(bytes : Bytes, offset : Int32, count : Int32) : Nil
        raise FormatError.new("truncated binary field") if offset < 0 || count < 0 || offset > bytes.size || count > bytes.size - offset
      end
    end
  end
end
