# frozen_string_literal: false
# runswmm for the Ruby port: same command line and console messages as EPA's run/main.c.
#   ruby ruby/runswmm.rb <input file> <report file> [output file]
# Written by Claude (Anthropic) for Robert Dickinson; see ruby/README.md.
here = File.join(__dir__, 'swmm5')
require File.join(here, 'crt')
require File.join(here, 'engine')
require File.join(here, 'overrides')

def swmm_main(argv)
  version = SWMM5.swmm_getVersion
  v_major = version / 10000
  v_minor = (version - 10000 * v_major) / 1000
  v_release = version - 10000 * v_major - 1000 * v_minor
  out = $stdout
  if argv.empty?
    out.write("\nNot Enough Arguments (See Help --help)\n\n")
  elsif argv.size == 1
    a = argv[0]
    if ['--help', '-h'].include?(a)
      out.write("\n\nSTORMWATER MANAGEMENT MODEL (SWMM) HELP\n\nCOMMANDS:\n\t--help (-h)       SWMM Help\n" \
                "\t--version (-v)    Build Version\n\nRUNNING A SIMULATION:\n" \
                "\t runswmm <input file> <report file> <optional output file>\n\n")
    elsif ['--version', '-v'].include?(a)
      out.write("\n#{v_major}.#{v_minor}.#{v_release}\n\n")
    else
      out.write("\nUnknown Argument (See Help --help)\n\n")
    end
  else
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out.write("\n... EPA SWMM #{v_major}.#{v_minor} (Build #{v_major}.#{v_minor}.#{v_release}) [Ruby port]\n")
    out.flush
    SWMM5.swmm_run(SWMM5.lit(argv[0].b), SWMM5.lit(argv[1].b), SWMM5.lit((argv[2] || '').b))
    out.write(format("\n\n... EPA SWMM completed in %.2f seconds.", Process.clock_gettime(Process::CLOCK_MONOTONIC) - start))
    err = CRT::CPtr.buf(128)
    if SWMM5.swmm_getError(err, 127) > 0
      out.write(" There are errors.\n")
    elsif SWMM5.swmm_getWarnings > 0
      out.write(" There are warnings.\n")
    else
      out.write("\n")
    end
  end
  out.flush
  0
end

exit(swmm_main(ARGV))
