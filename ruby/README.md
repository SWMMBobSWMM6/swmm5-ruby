# swmm5-ruby

EPA SWMM 5.2.4 in Ruby, written by a translator that reads EPA's C, and judged against EPA itself: the binary
`.out` file byte for byte, and the `.rpt` report line for line except the three lines that print the wall clock.

**Result: 478 of the 480 gate models ran, and all 478 are identical to EPA 5.2.4; 2 were not run** (stopped at
the 1800-second limit: `Hydrology/SCANLON.inp` and `EPA/72_H&H_Elements(2).inp`, the two models EPA itself takes
longest on, 34.8 s and 38.6 s). Final gate: runs rb_5 (451 models), rb_6 and rb_7 (the 29 slowest), 8 November
2026; every `.out` byte-identical, every `.rpt` identical except the three clock lines, exit code 0 on every model,
as EPA's. The engine runs at about 70 times EPA's time (median; see Speed).

It is not a new engine and not a wrapper: there is no C in it and it calls no other port. Every number it writes
is EPA 5.2.4's, including the results of EPA's own defects wherever EPA's behaviour is defined
(`lessons/02-epa-defects-found.md`). Ruby replaces Scala among the four new Code Rosetta Stone languages: the
sandbox could not fetch or run a Scala compiler (`lessons/20-use-the-compiler-already-installed.md`), and Bob chose
Ruby, which is installed here and is the scripting language of InfoWorks ICM.

## The parity contract

The same as the earlier ports' (see `go/` or the swmm5-go repository): EPA SWMM 5.2.4 built from the USEPA v5.2.4
tag with gcc 13.3 `-O2` on x86-64 Linux with glibc 2.39 (`ref/Makefile`), on a processor with FMA and AVX2; each
model run in its own folder; pass = `.out` byte-identical (when EPA writes one) and `.rpt` identical after removing
`Analysis begun on`, `Analysis ended on` and `Total elapsed time`, the exit code the same (EPA's command line always
exits 0). When an input error stops EPA before it writes results, the engine must not write a results file either.
Corpus: the 480 gate models of `gate/models_all.tsv` from SWMMBobSWMM6/1729-SWMM5-Models-2030.

## Run

Requires Ruby 3.3 (tested with **Ruby 3.3.6**, `ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [x86_64-linux]`, the
interpreter at `/usr/local/bin/ruby`, built without YJIT) and nothing else: only Ruby's core and standard library,
no gems. There is nothing to build.

```sh
ruby/runswmm model.inp model.rpt model.out          # = ruby --disable-gems ruby/runswmm.rb ...
```

To regenerate the engine: `python3 tools/c2x/emit_ruby.py ruby/swmm5` from the repository root (needs
`pip install libclang==18.1.1` and the clang 18 headers at `/usr/lib/llvm-18/lib/clang/18/include`; about 35 s).

## How it was made

`tools/c2x/front.py` parses EPA's 54 C files with libclang; `tools/c2x/emit_ruby.py` (1,362 lines, built on the
Python back end's analysis in `emit_py.py` and `emit_cs.py`: which locals live in boxes, pointer modes, names)
writes the engine as one module, `ruby/swmm5/engine.rb` (35,616 lines, generated). Hand-written:
`ruby/swmm5/crt.rb` (1,233 lines, the C library pieces SWMM uses), `ruby/swmm5/overrides.rb` (224 lines, ports of
`odesolve.c`, `mempool.c` and six helpers that use pointer arithmetic, as in the Python port) and
`ruby/runswmm.rb` (48 lines, EPA's `run/main.c`). When the port disagreed with EPA, the fix went into the
translator or the runtime, never into the generated file.

The layout is the Python port's: C globals are Ruby globals (`$Node`, `$Link`), structs are classes with
`attr_accessor` fields and a `copy` for C's value assignment, `char*` is a `CPtr` (a binary String and an
offset), a C local whose address is taken lives in a `Box`, and the engine's functions are methods of
`module SWMM5`, which includes the runtime module `CRT`. What Ruby needed that the Python port did not (each in the
emitter's header; `lessons/27-ruby-numbers-are-not-c-numbers.md`):

- **Every conversion written out.** Ruby never turns an Integer into a Float by itself and `1 / 2` is 0, so each
  int-to-double conversion clang records is `.to_f` (literals as `2.0`); C's integer `/` is `idiv` (Ruby's floors)
  and `%` is `Integer#remainder`; unsigned arithmetic is masked to 32 or 64 bits.
