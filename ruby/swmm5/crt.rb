# frozen_string_literal: false
# C runtime layer for the Ruby port of EPA SWMM 5.2.4 (module CRT, included by the generated engine).
#
# Reproduces the C library behaviour SWMM's output depends on, where Ruby's own differs:
#   - printf: MRI's Kernel#format (BSD vfprintf, David Gay's dtoa) is not correctly rounded for %f, so the digits of
#     %f %e %g come from exact integer arithmetic here (fmt_float); Kernel#format is used only for %d and %x
#     (with C's unsigned reading of negative numbers); nan/inf, %c and %s are written here
#   - strtod, atof, atoi, sscanf: our own scanner and an exactly rounded decimal-to-binary conversion, not
#     String#to_f (which accepts '_' and is not glibc's strtod on every input)
#   - libm: Math.sqrt/log/log10/asin/acos raise Math::DomainError where C returns a NaN, Math.sqrt(-0.0) is +0.0,
#     Float#** returns a Complex for a negative base and a non-integral exponent, Float#floor returns an Integer;
#     these wrappers return C's values and otherwise call the same glibc routine EPA calls (test/libmcheck.rb)
#   - 0.0 / 0.0: MRI returns nan("") (sign bit clear); x86 returns the default NaN (sign bit set, "-nan")
#   - double -> int: x86's cvttsd2si (NaN and out of range give INT_MIN); float: IEEE single rounding as C's cast
#   - char*: CPtr, a binary String plus an offset; signed chars as on x86
# Written by Claude (Anthropic) for Robert Dickinson; see ruby/README.md.

