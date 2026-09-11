#!/usr/bin/env python3
"""Generate verif/compliance/rv32sky/sail.json - the Sail configuration ACT4 uses.

WHY THIS FILE IS GENERATED AND NOT HAND-WRITTEN
================================================
ACT4 invokes Sail with `--config <file>` (framework/src/act/build_plan.py:99),
which supplies a COMPLETE configuration. `--rv32` is mutually exclusive with
`--config`, so nothing is inherited: every one of ~862 lines must be present.

verif/sail/rv32sky.json cannot be used. It is an OVERRIDE (`--config-override`),
carrying only the deltas from Sail's RV32 default. Handed to `--config` it would
be missing almost everything.

Rather than maintain a second 862-line file by hand, this script derives one:

    Sail's own --rv32 --print-default-config   (the complete base)
  + the extension set from verif/sail/rv32sky.json   (DUT match, single source)
  + ACT4-specific memory and device edits            (below)
  = verif/compliance/rv32sky/sail.json

Taking the extension set from the lockstep override means the two Sail configs
CANNOT diverge on which extensions the model implements. That is the specific
drift this milestone exists to fix: four separate artifacts (rv32sky.yaml,
test_config.yaml, rvmodel_macros.h, and the absent sail.json) all described the
pre-M3.4a core because each was maintained by hand, separately, on one day.

MEASURED FACTS THIS SCRIPT RELIES ON (all T1, all in docs/results/)
===================================================================
- `--print-default-config` IGNORES `--config-override`. Verified 2026-09-11 by
  diffing the output with and without: byte-identical. docs/results/0018 states
  the opposite and carries a provenance note correcting it. This is why the
  override's content is applied HERE, in Python, rather than by asking Sail to
  resolve it.
- Sail's global `memory.misaligned.exceptions.load_store` is checked BEFORE
  address translation and overrides the per-region `misaligned_exceptions`.
  Left at its default {"None": null}, a misaligned sw/lw EXECUTES. docs/results/0018.
- Default region 0 (base 0x1000, size 0x1000) is IOMemory with
  `writable: false` and `executable: false`. ACT4's link.ld places RAM at 0x0
  for 0x40000, so .text spans through 0x1000 and would fault on fetch. The
  region must be removed. Separately, docs/results ledger 2026-08-20 records
  test data at 0x1000 colliding with the HTIF tohost window.

THE ONE DELIBERATE MISMATCH WITH THE DUT
=========================================
ACT4 REQUIRES platform.clint.supported and
platform.simple_interrupt_generator.supported to be true
(framework/src/act/build_plan.py:_sail_platform_base raises otherwise). Its own
error text says this is required "even when the DUT uses a different interrupt
mechanism or does not provide the same device."

This core has NO CLINT and no interrupt controller, and verif/sail/rv32sky.json
disables both deliberately.

Enabling them here does not weaken the reference model. The two base addresses
become nothing but compiler defines - SAIL_CLINT_BASE_ADDRESS and
SAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS - consumed by sail_macros.h for
signature-generation plumbing. They are not ISA semantics. The extension set,
which is where "match the model to the core" actually lives, still matches the
DUT exactly, because it is copied from the lockstep config.

Both devices sit at their Sail defaults (0x2000000 and 0xC000000), inside the
0x2000000/0x10000000 IOMemory region, clear of DUT memory at 0x0-0x40000.

USAGE
=====
    cd ~/dev/rv32-sky
    python3 verif/compliance/rv32sky/gen_act4_sail_config.py

Re-run it after any change to verif/sail/rv32sky.json or after a Sail upgrade.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SAIL = Path.home() / "src/sail-riscv-bin/bin/sail_riscv_sim"
OVERRIDE = REPO / "verif/sail/rv32sky.json"
OUT = REPO / "verif/compliance/rv32sky/sail.json"

# ACT4's link.ld: RAM_ORIGIN = TEST_BASE = 0x0, RAM_LENGTH = 0x100000.
# Raised from 0x40000 on 2026-09-11: I-bne-00.sig.elf placed .text.rvmodel
# at 0x47660, past the end of a 256 KB region. ACT4 builds at -O0 -g with no
# size optimisation, and I-bne-00 is among the simplest tests in the suite,
# so 1 MB is chosen for headroom rather than the minimum that clears it.
# THREE numbers must agree: this, RAM_LENGTH in link.ld, and the tcm.sv
# SIZE_BYTES override in the ACT4 harness (1048576).
DUT_RAM_BASE = "0x0"
DUT_RAM_SIZE = "0x100000"


def die(msg: str) -> None:
    sys.exit(f"ERROR: {msg}")


def load_json5(text: str, what: str) -> dict:
    """Parse JSON5. Prefer pyjson5; fall back to stripping line comments."""
    try:
        import pyjson5

        return pyjson5.loads(text)
    except ImportError:
        pass
    stripped = re.sub(r"^\s*//.*$", "", text, flags=re.M)
    try:
        return json.loads(stripped)
    except json.JSONDecodeError as e:
        die(
            f"could not parse {what} after stripping line comments ({e}). "
            "Install pyjson5 (pip install pyjson5 --break-system-packages) and re-run."
        )


def main() -> None:
    if not SAIL.is_file():
        die(f"Sail binary not found at {SAIL}")
    if not OVERRIDE.is_file():
        die(f"lockstep override not found at {OVERRIDE}")

    # ---- 1. the complete base, straight from Sail ----
    proc = subprocess.run(
        [str(SAIL), "--rv32", "--print-default-config"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        die(f"sail --print-default-config failed:\n{proc.stderr}")
    cfg = load_json5(proc.stdout, "Sail default config")

    for key in ("base", "memory", "platform", "extensions"):
        if key not in cfg:
            die(f"Sail default config has no '{key}' object - schema changed?")

    ov = load_json5(OVERRIDE.read_text(), str(OVERRIDE))

    # ---- 2. extensions: copy the DUT match wholesale ----
    ov_ext = ov.get("extensions")
    if not isinstance(ov_ext, dict) or not ov_ext:
        die(f"{OVERRIDE} has no 'extensions' object to copy")
    before_disabled = sum(
        1 for v in cfg["extensions"].values()
        if isinstance(v, dict) and v.get("supported") is False
    )
    for name, spec in ov_ext.items():
        if name not in cfg["extensions"]:
            die(f"override names extension '{name}' absent from Sail's default - Sail upgrade?")
        cfg["extensions"][name].update(spec)
    after_disabled = sum(
        1 for v in cfg["extensions"].values()
        if isinstance(v, dict) and v.get("supported") is False
    )
    if after_disabled <= before_disabled:
        die("applying the override disabled no extensions - the copy did not take effect")

    # ---- 3. base: match the core ----
    # misa is read-only in this core (docs/results/0009-csr-standalone.md).
    cfg["base"]["writable_misa"] = False
    ov_base = ov.get("base", {})
    if "mstatus" in ov_base:
        # With S and F disabled, mstatus.FS and .VS must be read-only zero;
        # Sail's validator enforces the consistency.
        cfg["base"].setdefault("mstatus", {}).update(ov_base["mstatus"])

    # ---- 4. memory: physaddr width and the GLOBAL misaligned gate ----
    # 32, not the default 34: Sv32 is disabled, 32-bit bus, no MMU.
    cfg["memory"]["physaddr_bits"] = 32

    mis = cfg["memory"].get("misaligned")
    if not isinstance(mis, dict) or "exceptions" not in mis:
        die("memory.misaligned.exceptions missing - schema changed?")
    if mis["exceptions"].get("load_store") != {"None": None}:
        die(
            "memory.misaligned.exceptions.load_store is not at its expected default - "
            f"got {mis['exceptions']['load_store']!r}. Re-read before overwriting."
        )
    # The live control. Produces cause 4 (load) and cause 6 (store), matching
    # the core. Verified in docs/results/0018: with this left at the default,
    # probe_traps.S produced four traps where six were expected.
    mis["exceptions"]["load_store"] = {"Some": "AlignmentException"}

    # ---- 5. regions ----
    regions = cfg["memory"]["regions"]
    if not isinstance(regions, list) or not regions:
        die("memory.regions is empty - schema changed?")

    def base_of(r: dict) -> str:
        return str(r["base"]["value"]).lower()

    # Template the DUT RAM region on the override's MainMemory region, which
    # was written for this core. Falls back to Sail's own MainMemory otherwise.
    ram_template = None
    for r in ov.get("memory", {}).get("regions", []):
        if r.get("attributes", {}).get("mem_type") == "MainMemory":
            ram_template = json.loads(json.dumps(r))
            break
    if ram_template is None:
        for r in regions:
            if r["attributes"]["mem_type"] == "MainMemory":
                ram_template = json.loads(json.dumps(r))
                break
    if ram_template is None:
        die("no MainMemory region found in either config to use as a template")

    ram_template["base"]["value"] = DUT_RAM_BASE
    ram_template["size"]["value"] = DUT_RAM_SIZE

    # Keep ONLY the device IO region; drop 0x1000 (not writable, not
    # executable - .text spans it) and 0x80000000 (the DUT peripheral window,
    # which ACT4 ELFs never touch: they terminate via HTIF tohost).
    device_region = None
    for r in regions:
        if base_of(r) == "0x2000000":
            device_region = r
            break
    if device_region is None:
        die("no region at 0x2000000 to hold the CLINT and interrupt generator")

    cfg["memory"]["regions"] = [ram_template, device_region]

    # ---- 6. platform devices ACT4 requires ----
    for dev in ("clint", "simple_interrupt_generator"):
        d = cfg["platform"].get(dev)
        if not isinstance(d, dict):
            die(f"platform.{dev} missing - schema changed?")
        d["supported"] = True
        if not isinstance(d.get("base"), int):
            die(f"platform.{dev}.base is not an integer - ACT4 requires one")

    # ---- 7. assert the devices land inside the IO region ----
    dev_base = int(device_region["base"]["value"], 16)
    dev_size = int(device_region["size"]["value"], 16)
    for dev in ("clint", "simple_interrupt_generator"):
        b = cfg["platform"][dev]["base"]
        if not (dev_base <= b < dev_base + dev_size):
            die(f"platform.{dev}.base 0x{b:x} is outside the IO region")
        if b < int(DUT_RAM_SIZE, 16):
            die(f"platform.{dev}.base 0x{b:x} overlaps DUT memory")

    header = f"""\
