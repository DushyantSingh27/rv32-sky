# Tool Version Ledger

Per PROJECT_INSTRUCTIONS 5.3, every tool is pinned and recorded here.
Undated entries are invalid.

## Host
| Item | Value | Recorded |
|---|---|---|
| OS | Ubuntu 22.04.5 LTS on WSL2 (kernel 6.6.114.1-microsoft-standard-WSL2) | 2026-07-30 |
| pid1 | systemd | 2026-07-30 |
| CPU threads | 20 | 2026-07-30 |
| RAM available to WSL | 10 GiB (raised from 7.6 GiB via .wslconfig memory=11GB) | 2026-07-30 |
| Host total RAM | 15.7 GiB | 2026-07-30 |
| Python | 3.10.12 | 2026-07-30 |

## Implementation stack
| Tool | Version | Install method | Recorded |
|---|---|---|---|
| LibreLane | v3.0.5 | AppImage (librelane-devshell-x86_64.AppImage) | 2026-07-30 |
| PDK family | sky130 | fetched by LibreLane smoke test | 2026-07-30 |
| PDK version hash | `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` (dated 2025.07.14) | ciel v2.4.0 | 2026-07-30 |
| PDK variants present | sky130A (used), sky130B (unused) | | 2026-07-30 |
| ciel | v2.4.0 | bundled in LibreLane devshell | 2026-07-30 |
| ciel store path | `$HOME/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/` | | 2026-07-30 |
| Yosys | TBD | bundled in LibreLane devshell | |
| OpenROAD | TBD | bundled in LibreLane devshell | |
| Magic | TBD | bundled in LibreLane devshell | |
| KLayout | TBD | bundled in LibreLane devshell | |
| Netgen | TBD | bundled in LibreLane devshell | |

## Verification stack
| Tool | Version | Licence | Expiry | Recorded |
|---|---|---|---|---|
| ~~Altair DSim~~ | 2026.0.0 | **DEAD** — DSim Cloud shut down 2026-09-01; the on-premises install validates against that server | n/a | 2026-09-02 |
| Verilator | 5.050 `v5.050-60-g3d2421f3b` | n/a, open source | none | 2026-08-01 |
| Icarus Verilog | 11.0 | n/a, open source | none | 2026-08-01 |
| GTKWave | 3.3.104 | n/a, open source | none | 2026-08-01 |
| sv2v | not yet installed | | | |
| slang (standalone) | not yet installed | | | |

## Environment notes
- `libfuse2` was required for the LibreLane AppImage to run on Ubuntu 22.04 WSL2.
  Not mentioned in the LibreLane AppImage installation docs. Installed via
  `sudo apt-get install -y libfuse2`.
- Enter the LibreLane environment: `~/librelane-devshell-$(uname -m).AppImage`
  Leave it: `exit`
- DSim licence expires every 90 days and must be revoked then regenerated from the
  DSim Cloud Portal. Record each new expiry date above.

## PDK pinning policy
This PDK version is the project pin. Do NOT upgrade mid-project. Any PDK change
invalidates every prior area, Fmax and DRC result and requires re-baselining from
the M0 smoke design forward. If an upgrade is ever needed, write an ADR first.

## USE_SLANG confirmation (T1, empirical, 2026-07-31)
Confirmed by reading the installed LibreLane 3.0.5 package source, not documentation.

Definition, from librelane/steps/pyosys.py:
    Variable("USE_SLANG", bool,
             "Use the Slang frontend to process files, which has better
              SystemVerilog parsing capabilities but is not as battle-tested
              as the default Yosys frontend.",
             default=False,
             deprecated_names=["USE_SYNLIG"])

Key facts:
  - Type bool, DEFAULT IS FALSE. Must be set explicitly to true in flow config.
  - Deprecated alias USE_SYNLIG still accepted (OpenLane 2.x compatibility).
  - Companion variable SLANG_ARGUMENTS (Optional[List[str]]) passes arguments
    to the Slang frontend. This is an escape hatch before falling back to sv2v.
  - Consumed at librelane/scripts/pyosys/synthesize.py, in the Verilog/SV branch
    (a separate branch handles VHDL_FILES via the ghdl plugin).
  - LibreLane 3.0.5 drives Yosys through its Python API (pyosys). The synthesis
    step is steps/pyosys.py. OpenLane-era material referencing yosys.py or Tcl
    synthesis scripts does not apply.

