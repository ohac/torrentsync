# coding: utf-8
require 'rubygems'

# for ruby 1.8
class String
  def force_encoding(e)
    self
  end
end

module REncode

  class DecodeError < StandardError
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
    s = x[colon, n].force_encoding('UTF-8')
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
        s = x[f+1, i].force_encoding('UTF-8')
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

  class EncodeError < StandardError
  end

  encode_int = lambda do |x, r|
    if 0 <= x and x < INT_POS_FIXED_COUNT
      r << (INT_POS_FIXED_START+x).chr
    elsif -INT_NEG_FIXED_COUNT <= x and x < 0
      r << (INT_NEG_FIXED_START-1-x).chr
    elsif -128 <= x and x < 128
      r << CHR_INT1 << [x].pack('c')
    elsif -32768 <= x and x < 32768
      r << CHR_INT2 << [x].pack('n')
    elsif -2147483648 <= x and x < 2147483648
      r << CHR_INT4 << [x].pack('N')
    elsif -9223372036854775808 <= x and x < 9223372036854775808
      r << CHR_INT8 << [x].pack('Q') # FIXME must be big endian with 64 bits
    else
      s = x.to_s
      raise EncodeError, 'overflow' if s.size >= MAX_INT_LENGTH
      r << CHR_INT << s << CHR_TERM
    end
  end

  encode_float32 = lambda do |x, r|
    r << CHR_FLOAT32 << [x].pack('f') # FIXME must be big endian
  end

  encode_float64 = lambda do |x, r|
    r << CHR_FLOAT64 << [x].pack('d') # FIXME must be big endian
  end

  encode_bool = lambda do |x, r|
    r << (x ? CHR_TRUE : CHR_FALSE)
  end

  encode_none = lambda do |x, r|
    r << CHR_NONE
  end

  encode_string = lambda do |x, r|
    size = x.unpack('C*').size
    if size < STR_FIXED_COUNT
      r << (STR_FIXED_START + size).chr << x
    else
      r << size.to_s << ':' << x
    end
  end

  encode_list = lambda do |x, r|
    if x.size < LIST_FIXED_COUNT
      r << (LIST_FIXED_START + x.size).chr
      x.each do |i|
        @encode_func[i.class].call(i, r)
      end
    else
      r << CHR_LIST
      x.each do |i|
        @encode_func[i.class].call(i, r)
      end
      r << CHR_TERM
    end
  end

  encode_dict = lambda do |x,r|
    if x.size < DICT_FIXED_COUNT
      r << (DICT_FIXED_START + x.size).chr
      x.each do |k, v|
        @encode_func[k.class].call(k, r)
        @encode_func[v.class].call(v, r)
      end
    else
      r << CHR_DICT
      x.each do |k, v|
        @encode_func[k.class].call(k, r)
        @encode_func[v.class].call(v, r)
      end
      r << CHR_TERM
    end
  end

  @encode_func = {}
  @encode_func[Fixnum] = encode_int
  @encode_func[Bignum] = encode_int
  @encode_func[String] = encode_string
  @encode_func[Array] = encode_list
  @encode_func[Array] = encode_list
  @encode_func[Hash] = encode_dict
  @encode_func[NilClass] = encode_none
  @encode_func[TrueClass] = encode_bool
  @encode_func[FalseClass] = encode_bool
  @encode_func[Float] = encode_float32
  # @encode_func[Float] = encode_float64

  def self.dump(x)
    r = []
    @encode_func[x.class].call(x, r)
    r.join
  end

end
