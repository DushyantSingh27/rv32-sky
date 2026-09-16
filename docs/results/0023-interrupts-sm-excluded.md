# 0023 — `InterruptsSm` is unrunnable on this core. Excluded, not fixed.

**Date:** 2026-09-14
**Milestone:** M3.4b
**DUT:** `rtl/core/csr.sv`, `rtl/core/decoder.sv` (context only — no RTL changed)
**Tools:** Verilator 5.050 (`v5.050-60-g3d2421f3b`), GCC 16.1.0 (`g6afcc4f6d`),
Sail RISC-V 0.13.1, ACT4 `riscv-arch-test`
**Status:** Finding 3 of `docs/results/0021` closed by exclusion. One new open
discrepancy recorded (`wfi`).

## Result

| | Before | After |
|---|---|---|
| ACT4 | 46 passed / **48** | 46 passed / **47** |
| Excluded | — | `InterruptsSm` |
| Remaining failure | `fence.i`, `InterruptsSm` | `fence.i` only |

**Both denominators are stated deliberately.** The pass count did not improve;
the test count dropped. A results file reporting 46/47 without saying a test was
removed would be misleading in exactly the way this milestone has been about.

## Why the test cannot pass

`InterruptsSm-00.S` arms `mie`, triggers an interrupt through
`RVTEST_SET_MSW_INT` / `RVTEST_SET_MEXT_INT`, then executes `wfi` via
`RVTEST_IDLE_FOR_INTERRUPT` to wait for it.

On this core those macros are **deliberately empty**
(`verif/compliance/rv32sky/rvmodel_macros.h`): there is no CLINT, no PLIC, and
`mip` is driven entirely from `irq_timer` / `irq_software` / `irq_external`,
all tied low (`csr.sv`). No interrupt can ever arrive. So `wfi` is reached, the
decoder rejects it as illegal, a trap is taken, and the recorded trap signature
differs from the reference — whose `sail.json` has a working CLINT and interrupt
generator.

Measured from the run:

    XCAUSE:  0x00000002        illegal instruction
    XTVAL:   0x10500073        wfi
    XSTATUS: 0x00001880        MPP=11, MPIE=1, MIE=0 — correct trap entry
    Expected signature word 0: 0x03101b53
    Actual   signature word 0: 0x03100353

XOR is `0x1800` — bits 11 and 12.
`tests/env/rvtest_trap_handler.h:217` gives the packing:

> word 0 packs: `mode(1:0)`, `entry_size(5:2)`, `vector(10:6)`, **`xIE(11)`,
> `xIP(12)`**, `xstatus(30:13)`

So the reference records `mie` and `mip` non-zero at trap time; this core records
both zero. `mode(1:0)` matches in both values, so the core entered M-mode
correctly and the trap mechanism itself is healthy. **This is a missing
interrupt controller, not a trap-path bug.**

No RTL change can make it pass short of implementing a CLINT, which is M5
(`PROJECT_CONTEXT` §3.4).

### The tool's own hint was wrong, and nearly cost a wasted investigation

RVCP printed:

> HINT: Vector+Mode word mismatch may indicate: trap handled in wrong privilege
> mode (check medeleg/mideleg), incorrect mstatus fields (MPP/SPP/MPV), or wrong
> vectored interrupt entry.

`0x1800` is also exactly `MPP_MMODE` — `(3 << MPP_LSB)` with `MPP_LSB = 11`,
defined twenty lines below the packing comment in the same header. The
difference looked like MPP and was not: MPP lives inside the `xstatus(30:13)`
slice, which **matches** in both values. The `0x1800` coincidence is arithmetic,
not signal.

Following the hint would have sent the investigation into `csr.sv`'s
`mstatus[MSTATUS_MPP_LSB +: 2] = 2'b11` — hardwired, correct, and irrelevant.
It was avoided only by reading the packing definition before acting on the hint.

**Fourth wrong mechanism in two sessions, and the first proposed by a tool
rather than by us.** The other three are in `0022`. A generated diagnostic hint
is a guess with good formatting; it earns the same T5 treatment as a recalled
tool flag (PROJECT_INSTRUCTIONS §2.1).

## `ExceptionsSm` PASSES — which is why the exclusion is by name

`tests/priv/` holds ~40 suites. Test selection against the declared extension set
generated exactly two: `ExceptionsSm` and `InterruptsSm`. **`ExceptionsSm`
passes.**

That is a second independent confirmation of M3.4a's trap path — ACT4 agreeing
with Sail lockstep on the work `0018` measured, the same shape of cross-check the
39 base-I tests give for M3.1–M3.5.

It is also the argument against excluding `Sm` wholesale. Declaring `Sm` is
**truthful**: this core has M-mode CSRs, trap entry, `mret`, and six measured
trap causes. ACT4 simply does not subdivide `Sm` into traps and interrupts. A
blanket `Sm` exclusion would discard a genuinely passing suite covering exactly
the milestone's work.

Contrast `Zifencei`, which **is** a false declaration (`0021` finding 2). The two
situations look similar and are not: one is a hardware gap under a truthful
declaration, the other is a declaration claiming behaviour that does not exist.

## Where the exclusion lives, and why

`--exclude` is a `typer.Option` on the `act` CLI (`framework/src/act/act.py:51`),
threaded into `generate_test_dict()`. There is **no config-file route** —
confirmed by grepping `config.py` and `select_tests.py` for `exclude` and finding
nothing. So it cannot live in `rv32sky.yaml` or `test_config.yaml`.