module CRT
  INF = Float::INFINITY
  NEG_NAN = [0xFFF8000000000000].pack('Q<').unpack1('E')    # x86 default NaN: glibc prints "-nan"
  POS_NAN = [0x7FF8000000000000].pack('Q<').unpack1('E')    # glibc's NAN macro: "nan"
  FLT_MAX = 3.4028234663852886e38
  FLT_OVF = 3.4028235677973366e38                            # 2**128 - 2**103: from here a double rounds to inf

  # ------------------------------------------------------------------- pointers and references
  class CPtr
    attr_accessor :b, :o

    def initialize(b, o = 0)
      @b = b
      @o = o
    end

    def [](i)
      v = @b.getbyte(@o + i)
      v > 127 ? v - 256 : v
    end

    def []=(i, v)
      @b.setbyte(@o + i, v & 255)
    end

    def +(n)
      CPtr.new(@b, @o + n)
    end

    def -(n)
      n.is_a?(CPtr) ? @o - n.o : CPtr.new(@b, @o - n)
    end

    def ==(x)
      x.is_a?(CPtr) && x.b.equal?(@b) && x.o == @o
    end

    def !=(x)
      !(self == x)
    end

    def <(x) = @o < x.o
    def >(x) = @o > x.o
    def <=(x) = @o <= x.o
    def >=(x) = @o >= x.o

    def copy
      CPtr.new(@b.dup, @o)
    end

    def self.buf(n)
      n = n.to_i
      CPtr.new("\0".b * (n > 0 ? n : 1), 0)
    end

    def self.buf_from(src, n)
      p = buf(n)
      s = CRT.bytes_of(src)
      s = s.byteslice(0, n) if s.bytesize > n
      p.b.bytesplice(0, s.bytesize, s)
      p
    end

    def inspect
      "CPtr(#{CRT.bytes_of(self).inspect})"
    end
  end

  class Box
    attr_accessor :v

    def initialize(v)
      @v = v
    end
  end

  SETTER = Hash.new { |h, k| h[k] = :"#{k}=" }

  class FieldRef
    def initialize(o, g)
      @o = o
      @g = g
      @s = SETTER[g]
    end

    def v
      @o.__send__(@g)
    end

    def v=(x)
      @o.__send__(@s, x)
    end
  end

  class ElemRef
    def initialize(a, i)
      @a = a
      @i = i
    end

    def v
      @a[@i]
    end

    def v=(x)
      @a[@i] = x
    end
  end

  class GlobalRef
    def initialize(name)
      @n = name.to_s
    end

    def v
      eval(@n)
    end

    def v=(x)
      __gref_value = x
      eval("#{@n} = __gref_value")
    end
  end

  def self.bytes_of(p)
    b = p.b
    e = b.byteindex("\0", p.o)
    b.byteslice(p.o, (e || b.bytesize) - p.o)
  end

  def lit(s)
    CPtr.new((s + "\0").b, 0)
  end

  def bytes_of(p) = CRT.bytes_of(p)

  def fieldref(o, g) = FieldRef.new(o, g)

  def cptr_diff(a, b) = a.o - b.o

  def rec_init(o, *kv)
    kv.each_slice(2) { |k, v| o.__send__(SETTER[k], v) }
    o
  end

  # ------------------------------------------------------------------- arithmetic with C semantics
  # C (int)x on x86-64 (cvttsd2si): NaN or out of range gives INT_MIN
  def d2i(x)
    (x < 2147483648.0 && x > -2147483649.0) ? x.to_i : -2147483648
  end

  def d2l(x)
    (x < 9223372036854775808.0 && x >= -9223372036854775808.0) ? x.to_i : -9223372036854775808
  end

  def i32(x)
    x &= 0xFFFFFFFF
    x >= 0x80000000 ? x - 0x100000000 : x
  end

  def i64(x)
    x &= 0xFFFFFFFFFFFFFFFF
    x >= 0x8000000000000000 ? x - 0x10000000000000000 : x
  end

  # C's (float)x: MRI's pack('f') turns every NaN into +NaN and rounds what lies above FLT_MAX to infinity
  # (VALUE_to_float in pack.c); cvtsd2ss keeps a NaN's sign and rounds to nearest
  def f32(x)
    if x.abs <= FLT_MAX
      [x].pack('f').unpack1('f')
    elsif x.nan?
      b = [x].pack('E').unpack1('Q<')
      [(b & 0xFFFFFFFFE0000000) | 0x0008000000000000].pack('Q<').unpack1('E')
    elsif x.abs >= FLT_OVF
      x > 0 ? INF : -INF
    else
      x > 0 ? FLT_MAX : -FLT_MAX
    end
  end

  # C integer division truncates; Ruby's floors
  def idiv(a, b)
    q = a / b
    (q < 0 && q * b != a) ? q + 1 : q
  end

  # double division whose divisor may be zero: MRI's Float#/ gives nan("") for 0/0, x86 the default NaN
  def fdiv(a, b)
    b == 0.0 ? fdiv0(a, b) : a / b
  end

  def fdiv0(a, b)
    return a if a.nan?
    return NEG_NAN if a == 0.0
    a / b                                 # MRI: a * (signbit(b) ? -1 : 1) * HUGE_VAL, C's signed infinity
  end

  def arr1(ref, f)
    a = [ref.v]
    r = f.call(a)
    ref.v = a[0]
    r
  end

  def chr1(ref, f)
    p = CPtr.buf(2)
    p[0] = ref.v
    r = f.call(p)
    ref.v = p[0]
    r
  end

  # ------------------------------------------------------------------- math.h
  # MRI's Math functions call glibc (libruby imports exp@GLIBC_2.29, log@GLIBC_2.29, pow@GLIBC_2.29, sin, cos,
  # tan, asin, acos, atan, log10, sqrt: the symbols EPA imports); what they add is checked and undone here.
  def c_sqrt(x)
    x > 0.0 ? Math.sqrt(x) : CRT.sqrt0(x)
  end

  def self.sqrt0(x)
    return x if x == 0.0                  # sqrt(-0.0) is -0.0 in C, +0.0 from Math.sqrt
    return x + x if x.nan?                # a NaN comes back quiet (x + x sets the quiet bit, as the hardware does)
    NEG_NAN                               # sqrtsd of a negative number: the default NaN
  end

  def c_floor(x)
    return (x.nan? ? x + x : x) unless x.abs < 4503599627370496.0   # |x| >= 2**52, inf: already integral
    return x if x == 0.0
    x.floor.to_f
  end

  def c_ceil(x)
    return (x.nan? ? x + x : x) unless x.abs < 4503599627370496.0
    return x if x == 0.0
    r = x.ceil.to_f
    r == 0.0 ? -0.0 : r                   # -1 < x < 0: C's ceil gives -0.0
  end

  def c_log(x)
    x > 0.0 ? Math.log(x) : CRT.log0(x)
  end

  def self.log0(x)
    return -INF if x == 0.0
    return x + x if x.nan?
    NEG_NAN                               # glibc __math_invalid: (x - x) / (x - x)
  end

  def c_log10(x)
    x > 0.0 ? Math.log10(x) : CRT.log100(x)
  end

  def self.log100(x)
    return -INF if x == 0.0
    return x + x if x.nan?
    POS_NAN                               # glibc's x86-64 log10 is the SVID wrapper: __kernel_standard's NAN
  end

  def c_asin(x)
    (x <= 1.0 && x >= -1.0) ? Math.asin(x) : (x.nan? ? x + x : POS_NAN)
  end

  def c_acos(x)
    (x <= 1.0 && x >= -1.0) ? Math.acos(x) : (x.nan? ? x + x : POS_NAN)
  end

  def c_pow(x, y)
    x < 0.0 ? c_powneg(x, y) : x ** y
  end

  # pow with a negative base. MRI's rb_float_pow calls pow(x, y) unless y is NaN or a finite non-integer, where
  # it builds a Complex; glibc returns x + y for a NaN y, +inf or +0 for x = -inf, and the default NaN otherwise
  def c_powneg(x, y)
    return x + y if y.nan?
    return x ** y if y.infinite? || y == y.floor
    return (y > 0.0 ? INF : 0.0) if x == -INF
    NEG_NAN
  end

  # ------------------------------------------------------------------- memory
  def c_memset(a, v, n)
    if a.is_a?(CPtr)
      n.to_i.times { |i| a.b.setbyte(a.o + i, v & 255) }
    else
      cnt = n.to_i / 8
      cnt = a.size if cnt > a.size
      cnt.times { |i| a[i] = a[i].is_a?(Float) ? 0.0 : 0 }
    end
    nil
  end

  def realloc_(a, n)
    n = n.to_i
    return ::Array.new(n) if a.nil?
    if a.is_a?(CPtr)
      p = CPtr.buf(n)
      m = [n, a.b.bytesize - a.o].min
      p.b.bytesplice(0, m, a.b.byteslice(a.o, m))
      return p
    end
    return a[0, n] if n <= a.size
    if !a.empty? && a[0].respond_to?(:copy) && !a[0].is_a?(CPtr)
      return a + ::Array.new(n - a.size) { a[0].class.new }
    end
    fill = a.empty? ? nil : (a[0].is_a?(Float) ? 0.0 : (a[0].is_a?(Integer) ? 0 : nil))
    a + ::Array.new(n - a.size, fill)
  end

  # ------------------------------------------------------------------- strings
  def c_strlen(p)
    p.b.byteindex("\0", p.o) - p.o
  end

  def c_strcpy(d, s)
    src = s.b.byteslice(s.o, s.b.byteindex("\0", s.o) - s.o + 1)
    d.b.bytesplice(d.o, src.bytesize, src)
    d
  end

  def c_strcat(d, s)
    c_strcpy(d + c_strlen(d), s)
    d
  end

  def c_strcmp(a, b)
    x = bytes_of(a)
    y = bytes_of(b)
    n = x.bytesize < y.bytesize ? x.bytesize : y.bytesize
    i = 0
    while i < n
      d = x.getbyte(i) - y.getbyte(i)
      return d if d != 0
      i += 1
    end
    return 0 if x.bytesize == y.bytesize
    x.bytesize > y.bytesize ? x.getbyte(n) : -y.getbyte(n)
  end

  def c_strchr(s, c)
    c &= 255
    b = s.b
    i = s.o
    loop do
      ch = b.getbyte(i)
      return CPtr.new(b, i) if ch == c
      return nil if ch == 0
      i += 1
    end
  end

  def c_strrchr(s, c)
    c &= 255
    e = s.b.byteindex("\0", s.o)
    return CPtr.new(s.b, e) if c == 0
    i = e - 1
    while i >= s.o
      return CPtr.new(s.b, i) if s.b.getbyte(i) == c
      i -= 1
    end
    nil
  end

  def c_strstr(h, n)
    hb = bytes_of(h)
    i = hb.byteindex(bytes_of(n))
    i ? CPtr.new(h.b, h.o + i) : nil
  end

  def c_strcspn(s, rej)
    sb = bytes_of(s)
    rb = bytes_of(rej).bytes
    sb.each_byte.with_index { |ch, i| return i if rb.include?(ch) }
    sb.bytesize
  end

  @tok_next = nil
  class << self
    attr_accessor :tok_next
  end

  def c_strtok(s, delim)
    CRT.tok_next = s unless s.nil?
    p = CRT.tok_next
    return nil if p.nil?
    ds = bytes_of(delim).bytes
    b = p.b
    i = p.o
    i += 1 while b.getbyte(i) != 0 && ds.include?(b.getbyte(i))
    if b.getbyte(i) == 0
      CRT.tok_next = nil
      return nil
    end
    start = i
    i += 1 while b.getbyte(i) != 0 && !ds.include?(b.getbyte(i))
    if b.getbyte(i) != 0
      b.setbyte(i, 0)
      CRT.tok_next = CPtr.new(b, i + 1)
    else
      CRT.tok_next = nil
    end
    CPtr.new(b, start)
  end

  def c_toupper(c)
    c >= 97 && c <= 122 ? c - 32 : c
  end

  SPACE = [32, 9, 10, 11, 12, 13].freeze

  def self.space?(c)
    c == 32 || (c >= 9 && c <= 13)
  end

  # ------------------------------------------------------------------- strtod
  # Decimal text to the nearest double, ties to even, by exact integer arithmetic (Clinger's fast path when the
  # digits and the power of ten are both exact doubles). Hexadecimal floats, inf, infinity, nan and nan(...) as glibc.
  P10 = (0..22).map { |k| ('1e%d' % k).to_f }.freeze

  def self.to_double(neg, digits, exp10)
    # digits: Integer mantissa (decimal), value = digits * 10**exp10
    v = if digits == 0
          0.0
        elsif digits < 9007199254740992 && exp10.abs <= 22
          exp10 >= 0 ? digits.to_f * P10[exp10] : digits.to_f / P10[-exp10]
        else
          nd = digits.to_s.size
          if nd + exp10 > 310
            INF
          elsif nd + exp10 < -330
            0.0
          elsif exp10 >= 0
            int_to_double(digits * 10**exp10)
          else
            ratio_to_double(digits, 10**-exp10)
          end
        end
    neg ? -v : v
  end

  def self.int_to_double(n)
    ratio_to_double(n, 1)
  end

  # nearest double to num/den (both positive Integers), round half to even, with gradual underflow
  def self.ratio_to_double(num, den)
    e = num.bit_length - den.bit_length
    e -= 1 if (e >= 0 ? (num >= (den << e)) : ((num << -e) >= den)) == false
    # now 2**e <= num/den < 2**(e+1)
    e = -1074 + 52 if e < -1022             # subnormal: fixed exponent
    sh = 52 - e                              # q = num/den * 2**sh has 53 bits (or fewer when subnormal)
    if sh >= 0
      q, r = (num << sh).divmod(den)
    else
      q, r = num.divmod(den << -sh)
      den <<= -sh
    end
    r2 = r * 2
    q += 1 if r2 > den || (r2 == den && q.odd?)
    Math.ldexp(q.to_f, -sh)                  # q <= 2**53 is exact; ldexp only scales (inf past DBL_MAX)
  end

  def self.nan_payload(seq)
    v = case seq
        when '' then 0
        when /\A0[xX][0-9a-fA-F]+\z/ then seq[2..].to_i(16)
        when /\A0[0-7]*\z/ then seq.to_i(8)
        when /\A[1-9][0-9]*\z/ then seq.to_i(10)
        end
    return nil if v.nil?
    v > 0xFFFFFFFFFFFFFFFF ? 0xFFFFFFFFFFFFFFFF : v
  end

  # parse a C floating number at b[i..] (at most lim bytes from i); returns [value, end] or [0.0, nil]
  def self.scan_double(b, i, maxw)
    n = b.bytesize
    lim = maxw.nil? ? n : [i + maxw, n].min
    g = ->(k) { k < lim ? b.getbyte(k) : 0 }
    neg = false
    c = g.(i)
    if c == 43 || c == 45
      neg = c == 45
      i += 1
    end
    low = ->(k) { x = g.(k); x >= 65 && x <= 90 ? x | 0x20 : x }
    if low.(i) == 105 && low.(i + 1) == 110 && low.(i + 2) == 102
      i += 3
      i += 5 if (0..4).all? { |k| low.(i + k) == 'inity'.getbyte(k) }
      return [neg ? -INF : INF, i]
    end
    if low.(i) == 110 && low.(i + 1) == 97 && low.(i + 2) == 110
      i += 3
      v = POS_NAN
      if g.(i) == 40
        k = i + 1
        k += 1 while (x = g.(k)) && ((x >= 48 && x <= 57) || ((x | 0x20) >= 97 && (x | 0x20) <= 122) || x == 95)
        if g.(k) == 41
          # glibc reads the n-char-sequence with strtoull(seq, 0) and keeps it as the payload
          pl = nan_payload(b.byteslice(i + 1, k - i - 1))
          v = [0x7FF8000000000000 | (pl & 0x7FFFFFFFFFFFF)].pack('Q<').unpack1('E') unless pl.nil?
          i = k + 1
        end
      end
      return [neg ? -v : v, i]
    end
    if g.(i) == 48 && (g.(i + 1) | 0x20) == 120
      r = scan_hex(g, i + 2, neg)
      return r if r
      return [neg ? -0.0 : 0.0, i + 1]      # "0x" with no hex digits: the "0" is the number
    end
    digits = 0
    nd = 0
    exp10 = 0
    any = false
    while (c = g.(i)) >= 48 && c <= 57
      digits = digits * 10 + (c - 48)
      any = true
      i += 1
    end
    if g.(i) == 46
      i += 1
      while (c = g.(i)) >= 48 && c <= 57
        digits = digits * 10 + (c - 48)
        exp10 -= 1
        any = true
        i += 1
      end
    end
    return [0.0, nil] unless any
    if (g.(i) | 0x20) == 101
      k = i + 1
      es = 1
      if g.(k) == 43 || g.(k) == 45
        es = -1 if g.(k) == 45
        k += 1
      end
      if (c = g.(k)) >= 48 && c <= 57
        ev = 0
        while (c = g.(k)) >= 48 && c <= 57
          ev = ev * 10 + (c - 48) if ev < 100000
          k += 1
        end
        exp10 += es * ev
        i = k
      end
    end
    [to_double(neg, digits, exp10), i]
  end

  def self.hexval(c)
    return c - 48 if c >= 48 && c <= 57
    c |= 0x20
    return c - 87 if c >= 97 && c <= 102
    nil
  end

  def self.scan_hex(g, i, neg)
    m = 0
    e2 = 0
    any = false
    while (h = hexval(g.(i)))
      m = (m << 4) | h
      any = true
      i += 1
    end
    if g.(i) == 46
      i += 1
      while (h = hexval(g.(i)))
        m = (m << 4) | h
        e2 -= 4
        any = true
        i += 1
      end
    end
    return nil unless any
    if (g.(i) | 0x20) == 112
      k = i + 1
      es = 1
      if g.(k) == 43 || g.(k) == 45
        es = -1 if g.(k) == 45
        k += 1
      end
      if (c = g.(k)) >= 48 && c <= 57
        ev = 0
        while (c = g.(k)) >= 48 && c <= 57
          ev = ev * 10 + (c - 48) if ev < 100000
          k += 1
        end
        e2 += es * ev
        i = k
      end
    end
    v = if m == 0
          0.0
        elsif e2 >= 0
          e2 > 2000 ? INF : int_to_double(m << e2)
        else
          e2 < -2200 ? 0.0 : ratio_to_double(m, 1 << -e2)
        end
    [neg ? -v : v, i]
  end

  def c_strtod(s, endref)
    b = s.b
    i = s.o
    i += 1 while CRT.space?(b.getbyte(i))
    v, e = CRT.scan_double(b, i, nil)
    endref.v = (e.nil? ? s : CPtr.new(b, e)) unless endref.nil?
    e.nil? ? 0.0 : v
  end

  def c_atof(s)
    c_strtod(s, nil)
  end

  def c_atoi(s)
    b = s.b
    i = s.o
    i += 1 while CRT.space?(b.getbyte(i))
    neg = false
    c = b.getbyte(i)
    if c == 43 || c == 45
      neg = c == 45
      i += 1
    end
    v = 0
    while (c = b.getbyte(i)) >= 48 && c <= 57
      v = v * 10 + c - 48
      i += 1
    end
    v = -v if neg
    v = 9223372036854775807 if v > 9223372036854775807
    v = -9223372036854775808 if v < -9223372036854775808
    i32(v)
  end

  # ------------------------------------------------------------------- sscanf
  def c_sscanf(s, fmt, *args)
    b = s.b
    i = s.o
    f = bytes_of(fmt)
    k = 0
    ai = 0
    count = 0
    any_input = false
    n = b.bytesize
    nf = f.bytesize
    ch = ->(j) { j < n ? b.getbyte(j) : 0 }
    while k < nf
      fc = f.getbyte(k)
      if CRT.space?(fc)
        k += 1 while k < nf && CRT.space?(f.getbyte(k))
        i += 1 while ch.(i) != 0 && CRT.space?(ch.(i))
        next
      end
      if fc != 37
        return (any_input || count > 0) ? count : -1 if ch.(i) == 0
        return count if ch.(i) != fc
        i += 1
        k += 1
        next
      end
      k += 1
      if f.getbyte(k) == 37
        i += 1 while ch.(i) != 0 && CRT.space?(ch.(i))
        return count if ch.(i) != 37
        i += 1
        k += 1
        next
      end
      suppress = false
      if f.getbyte(k) == 42
        suppress = true
        k += 1
      end
      width = 0
      while (x = f.getbyte(k)) >= 48 && x <= 57
        width = width * 10 + x - 48
        k += 1
      end
      lmod = 0
      while (x = f.getbyte(k)) == 108 || x == 104 || x == 76
        lmod += 1 if x == 108
        k += 1
      end
      conv = f.getbyte(k)
      k += 1
      i += 1 while ch.(i) != 0 && CRT.space?(ch.(i)) if conv != 99 && conv != 91 && conv != 110
      if ch.(i) == 0 && conv != 110
        return (count == 0 && !any_input) ? -1 : count
      end
      case conv
      when 100, 105, 117                      # d i u
        j = i
        lim = width > 0 ? i + width : n
        neg = false
        if j < lim && (ch.(j) == 43 || ch.(j) == 45)
          neg = ch.(j) == 45
          j += 1
        end
        ds = j
        v = 0
        while j < lim && (x = ch.(j)) >= 48 && x <= 57
          v = v * 10 + x - 48
          j += 1
        end
        return count if j == ds
        i = j
        any_input = true
        v = -v if neg
        unless suppress
          a = args[ai]
          ai += 1
          v = 9223372036854775807 if v > 9223372036854775807
          v = -9223372036854775808 if v < -9223372036854775808
          a[1].v = lmod > 0 ? v : i32(v)
          count += 1
        end
      when 102, 101, 103                      # f e g
        v, e = CRT.scan_double(b, i, width > 0 ? width : nil)
        return count if e.nil?
        i = e
        any_input = true
        unless suppress
          a = args[ai]
          ai += 1
          a[1].v = (lmod > 0 || a[0] == :d) ? v : f32(v)
          count += 1
        end
      when 115                                # s
        j = i
        w = width > 0 ? width : (1 << 30)
        st = j
        j += 1 while ch.(j) != 0 && !CRT.space?(ch.(j)) && j - st < w
        unless suppress
          d = args[ai]
          ai += 1
          src = b.byteslice(st, j - st) + "\0"
          d.b.bytesplice(d.o, src.bytesize, src)
          count += 1
        end
        i = j
        any_input = true
      when 99                                 # c
        cnt = width > 0 ? width : 1
        return (count == 0 && !any_input) ? -1 : count if ch.(i) == 0
        a = suppress ? nil : args[ai]
        ai += 1 unless suppress
        t = 0
        while t < cnt && ch.(i) != 0
          unless suppress
            if a.is_a?(CPtr)
              a.b.setbyte(a.o + t, ch.(i))
            else
              c = ch.(i)
              a[1].v = c > 127 ? c - 256 : c
            end
          end
          i += 1
          t += 1
        end
        any_input = true
        count += 1 unless suppress
      else
        raise NotImplementedError, "sscanf %#{conv.chr}"
      end
    end
    count
  end

  # ------------------------------------------------------------------- printf family
  # A parsed format: [[:lit, bytes] | [:spec, flags, width, prec, conv, rubyspec]]
  FMT_CACHE = {}

  def self.parse_fmt(fb)
    parts = []
    i = 0
    n = fb.bytesize
    lit_start = 0
    while i < n
      if fb.getbyte(i) != 37
        i += 1
        next
      end
      if i + 1 < n && fb.getbyte(i + 1) == 37
        parts << [:lit, fb.byteslice(lit_start, i - lit_start) + '%']
        i += 2
        lit_start = i
        next
      end
      parts << [:lit, fb.byteslice(lit_start, i - lit_start)] if i > lit_start
      j = i + 1
      flags = ''
      while j < n && '-+ #0'.include?(fb.getbyte(j).chr)
        flags << fb.getbyte(j).chr
        j += 1
      end
      width = ''
      if j < n && fb.getbyte(j) == 42
        width = '*'
        j += 1
      else
        while j < n && fb.getbyte(j) >= 48 && fb.getbyte(j) <= 57
          width << fb.getbyte(j).chr
          j += 1
        end
      end
      prec = nil
      if j < n && fb.getbyte(j) == 46
        j += 1
        prec = ''
        if j < n && fb.getbyte(j) == 42
          prec = '*'
          j += 1
        else
          while j < n && fb.getbyte(j) >= 48 && fb.getbyte(j) <= 57
            prec << fb.getbyte(j).chr
            j += 1
          end
        end
      end
      lm = ''
      while j < n && 'hlLqjzt'.include?(fb.getbyte(j).chr)
        lm << fb.getbyte(j).chr
        j += 1
      end
      conv = j < n ? fb.getbyte(j).chr : ''
      parts << [:spec, flags, width, prec, conv, lm]
      i = j + 1
      lit_start = i
    end
    parts << [:lit, fb.byteslice(lit_start, n - lit_start)] if lit_start < n
    parts.each { |p| p[1] = p[1].b if p[0] == :lit }
    parts
  end

  # ------------------------------------------------------------------- exact %f %e %g
  # MRI's Kernel#format is not correctly rounded (format('%.1f', 36.15) gives "36.2"; glibc, which prints the
  # exact binary value, gives "36.1"; test/crtcheck.rb found 11,553 such cases), so the digits come from exact
  # integer arithmetic: x = m * 2**e, and round(x * 10**s) with ties to even, as glibc does.
  P10I = (0..400).map { |k| 10**k }.freeze

  def self.pow10i(k) = k <= 400 ? P10I[k] : 10**k

  # [m, e] with |x| = m * 2**e (x finite, nonzero)
  def self.decompose(x)
    b = [x].pack('E').unpack1('Q<')
    be = (b >> 52) & 0x7FF
    m = b & 0xFFFFFFFFFFFFF
    if be == 0
      [m, -1074]
    else
      [m | 0x10000000000000, be - 1075]
    end
  end

  # round(m * 2**e * 10**s), ties to even
  def self.scaled_round(m, e, s)
    num = m
    den = 1
    if s >= 0
      num *= pow10i(s)
    else
      den = pow10i(-s)
    end
    if e >= 0
      num <<= e
    else
      den <<= -e
    end
    q, r = num.divmod(den)
    r2 = r << 1
    q += 1 if r2 > den || (r2 == den && q.odd?)
    q
  end

  # decimal exponent E with 10**E <= m * 2**e < 10**(E+1)
  def self.dec_exp(x, m, e)
    k = Math.log10(x).floor
    k -= 1 while cmp_pow10(m, e, k) < 0
    k += 1 while cmp_pow10(m, e, k + 1) >= 0
    k
  end

  def self.cmp_pow10(m, e, k)
    a = m
    b = 1
    if e >= 0 then a <<= e else b <<= -e end
    if k >= 0 then b *= pow10i(k) else a *= pow10i(-k) end
    a <=> b
  end

  # digits of |x| (finite) for %f with precision p: [integer part, fraction] as strings
  def self.f_digits(x, p)
    return ['0', '0' * p] if x == 0.0
    m, e = decompose(x)
    s = scaled_round(m, e, p).to_s
    s = '0' * (p + 1 - s.size) + s if s.size < p + 1
    [s[0, s.size - p], s[s.size - p, p]]
  end

  # digits of |x| (finite) for %e with precision p: [digit string of p+1 digits, decimal exponent]
  def self.e_digits(x, p)
    return ['0' * (p + 1), 0] if x == 0.0
    ax = x.abs
    m, e = decompose(ax)
    k = dec_exp(ax, m, e)
    q = scaled_round(m, e, p - k)
    if q >= pow10i(p + 1)
      k += 1
      q = pow10i(p)
    end
    [q.to_s, k]
  end

  def self.exp_str(k, upper)
    (upper ? 'E' : 'e') + (k < 0 ? '-' : '+') + (k.abs < 10 ? '0' : '') + k.abs.to_s
  end

  # one floating conversion, exactly as glibc's printf writes it
  def self.fmt_float(x, flags, width, prec, conv)
    neg = [x].pack('E').getbyte(7) >= 128
    left = flags.include?('-')
    sign = neg ? '-' : (flags.include?('+') ? '+' : (flags.include?(' ') ? ' ' : ''))
    upper = conv == 'E' || conv == 'G' || conv == 'F'
    alt = flags.include?('#')
    unless x.finite?
      body = x.nan? ? 'nan' : 'inf'
      body = body.upcase if upper
      return pad((sign + body).b, width, left)
    end
    p = prec.nil? ? 6 : prec.to_i
    ax = x.abs
    case conv
    when 'f', 'F'
      ip, fp = f_digits(ax, p)
      body = p > 0 ? ip + '.' + fp : (alt ? ip + '.' : ip)
    when 'e', 'E'
      d, k = e_digits(ax, p)
      body = d[0] + (p > 0 || alt ? '.' : '') + d[1..] + exp_str(k, upper)
    else                                      # g, G
      pp = p == 0 ? 1 : p
      d, k = e_digits(ax, pp - 1)
      if pp > k && k >= -4
        ip, fp = f_digits(ax, pp - 1 - k)
        fp = fp.sub(/0+\z/, '') unless alt
        body = fp.empty? && !alt ? ip : ip + '.' + fp
      else
        fr = d[1..]
        fr = fr.sub(/0+\z/, '') unless alt
        body = d[0] + (fr.empty? && !alt ? '' : '.') + fr + exp_str(k, upper)
      end
    end
    w = width.to_i
    if flags.include?('0') && !left && sign.size + body.size < w
      body = '0' * (w - sign.size - body.size) + body
    end
    pad((sign + body).b, width, left)
  end

  def self.pad(s, width, left)
    w = width.to_i
    return s if s.bytesize >= w
    left ? s + ' ' * (w - s.bytesize) : ' ' * (w - s.bytesize) + s
  end

  def self.format_c(fmt, args)
    fb = CRT.bytes_of(fmt)
    ent = FMT_CACHE[fb]
    if ent.nil?
      ent = parse_fmt(fb)
      FMT_CACHE[fb.dup.freeze] = ent
    end
    out = ''.b
    ai = 0
    ent.each do |p|
      if p[0] == :lit
        out << p[1]
        next
      end
      _, flags, width, prec, conv, lm = p
      if width == '*'
        w = args[ai]
        ai += 1
        if w < 0
          flags += '-'
          w = -w
        end
        width = w.to_s
      end
      if prec == '*'
        pr = args[ai]
        ai += 1
        prec = pr >= 0 ? pr.to_s : nil
      end
      a = args[ai]
      ai += 1
      case conv
      when 's'
        sv = a.nil? ? '(null)'.b : CRT.bytes_of(a)
        sv = sv.byteslice(0, prec.to_i) unless prec.nil?
        out << pad(sv, width, flags.include?('-'))
      when 'c'
        out << pad((a & 255).chr.b, width, flags.include?('-'))
      when 'f', 'F', 'e', 'E', 'g', 'G'
        out << fmt_float(a.to_f, flags, width, prec, conv)
      when 'd', 'i'
        a = a.to_i
        out << Kernel.format("%#{flags}#{width}#{prec.nil? ? '' : '.' + (prec.empty? ? '0' : prec)}d", a).b
      when 'u', 'x', 'X', 'o'
        a = a.to_i
        a &= (lm.include?('l') || lm.include?('j') || lm.include?('z') || lm.include?('q')) ? 0xFFFFFFFFFFFFFFFF : 0xFFFFFFFF
        out << Kernel.format("%#{flags}#{width}#{prec.nil? ? '' : '.' + (prec.empty? ? '0' : prec)}#{conv == 'u' ? 'd' : conv}", a).b
      else
        raise NotImplementedError, "printf %#{conv}"
      end
    end
    out
  end

  def c_fprintf(f, fmt, *args)
    b = CRT.format_c(fmt, args)
    return -1 if f.nil?
    f.write(b)
    b.bytesize
  end

  def c_snprintf(buf, n, fmt, *args)
    b = CRT.format_c(fmt, args)
    n = n.to_i
    if n > 0
      m = b.bytesize < n - 1 ? b.bytesize : n - 1
      buf.b.bytesplice(buf.o, m + 1, b.byteslice(0, m) + "\0")
    end
    b.bytesize
  end

  # ------------------------------------------------------------------- files
  class CFile
    attr_accessor :f, :eof, :std

    def initialize(f, std = false)
      @f = f
      @eof = false
      @std = std
    end

    def write(b)
      @f.write(b)
    end
  end

  C_STDOUT = CFile.new($stdout, true)
  C_STDERR = CFile.new($stderr, true)

  def c_fopen(name, mode)
    fn = CRT.bytes_of(name)
    m = CRT.bytes_of(mode).delete('t')
    m += 'b' unless m.include?('b')
    begin
      CFile.new(File.open(fn, m))
    rescue SystemCallError, IOError
      nil
    end
  end

  def c_fclose(f)
    return -1 if f.nil?
    if f.std
      f.f.flush
    else
      f.f.close
    end
    0
  end

  def c_fflush(f)
    f.f.flush unless f.nil?
    0
  end

  def c_feof(f)
    f.eof ? 1 : 0
  end

  def c_rewind(f)
    f.f.rewind
    f.eof = false
    nil
  end

  def c_fseek(f, off, whence)
    f.f.seek(off, whence)
    f.eof = false
    0
  rescue SystemCallError
    -1
  end

  def c_ftell(f)
    f.f.pos
  end

  def c_fgets(buf, n, f)
    line = f.f.gets("\n", n - 1)
    if line.nil?
      f.eof = true
      return nil
    end
    f.eof = true if line.bytesize < n - 1 && line.getbyte(-1) != 10
    line = line.b
    buf.b.bytesplice(buf.o, line.bytesize + 1, line + "\0")
    buf
  end

  def c_remove(name)
    File.delete(CRT.bytes_of(name))
    0
  rescue SystemCallError
    -1
  end

  MKS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

  def c_mkstemp(template)
    n = c_strlen(template)
    1000.times do
      (n - 6...n).each { |i| template[i] = MKS.getbyte(rand(MKS.size)) }
      begin
        File.open(CRT.bytes_of(template), File::CREAT | File::EXCL | File::RDWR, 0o600).close
        return 3
      rescue Errno::EEXIST
        next
      end
    end
    -1
  end

  PACK = { d: ['E', 8], f: ['e', 4], i: ['l<', 4], I: ['L<', 4], q: ['q<', 8] }.freeze

  # the 4 bytes C's (float)x stores: MRI's pack('e') turns every NaN into +NaN (VALUE_to_float in pack.c), where
  # cvtsd2ss keeps the sign and the top of the payload (EPA writes -nan into one corpus model's .out)
  def self.float_bytes(x)
    return [x].pack('e') unless x.nan?
    b = [x].pack('E').unpack1('Q<')
    [((b >> 32) & 0x80000000) | 0x7FC00000 | ((b >> 29) & 0x3FFFFF)].pack('L<')
  end

  def c_fwrite1(code, size, v, f)
    if code == :c
      f.f.write((v & 255).chr)
      return 1
    end
    fm, nat = PACK[code]
    b = code == :f ? CRT.float_bytes(v) : [v].pack(fm)
    f.f.write(size == nat ? b : b.byteslice(0, size))
    1
  end

  def c_fread1(code, size, ref, f)
    fm, nat = PACK[code]
    b = f.f.read(size)
    if b.nil? || b.bytesize < size
      f.eof = true
      return 0
    end
    b += [ref.v].pack(fm).byteslice(size, nat - size) if size != nat
    ref.v = b.unpack1(fm)
    1
  end

  def c_fwrite_arr(code, size, arr, off, n, f)
    n = n.to_i
    if code == :c
      f.f.write(arr.b.byteslice(arr.o + off, n))
      return n
    end
    fm, = PACK[code]
    vals = arr[off, n]
    if code == :f && vals.any?(&:nan?)
      f.f.write(vals.map { |x| CRT.float_bytes(x) }.join)
    else
      f.f.write(vals.pack(fm + '*'))
    end
    n
  end

  def c_fread_arr(code, size, arr, off, n, f)
    n = n.to_i
    if code == :c
      b = f.f.read(n) || ''.b
      arr.b.bytesplice(arr.o + off, b.bytesize, b)
      f.eof = true if b.bytesize < n
      return b.bytesize
    end
    fm, nat = PACK[code]
    b = f.f.read(n * nat) || ''.b
    m = b.bytesize / nat
    vals = b.byteslice(0, m * nat).unpack(fm + '*')
    m.times { |i| arr[off + i] = vals[i] }
    f.eof = true if m < n
    m
  end

  # ------------------------------------------------------------------- time
  def c_time
    Time.now.to_i
  end

  def c_ctime(t)
    lit(Time.at(t).strftime('%a %b %e %H:%M:%S %Y') + "\n")
  end

  def c_clock
    (Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) * 1_000_000).to_i
  end
end