- **Truth.** 0 and 0.0 are true in Ruby: every condition is `(x != 0)`, `(x != 0.0)` or `!p.nil?`, and a C
  comparison used as a number is `(c ? 1 : 0)`.
- **0.0 / 0.0.** MRI's `Float#/` returns a NaN with the sign bit clear where x86 returns one with it set (EPA
  prints "-nan"): a division whose divisor is not a nonzero constant is `(b == 0.0 ? fdiv0(a, b) : a / b)`.
- **Names.** A capital first letter makes a Ruby constant: C locals such as `Re` become `_Re`, lower-case enum
  values (`s_TITLE`) become `K_s_TITLE`; keywords and Object/Kernel/Module method names (`end`, `next`, `name`,
  `hash`) get a trailing `_`; C globals are `$` globals.
- **switch.** `case`/`when` with integer literal labels (Ruby dispatches those through a hash) when no case falls
  through; otherwise a one-pass `while true` loop with a fall-through flag, as in the Python port.
- **Speed.** C locals whose address is taken need a Box; a function that cannot be re-entered (no cycle through it
  in the call graph, counting a call through a function pointer as a call to every function whose address is
  taken) gets its boxes once, at load time, instead of one `Box.new` per call: 21 functions lie on such a cycle,
  and of the 113 functions with boxed locals only one of them, `getTree`, the recursive-descent parser in
  `mathexpr.c`, keeps per-call boxes. A divisor that is not a plain variable goes into a
  temporary rather than through a helper method (`lessons/28-a-sampler-thread-sees-only-where-the-lock-is-let-go.md`).

## The runtime and the math library

- **printf/snprintf** (`crt.rb`, `fmt_float`): MRI's `Kernel#format` is not correctly rounded (it prints 36.15,
  which is 36.149999999999998578 in binary, as "36.2" with `%.1f`; glibc prints "36.1"), so the digits of `%f`,
  `%e` and `%g` come from exact big-integer arithmetic, rounded half to even as glibc does
  (`lessons/26-ruby-format-is-not-glibc-printf.md`). `format` is used only for `%d` and, with C's unsigned
  reading of negative numbers, `%u`/`%x`/`%o`; nan/inf, `%c` and `%s` are written by the runtime.
- **strtod/atof/atoi/sscanf**: glibc's syntax (decimal, hexadecimal floats, `inf`, `infinity`, `nan`,
  `nan(...)` with its payload); short numbers take Clinger's exact fast path, the rest are rounded from the exact
  rational value with big integers. Ruby's `String#to_f` and `Float()` are not used (they accept `_` and differ
  from glibc's strtod on other inputs).
- Checked against glibc 2.39 by `ruby/test/run_crtcheck.sh` (the same 1,394,252 cases from
  `tools/crt/test/mkfmt.c` as the Go, Zig and Pascal checks): **1 differs**, `%#g` of 999999.5 (glibc `1.e+06`,
  the port `1.00000e+06`), the case the other runtimes also report; SWMM never uses `%#g`. Output:
  `ruby/results/crtcheck_result.txt`. Before the exact formatter, 11,553 cases differed.
- **Math.** MRI's `Math` calls glibc: libruby imports `exp@GLIBC_2.29`, `log@GLIBC_2.29`, `pow@GLIBC_2.29`,
  `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `log10` and `sqrt`, the same versioned symbols EPA imports
  (`nm -D /opt/rbenv/versions/3.3.6/lib/libruby.so.3.3` against `nm -D ref/runswmm`), so the port follows EPA,
  FMA routines included, on any machine both run on. What MRI adds around them is undone: `Math.sqrt`, `log`,
  `log10`, `asin` and `acos` raise `Math::DomainError` where C returns a NaN (and log10, asin and acos return
  glibc's positive NaN, log and sqrt the negative one); `Math.sqrt(-0.0)` is +0.0 in Ruby, -0.0 in C;
  `Float#**` returns a Complex for a negative base and a non-integral exponent; `Float#floor` and `#ceil` return
  Integers. `exp`, `sin`, `cos`, `tan` and `atan` are called as `Math.exp` etc. directly (MRI checks nothing
  for them); `pow(x, y)` is `x ** y` when `x >= 0` or `y` is integral. The engine never raises an Integer to a
  power: clang converts every argument of `pow` to double, and so does the translator.