// GENERATED FILE - DO NOT EDIT BY HAND.
// Produced by verif/compliance/rv32sky/gen_act4_sail_config.py
// Read that script's docstring before changing anything here.
//
// This is the Sail configuration ACT4 uses ({OUT.name}, found by convention at
// dut_include_dir/sail.json - build_plan.py:94). It is a COMPLETE config,
// passed with --config.
//
// THE OTHER SAIL CONFIG IS verif/sail/rv32sky.json. That one is an OVERRIDE,
// passed with --config-override by verif/sail/run_lockstep.sh. The two differ
// deliberately:
//
//   - This file is complete; that one carries only deltas.
//   - This file enables platform.clint and
//     platform.simple_interrupt_generator because ACT4 refuses to run
//     otherwise; that one disables both, matching the core. The bases here
//     become compiler defines for sail_macros.h, not ISA semantics.
//   - This file maps DUT RAM at {DUT_RAM_BASE} for {DUT_RAM_SIZE} (ACT4's link.ld);
//     that one maps 0x0 for 0x2000 (the 8 KB TCM) and a peripheral window
//     at 0x80000000.
//
// The EXTENSION SET is copied from verif/sail/rv32sky.json by the generator, so
// the two configs cannot drift apart on what the model implements.
"""

    OUT.write_text(header + json.dumps(cfg, indent=2) + "\n")

    print(f"wrote {OUT}")
    print(f"  extensions disabled: {before_disabled} -> {after_disabled}")
    print(f"  regions: {[ (base_of(r), r['attributes']['mem_type']) for r in cfg['memory']['regions'] ]}")
    print(f"  clint base: 0x{cfg['platform']['clint']['base']:x}")
    print(f"  sig   base: 0x{cfg['platform']['simple_interrupt_generator']['base']:x}")
    print("\nNow validate:")
    print(f"  {SAIL} --config {OUT} --validate-config")


if __name__ == "__main__":
    main()
