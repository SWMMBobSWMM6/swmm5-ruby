# frozen_string_literal: false
# libmcheck.rb - check the math the Ruby port computes against the system libm (the library EPA calls), bit for
# bit, NaN signs and payloads included. Reads vector files in the format of tools/libm/test/mkvectors.c
# (name\0, n:u32, n x (args..., result) as raw little-endian doubles) and evaluates each function the way the
# generated engine does: ::Math.exp/sin/cos/tan/atan directly, c_log, c_log10, c_asin, c_acos, c_sqrt, c_floor,
# c_ceil, Float#abs, and pow both as c_pow(x, y) and in the inline form (x < 0.0 ? c_powneg(x, y) : x ** y).
#   ruby/test/run_libm_tests.sh
# Written by Claude (Anthropic) for Robert Dickinson; see ../README.md.
require_relative '../swmm5/crt'
include CRT

FUNCS = {
  'exp' => ->(a) { ::Math.exp(a[0]) }, 'sin' => ->(a) { ::Math.sin(a[0]) }, 'cos' => ->(a) { ::Math.cos(a[0]) },
  'tan' => ->(a) { ::Math.tan(a[0]) }, 'atan' => ->(a) { ::Math.atan(a[0]) }, 'log' => ->(a) { c_log(a[0]) },
  'log10' => ->(a) { c_log10(a[0]) }, 'asin' => ->(a) { c_asin(a[0]) }, 'acos' => ->(a) { c_acos(a[0]) },
  'sqrt' => ->(a) { c_sqrt(a[0]) }, 'floor' => ->(a) { c_floor(a[0]) }, 'ceil' => ->(a) { c_ceil(a[0]) },
  'fabs' => ->(a) { a[0].abs },
  'pow' => ->(a) { x = a[0]; y = a[1]; r1 = c_pow(x, y); r2 = (x < 0.0 ? c_powneg(x, y) : x ** y)
                   [r1].pack('E') == [r2].pack('E') ? r1 : :inline_differs }
}.freeze
NARGS = Hash.new(1).merge('pow' => 2, 'fma' => 3)

total = bad = nanbad = 0
data = File.binread(ARGV[0])
pos = 0
while pos < data.bytesize
  z = data.index("\0", pos)
  name = data.byteslice(pos, z - pos)
  n = data.byteslice(z + 1, 4).unpack1('L<')
  pos = z + 5
  k = NARGS[name] + 1
  vals = data.byteslice(pos, n * k * 8).unpack('E*')
  pos += n * k * 8
  f = FUNCS[name]
  if f.nil?
    puts "#{name}: #{n} vectors, not used by the Ruby port (skipped)"
    next
  end
  nb = nn = 0
  shown = 0
  n.times do |j|
    a = vals[j * k, k]
    want = a[k - 1]
    begin
      got = f.call(a)
    rescue StandardError => e
      got = e
    end
    next if got.is_a?(Float) && [got].pack('E') == [want].pack('E')
    nb += 1
    nn += 1 if got.is_a?(Float) && got.nan? && want.nan?
    if shown < 5
      shown += 1
      fmt = ->(x) { x.is_a?(Float) ? format('%.17g(%016x)', x, [x].pack('E').unpack1('Q<')) : x.inspect }
      $stderr.puts "  #{name}(#{a[0, k - 1].map { |x| fmt.(x) }.join(', ')}) = #{fmt.(want)}  ruby: #{fmt.(got)}"
    end
  end
  puts "#{name}: #{n} vectors, #{nb} differ (#{nn} of them only in a NaN's sign or payload)"
  total += n
  bad += nb
  nanbad += nn
end
puts "#{bad} of #{total} differ"