Risk note: upstream itself describes the Slang frontend as less battle-tested
than the default. This raises the likelihood of PROJECT_CONTEXT section 2.5
Constraint B (slang rejecting legal SystemVerilog) occurring. The M0 smoke
design deliberately exercises enum, packed struct, package and interface to
find any limits early.

## Decision 2026-07-31 (owner)
Proceeding on DSim within the 32-day window rather than switching simulators.
Rationale as stated by the project owner: results will be captured and published
with the completed project, so DSim will not need to be re-run afterwards.
Claude noted a disagreement regarding PROJECT_INSTRUCTIONS 5.3 reproducibility
and post-2026-09-01 availability for M3-M5 UVM environments. Owner decision stands.
Consequence: UVM work should be front-loaded while the licence is live.

## Operational note: DSim licence leases (T1, 2026-07-31)
The free individual licence holds a server-side lease for the duration of each run
and permits `maxLeases (1)`. A simulation that is killed or dies mid-run strands its
lease, and subsequent runs fail with:

    =F:[UsageMeter] License not obtained: Lease acquisition denied.
                    Already at maxLeases (1) for supplied license.

Observed: the stranded lease self-expired within ~20 minutes without intervention.
No manual revoke was needed.

Practical consequence: **do not Ctrl-C a DSim run.** Each kill costs roughly a
20-minute lockout. Budget for this during coverage closure.

Every DSim run also requires live internet - the UsageMeter contacts the Altair
licence server and verifies its certificate against /etc/ssl/certs before starting.

## Verilator (T1, 2026-08-01)
| Item | Value |
|---|---|
| Version | 5.050 2026-07-01 rev v5.050-60-g3d2421f3b |
| Install | built from source, `git checkout stable`, prefix `$HOME/.local` |
| Reason | Ubuntu 22.04 apt ships 4.038 (July 2020), six years stale |
| Lint status | smoke design passes `--lint-only -Wall --timing`, zero warnings |

Note: `$HOME/.local/bin` must precede `/usr/bin` on PATH or the apt 4.038 build wins.
To be handled permanently in tools/env.sh.

## Icarus Verilog / GTKWave (T1, 2026-08-01)
| Tool | Version | Install |
|---|---|---|
| Icarus Verilog | 11.0 (stable) | apt |
| GTKWave | 3.3.104 | apt |

## UVM library (T1, 2026-10-02)

| Item | Value |
|---|---|
| Version | Accellera UVM 2020.3.1 (IEEE 1800.2-2020) |
| Path | `~/src/uvm-2020.3.1` |
| `UVM_SRC` | `~/src/uvm-2020.3.1/src` — the **src** directory |
| Size | 5.2 MB |
| `md5sum src/uvm_pkg.sv` | `3f35dfbc73ec285cc799d88bfd9849d6` |
| Consumed by | `verif/uvm/uvm.mk` |

**RELOCATED 2026-10-02** from `~/AltairDSim/2026/uvm/2020.3.1`, where it had
lived since the DSim install. The library is Accellera's and works perfectly
well — the licence server's death does not touch a source tree — but every UVM
build in the project depended on a path inside a dead vendor install. Anyone
tidying that directory away would have broken env 7 silently. Copied, not
moved, so the original is still there if this turns out wrong.

The md5 is recorded because "UVM 2020.3.1" does not distinguish Accellera's
release from a vendor's patched copy, and this one came out of a vendor tree.

**`UVM_SRC` is the `src` directory, not the package root.** `uvm_pkg.sv` sits
directly in it and the DPI sources are at `src/dpi/`. ADR-0006's recipe implies
this — it uses both `$UVM_SRC/uvm_pkg.sv` and `$UVM_SRC/dpi/uvm_dpi.cc` — but
the path was constructed rather than read during the relocation and the first
check failed. `verif/uvm/uvm.mk` now asserts both files exist before building,
naming the distinction in the error. docs/results/0027.

Build cost, measured: a trivial UVM testbench takes ~87 s and 2,313 generated
C++ files on 20 threads, dominated by compiling the library rather than the
design. Cached in `obj_dir` afterwards.
