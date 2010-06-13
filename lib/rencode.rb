require 'rubygems'
require 'bencode'

module REncode

  class DecodeError < StandardError
  end

  def self.dump(obj)
    bstr = BEncode.dump(obj)
    pycmd1 = "from deluge import rencode, bencode"
    return nil if bstr.size > 10000 # FIXME
    pycmd2 = "rencode.dumps(bencode.bdecode('#{bstr}'))"
    `python -c "#{pycmd1}; print #{pycmd2}"`.chomp
  end

  # Positive integers with value embedded in typecode.
  INT_POS_FIXED_START = 0
  INT_POS_FIXED_COUNT = 44

  # Strings with length embedded in typecode.
  STR_FIXED_START = 128
  STR_FIXED_COUNT = 64

  # Lists with length embedded in typecode.
  LIST_FIXED_START = STR_FIXED_START+STR_FIXED_COUNT
  LIST_FIXED_COUNT = 64

  # Default number of bits for serialized floats, either 32 or 64 (also a parameter for dumps()).
  DEFAULT_FLOAT_BITS = 32

  # Maximum length of integer when written as base 10 string.
  MAX_INT_LENGTH = 64

  # The bencode 'typecodes' such as i, d, etc have been extended and
  # relocated on the base-256 character set.
  CHR_LIST    = 59.chr
  CHR_DICT    = 60.chr
  CHR_INT     = 61.chr
  CHR_INT1    = 62.chr
  CHR_INT2    = 63.chr
  CHR_INT4    = 64.chr
  CHR_INT8    = 65.chr
  CHR_FLOAT32 = 66.chr
  CHR_FLOAT64 = 44.chr
  CHR_TRUE    = 67.chr
  CHR_FALSE   = 68.chr
  CHR_NONE    = 69.chr
  CHR_TERM    = 127.chr

  # Dictionaries with length embedded in typecode.
  DICT_FIXED_START = 102
  DICT_FIXED_COUNT = 25

  # Negative integers with value embedded in typecode.
  INT_NEG_FIXED_START = 70
  INT_NEG_FIXED_COUNT = 32

  LITTLE_ENDIAN = [1].pack('s') == "\001\000"

  decode_int = lambda do |x, f|
    f += 1
    newf = x.index(CHR_TERM, f)
    raise DecodeError, 'overflow' if newf - f >= MAX_INT_LENGTH
    n = x[f, newf - f].to_i
    if x[f, 1] == '-'
      raise DecodeError if x[f + 1, 1] == '0'
    elsif x[f, 1] == '0' and newf != f+1
      raise DecodeError
    end
    [n, newf+1]
  end

  decode_intb = lambda do |x, f|
    f += 1
    [x[f, 1].unpack('c')[0], f+1]
  end

  decode_inth = lambda do |x, f|
    f += 1
    v = x[f, 2].unpack('n').first
    v -= 0x8000 if v >= 0x8000
    [v, f+2]
  end

  decode_intl = lambda do |x, f|
    f += 1
    v = x[f, 4].unpack('N').first
    v -= 0x80000000 if v >= 0x80000000
    [v, f+4]
  end

  decode_intq = lambda do |x, f|
    f += 1
    x = x[f, 8]
    x.reverse! if LITTLE_ENDIAN
    [x.unpack('q')[0], f+8]
  end

  decode_float32 = lambda do |x, f|
    f += 1
    x = x[f, 4]
    x.reverse! if LITTLE_ENDIAN
    [x.unpack('f')[0], f+4]
  end

  decode_float64 = lambda do |x, f|
    f += 1
    x = x[f, 8]
    x.reverse! if LITTLE_ENDIAN
    [x.unpack('d')[0], f+8]
  end

  decode_string = lambda do |x, f|
    colon = x.index(':', f)
    n = x[f, colon - f].to_i
    raise DecodeError if x[f, 1] == '0' and colon != f+1
    colon += 1
    s = x[colon, n] # TODO support UTF-8
    [s, colon+n]
  end

  decode_list = lambda do |x, f|
    r, f = [], f+1
    while x[f, 1] != CHR_TERM
      v, f = @decode_func[x[f, 1]].call(x, f)
      r << v
    end
    [r, f + 1]
  end

  decode_dict = lambda do |x, f|
    r, f = {}, f+1
    while x[f, 1] != CHR_TERM
      k, f = @decode_func[x[f, 1]].call(x, f)
      r[k], f = @decode_func[x[f, 1]].call(x, f)
    end
    [r, f + 1]
  end

  decode_true = lambda do |x, f|
    [true, f+1]
  end

  decode_false = lambda do |x, f|
    [false, f+1]
  end

  decode_none = lambda do |x, f|
    [nil, f+1]
  end

  @decode_func = {}
  @decode_func['0'] = decode_string
  @decode_func['1'] = decode_string
  @decode_func['2'] = decode_string
  @decode_func['3'] = decode_string
  @decode_func['4'] = decode_string
  @decode_func['5'] = decode_string
  @decode_func['6'] = decode_string
  @decode_func['7'] = decode_string
  @decode_func['8'] = decode_string
  @decode_func['9'] = decode_string
  @decode_func[CHR_LIST   ] = decode_list
  @decode_func[CHR_DICT   ] = decode_dict
  @decode_func[CHR_INT    ] = decode_int
  @decode_func[CHR_INT1   ] = decode_intb
  @decode_func[CHR_INT2   ] = decode_inth
  @decode_func[CHR_INT4   ] = decode_intl
  @decode_func[CHR_INT8   ] = decode_intq
  @decode_func[CHR_FLOAT32] = decode_float32
  @decode_func[CHR_FLOAT64] = decode_float64
  @decode_func[CHR_TRUE   ] = decode_true
  @decode_func[CHR_FALSE  ] = decode_false
  @decode_func[CHR_NONE   ] = decode_none

  def self.make_fixed_length_string_decoders()
    STR_FIXED_COUNT.times do |i|
      @decode_func[(STR_FIXED_START+i).chr] = lambda {|x, f|
        s = x[f+1, i] # TODO support UTF-8
        [s, f+1+i]
      }
    end
  end

  make_fixed_length_string_decoders()

  def self.make_fixed_length_list_decoders()
    LIST_FIXED_COUNT.times do |i|
      @decode_func[(LIST_FIXED_START+i).chr] = lambda {|x, f|
        r, f = [], f+1
        i.times do
          v, f = @decode_func[x[f, 1]].call(x, f)
          r << v
        end
        [r, f]
      }
    end
  end

  make_fixed_length_list_decoders()

  def self.make_fixed_length_int_decoders()
    INT_POS_FIXED_COUNT.times do |i|
      @decode_func[(INT_POS_FIXED_START+i).chr] = lambda {|x, f|
        [i, f+1]
      }
    end
    INT_NEG_FIXED_COUNT.times do |i|
      @decode_func[(INT_NEG_FIXED_START+i).chr] = lambda {|x, f|
        [(-1-i), f+1]
      }
    end
  end

  make_fixed_length_int_decoders()

  def self.make_fixed_length_dict_decoders()
    DICT_FIXED_COUNT.times do |i|
      @decode_func[(DICT_FIXED_START+i).chr] = lambda {|x, f|
        r, f = {}, f+1
        i.times do
          k, f = @decode_func[x[f, 1]].call(x, f)
          r[k], f = @decode_func[x[f, 1]].call(x, f)
        end
        [r, f]
      }
    end
  end

  make_fixed_length_dict_decoders()

  def self.load(x)
    r, l = @decode_func[x[0, 1]].call(x, 0)
    raise DecodeError if l != x.size
    r
  end

end