- Checked bit for bit, NaN signs and payloads included, by `ruby/test/run_libm_tests.sh`: 10,000,416 random
  arguments over SWMM's ranges plus special values (`tools/libm/test/mkvectors.c`), 3,300,000 edge cases
  (`mkedge.c`: huge trigonometric arguments, negative bases, overflow, underflow, subnormals) and 4,000,112
  arguments for `sqrt`, `floor`, `ceil` and `fabs` (`ruby/test/mkexact.c`): **0 differ**
  (`ruby/results/libm_tests.txt`).
- **float.** `(float)x` and the REAL4 values of the `.out` file: MRI's `pack('f')`/`pack('e')` turn every NaN into
  +NaN and round anything above FLT_MAX to infinity; the runtime converts NaNs from their bits, as `cvtsd2ss` does.
- **stdio**: Ruby `File`s in binary mode with C's end-of-file flag, `fgets` semantics and positioning.

## How it was checked

| Run | Models | At once | Engine | Result |
|---|---|---|---|---|
| rb_1 | the 305 fastest (EPA under 0.05 s) without SAVE or LID report files | 2 | first runtime: Ruby's `format` for `%f` | 278 identical; 27 differ in a report's last digit (lessons/26) |
| rb_2 | those 27 | 2 | exact formatter | 27 identical |
| rb_3 | the 108 medium models (EPA 0.05 to 1.5 s) | 2 | the same | 107 identical; Hydraulics/Allow_Ponding_Low_CE.inp: report identical, `.out` differs in its NaNs' sign bits (lessons/27) |
| rb_4 | the 38 decks with SAVE, USE or LID report files | 1 | final engine and runtime (NaN writer, hoisted boxes, division temporaries) | 38 identical |
| **rb_5** | **all but the 29 slowest: 451** | **1** | **final** | **451 identical** |
| **rb_6** | **15 of the 29 slowest** | **2** | **final** | **14 identical; SCANLON.inp not run (stopped at 1800 s)** |
| **rb_7** | **the other 14** | **2** | **final** | **13 identical; 72_H&H_Elements(2).inp not run (stopped at 1800 s)** |
| rb_vs | 48: 45 drawn at random from rb_5's 451, plus the three decks that SAVE and USE `cho.txt` | 1 | final, from a clean checkout of commit 5588e66 (the main session's check) | 48 identical |
| rb_8 | SCANLON.inp and 72_H&H_Elements(2).inp | 2 | final, from the same clean checkout, 3,300 s limit | neither finished: not run |