An exclusion recorded only in a command line is the same artifact class this
milestone spent a week repairing: four config files describing the core from
somewhere other than where the core is defined, each stale, each masked by the
one before. A fifth living in shell history would be that failure with a shorter
half-life.

So the full invocation is version-controlled beside the config it applies to:
**`verif/compliance/rv32sky/run_compliance.sh`**.

    EXCLUDE="Sm,SdtrigSm,SdtrigS,SdtrigU,InterruptsSm"

`Sm,SdtrigSm,SdtrigS,SdtrigU` is the **upstream default** (Makefile: *"Sm:
Insufficient WARL configuration options"*). It must be repeated, because
overriding a make variable REPLACES its default — passing only `InterruptsSm`
would silently re-enable three upstream exclusions.

Matching is on directory names under `tests/` and is **exact, not prefix**
(`parse_test_constraints.py:198`), which is why the upstream `Sm` token does not
already cover `InterruptsSm`.

**Re-enable at M5**, when the CLINT lands. The reason is written into the script
next to the exclusion, not only here.

### The script propagates the exit code

`0018`: `run_lockstep.sh` read `compare.py`'s verdict and discarded the harness
exit status, and two programs reported FAIL from the harness on every run for
three weeks while the script said "all agree". Both components were correct; the
composition read one and dropped the other.

`run_compliance.sh` exits with `run_tests.py`'s status unchanged — **1** while
`fence.i` remains open — and prints expected against actual counts.

## Two mistakes this file exists to record

### The count check caught a silent no-op on its first run

The first version of the script removed only `work/stamps`. It reported:

    === expected 46 passed of 47
    === actual   46 passed of 48
    WARNING: test COUNT changed.

The exclusion had done nothing. `--exclude` filters at **test generation**, not
at ELF build and not at run time, so three things must go or it is inert:

| Path | Why |
|---|---|
| `work/stamps` | testgen stamps depend on their sources and the Makefile, **not** on the value of `EXCLUDE_EXTENSIONS` — a changed list leaves them valid and `make tests` says "Nothing to be done" |
| `tests/<arch>` | already-generated `.S` sources for excluded suites remain on disk and are still picked up |
| `work/rv32sky` | already-built ELFs are up-to-date targets; sources unchanged, so make skips them and the old set runs |

Failure mode #4, third instance this milestone. The count check is the only
reason it was visible rather than a quietly wrong 46/48.

### The first cleanup test was defeated by the thing it was testing

To prove the cleanup works, the plan was to regenerate everything with
`EXCLUDE_EXTENSIONS=` and check the script still produced 47. That run reported
`make: Nothing to be done for 'tests'` — **the stamps had been recreated by the
script's own prior successful run, and clearing the variable does not invalidate
a stamp.** The experiment designed to demonstrate the stamp problem was defeated
by the stamp problem.

Corrected by removing `work/stamps` first:

    rm -rf work/stamps
    make tests EXCLUDE_EXTENSIONS=      → 181 test suites generated
    ls tests/priv/InterruptsSm/ | wc -l → 1     (present on disk)
    ./run_compliance.sh                 → 46 passed of 47, exit 1

`InterruptsSm` present before the run, absent from the result after. That is the
cleanup **demonstrated**, in the same discipline as `--force-fail` in `0021`:
show the mechanism does something on input where it should, rather than
observing it did no harm on input where it did not matter.

## NEW OPEN DISCREPANCY — `wfi` traps as an illegal instruction

`XTVAL = 0x10500073` is `wfi`, and `XCAUSE = 2` shows the decoder rejects it.

`wfi` is a **legal M-mode instruction under `Sm`**, and the spec explicitly
permits implementing it as a no-op. This core declares `Sm`. `0017` records `wfi`
among the encodings already illegal via other paths in the decoder.

This did **not** cause the `InterruptsSm` failure — that is `xIE`/`xIP`, and the
trap is a downstream symptom of the interrupt never arriving. But it is a real
discrepancy against the declaration, the same shape as `fence.i`: a declaration
claiming behaviour the core does not have.

**Not fixed, not investigated further.** Scope: likely a decoder change to accept
`wfi` as a legal no-op, far smaller than the `fence.i` flush and with no pipeline
implications. Open.

## Reproduce

    cd ~/dev/rv32-sky
    ./verif/compliance/rv32sky/run_compliance.sh

Expect `46 passed of 47`, expected matching actual, exit 1.

The script regenerates from clean every time, so this is reproducible from any
state of the ACT4 tree.

## Provenance

Every expected value comes from ACT4, derived from Sail configured to match this
core. No value in this file was produced by the DUT.

**No RTL was changed.** The signature-word packing comes from
`tests/env/rvtest_trap_handler.h`, the exclusion mechanism from `act.py` and
`parse_test_constraints.py`, both read rather than recalled.

**Not verified here:** `wfi` is recorded as a discrepancy on the strength of the
spec and the observed `XCAUSE`/`XTVAL`; no test was written for it. Whether any
other `tests/priv/` suite would fail if the declaration widened is untested —
only `ExceptionsSm` and `InterruptsSm` are generated at present.
`Zifencei-fence.i-00` remains open (`0021` finding 2).
