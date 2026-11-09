# frozen_string_literal: false
# crtcheck.rb - compare the Ruby port's printf, strtod and sscanf (swmm5/crt.rb) with the system glibc's results
# written by tools/crt/test/mkfmt.c (lines KIND \t FORMAT \t ARG \t RESULT, hex-encoded).
#   ruby/test/run_crtcheck.sh  (builds mkfmt, runs it and this script, prints the summary)
# Written by Claude (Anthropic) for Robert Dickinson; see ruby/README.md.
require_relative '../swmm5/crt'
include CRT

def unhex(s) = [s].pack('H*')
def hexs(b) = b.unpack1('H*')
def dbl(h) = [h.to_i(16)].pack('Q<').unpack1('E')
def bits(x) = [x].pack('E').unpack1('Q<')

names = ['printf %f', 'printf %d', 'printf %ld', 'printf %s', 'strtod', 'sscanf']
total = Array.new(6, 0)
bad = Array.new(6, 0)
shown = 0
out = CPtr.buf(1024)
fcache = {}
File.foreach(ARGV[0], chomp: true) do |line|
  next if line.empty?
  kind, fm, arg, want = line.split("\t", 4)
  f = (fcache[fm] ||= lit(fm.b))
  case kind
  when 'f'
    k = 0
    x = dbl(arg)
    fm == '%*.*f' ? c_snprintf(out, 1024, f, 9, 3, x) : c_snprintf(out, 1024, f, x)
    got = hexs(bytes_of(out))
  when 'i'
    k = 1
    v = i32(arg.to_i(16))
    c_snprintf(out, 1024, f, v)
    got = hexs(bytes_of(out))
  when 'l'
    k = 2
    v = i64(arg.to_i(16))
    c_snprintf(out, 1024, f, v)
    got = hexs(bytes_of(out))
  when 's'
    k = 3
    c_snprintf(out, 1024, f, lit(unhex(arg)))
    got = hexs(bytes_of(out))
  when 'd'
    k = 4
    s = lit(unhex(arg))
    e = Box.new(nil)
    v = c_strtod(s, e)
    got = format('%016x:%d', bits(v), e.v.o - s.o)
  when 'n'
    k = 5
    s = lit(unhex(arg))
    i1 = Box.new(-77)
    d1 = Box.new(-77.0)
    b = CPtr.buf(32)
    b[0] = 63
    n = c_sscanf(s, lit('%d %lf %s'), [:i, i1], [:d, d1], b)
    got = format('%d:%d:%016x:%s', n, i1.v, bits(d1.v), hexs(bytes_of(b)))
  else
    next
  end
  total[k] += 1
  next if got == want
  bad[k] += 1
  if shown < 25
    shown += 1
    $stderr.puts "  #{kind} #{fm} arg=#{arg}  glibc=#{want}  ruby=#{got}"
  end
end
6.times { |k| puts "#{names[k]}: #{total[k]} cases, #{bad[k]} differ" }
puts "#{bad.sum} of #{total.sum} cases differ"