rb_5, rb_6 and rb_7 together cover the 480 models once each and are the result; rb_vs and rb_8 are the main
session's independent check of them, made from a clean checkout (ids in `ruby/gate/ids_check_*.txt`); rb_1 to rb_4 were discovery runs
(records in `ruby/results/discovery/`). The 29 slowest models (EPA's reference run 1.5 s or more; none SAVEs or USEs
a file, so none can race another) ran two at a time so that each run stayed inside the session's two-hour limit for
a background job; everything else ran one at a time, as the brief's gate command does. Neither unfinished run is
counted as anything but not run, although their reports, cut off when they were stopped, match EPA's line for line
as far as they go (871 and 1,500 lines). The final-gate records are `ruby/results/rb_5.json`, `rb_6.json`,
`rb_7.json` with their logs; the id lists are in `ruby/gate/`. rb_5 ran with the wrapper before the `exec` change
described below (it changes only which process the gate's timeout kills), rb_6 and rb_7 with it. The engine was
regenerated from the final translator before the final gate and is byte-identical to the one gated.

All runs: `python3 gate/gate.py NAME "$PWD/ruby/runswmm_saves.sh" --ids IDS -j J --timeout 1800 --prune`, inside
`flock` on the shared corpus lock, with the output folder in `/dev/shm` (`lessons/22`). `runswmm_saves.sh` backs
up every file a deck SAVEs (listed by the swmm6-rust repository's `gate/savefiles.py`, called read-only) and
restores it after the run; it also backs up the backslash spelling of `[LID_USAGE]` report files, which
`savefiles.py` lists with `/` (OpenSWMM 6's rule) while EPA 5.2.4 writes a file whose name contains the
backslashes; and a deck with nothing to back up runs the engine with `exec`, so that the gate's timeout, which
kills its own child process, stops the engine rather than leaving it running as an orphan (`lessons/29`).
`Hydrology/cho.txt` was 1,114,474 bytes, md5 5b0ca1fe78588202fa779dbfa417b089, before and after.

The runtime checks were rerun on the final runtime: 1 of 1,394,252 printf/strtod/sscanf cases differ (the `%#g`
case above) and 0 of 17,300,528 math vectors.

Beyond the gate: the four `[LID_USAGE]` report files the LID decks write (`LID/C:\Users\dickinre\Desktop\groof.txt` and
three more, named with backslashes as EPA names them) were last written by this port (rb_4) and are byte-identical to
the files EPA's own build writes for copies of the same decks (`lessons/29`).

## Speed

The gate's clock: the 478 models that ran took 11,303 seconds of engine time (rb_5: 2,859 s for 451 models, one at a
time; rb_6 and rb_7: 8,444 s for 27 models, two at a time), plus 3,600 s for the two that were stopped. Wall time
of the three final runs: 47 min 40 s, 55 min 2 s and 49 min 25 s (2 h 32 min). Against EPA's own times from the
reference run (made earlier, on a differently loaded machine, so a rough guide only), the median ratio is 70 (101
models where EPA took 0.1 s or more; range 11 to 147); against the Python port's stored gate times, 1.10 (median of
the 98 models the Python port took 5 s or more on; range 0.27 to 1.47).
Ruby 3.3.6 here has no YJIT, so this is the bytecode interpreter's speed. At the median ratio the two longest models
would need 40 to 45 minutes each, but that estimate proved low: in rb_8, run two at a time with a 3,300-second
(55-minute) limit, neither finished. Start-up (loading and compiling the 35,616-line engine; `ruby/runswmm --version`) takes
0.15 s. Peak memory on
`Hydrology/sewer_rdii_problem.inp`, which allocates 3.38 GB of RDII rainfall history in C: 3.07 GB resident
(EPA: 3.11 GB). No interleaved benchmark with EPA run twice was made (lessons/07), so no ratio here is a measured
result in that sense.

## What this does not show

- That SWMM is right: identical to EPA means EPA's answers, good or bad.
- The two models that were stopped: SCANLON.inp and 72_H&H_Elements(2).inp were not run to the end (not in 30
  minutes in rb_6 and rb_7, not in 55 minutes in rb_8), so nothing is claimed for them.
- Other platforms: the port calls the system libm through MRI, so on another machine it should follow EPA built
  there; only x86-64 Linux with glibc 2.39 was run.
- Paths no gate model exercises: streets and inlets (one deck, which stops on input errors), climate files,
  USE HOTSTART, USE INFLOWS, USE RUNOFF; the stepping API is translated but only the command line was gated.
- A checked run: Ruby is memory-safe, but not C-safe. Reading past the end of an Array gives `nil` and writing past
  it grows the Array; a negative index counts from the end. A C overrun would therefore not crash here, and the
  gate would see it only if it changed an output. No equivalent of the Zig and Pascal checked builds was run.
- Speed beyond the gate's own clock: no interleaved benchmark against EPA was run (lessons/07).
- No person has reviewed the generated code line by line; the evidence is the gate and the runtime checks.

## Licence and credit

EPA SWMM is a work of the U.S. Environmental Protection Agency and is in the public domain; its engine is Lewis
Rossman's design, and this port keeps every algorithm as he wrote it. The port contains no glibc code: Ruby calls
the system's libm (glibc, LGPL-2.1-or-later, `ref/LGPL-2.1.txt`) as a shared library at run time, as EPA's own
build does. Ruby is distributed under the Ruby licence or the 2-clause BSD licence. No licence has been chosen yet
for the translator and the runtime.

## AI use

The translator back end (`tools/c2x/emit_ruby.py`), the runtime (`ruby/swmm5/crt.rb`, `ruby/swmm5/overrides.rb`,
`ruby/runswmm.rb`), the generated engine, the launcher and gate wrapper, the runtime and math checks, lessons 26
to 29 and this README were written by Claude (Anthropic's AI model, Claude Opus 5.5) in a Claude Code session on
8 November 2026, for Robert (Bob) Dickinson, who chose Ruby for his Code Rosetta Stone app and set the
byte-for-byte standard. Claude ran every gate and check reported here. The checks are mechanical; no person has
yet reviewed the code.
