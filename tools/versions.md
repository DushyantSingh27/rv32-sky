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
| Sail RISC-V | 0.13.1, release `2026-08-17-8f91355`, binary sha256 `55de5754…` (section below) | n/a, open source | none | 2026-10-30 |
| binutils-riscv64-unknown-elf | `2.35.1-0ubuntu1` (apt), assembles `sw/tests` | n/a, open source | none | 2026-10-30 |
| Icarus Verilog | 11.0 | n/a, open source | none | 2026-08-01 |
| GTKWave | 3.3.104 | n/a, open source | none | 2026-08-01 |
| sv2v | not yet installed | | | |
| slang (standalone) | not installed; standalone slang lint deferred from CI (ADR-0009) | | | 2026-11-04 |

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

## Sail RISC-V (T1, 2026-10-30)

Two different binaries report `0.13.1`. A version string does not identify Sail here.

| Item | Release `2026-08-17-8f91355` (**the pin**) | Tag `0.13.1` (not used) |
|---|---|---|
| `sail_riscv_sim --version` | `0.13.1` | `0.13.1` |
| Binary sha256 | `55de57547cc2f1cf5be4e41ac3e7664d9c9534f9f43ef76f53fded3a4672a0f3` | `b83c230eb252d31648dd805be2fc5e1ab5951c57992d7df30818b0cd8a6c6f05` |
| Tarball | `sail-riscv-Linux-x86_64.tar.gz`, 2,571,363 bytes, sha256 `095dcdb536938459e14c345d7be3e394cba0f609f6072e91777f31bef2a92846` | — |
| Local path | `~/src/sail-riscv-bin/bin/sail_riscv_sim` (tarball kept at `~/src/sail-riscv.tar.gz`) | — |
| Used by | every lockstep result since `0015`; the ACT4 ELF set; CI | — |

Enforced by `make -f tools/guards.mk check-sail` (L0 `sail-guard`) and, in CI, by
sha256 checks on both the tarball and the binary. docs/results/0030.

## Assembler for `sw/tests` (T1, 2026-10-30)

| Item | Value |
|---|---|
| Package | `binutils-riscv64-unknown-elf` `2.35.1-0ubuntu1` (Ubuntu 22.04 `jammy/universe`) |
| Binary | `/usr/bin/riscv64-unknown-elf-as`, reports `GNU assembler () 2.35.1` |
| Why pinned | `ci/build_sw_tests.sh` requires every rebuilt `.hex` to equal the tracked one, byte for byte |

## ACT4 compiler (T2, recorded in docs/results/0016)

GCC 16.1.0 (`g6afcc4f6d`), binutils 2.46, riscv-collab nightly `2026.07.15`, at
`~/src/toolchain-gcc15/riscv/bin/` (the directory name says 15; the compiler is 16).
Not installed in CI: the 47 ELFs it produced are committed under
`verif/compliance/rv32sky/elfs/` with `MANIFEST.sha256`, which records the
compiler, the riscv-arch-test commit (`8693fd9c…`) and the sha256 of the five
config files. `ci/check_elfs.py` (L0) fails on any mismatch.

## OSS CAD Suite (recorded in docs/results/0028)

Yosys 0.69+152 (`6f876ae0e-dirty`), yosys-slang, SBY and boolector. **Its bundled
Verilator 5.053 must never run a recorded result** (docs/results/0026). Used only for
formal and equivalence flows, which are not in CI (ADR-0009). Standalone slang lint
is deferred from CI by the same ADR.

## CI (T1, GitHub Actions runs 2026-10-30 to 2026-11-04)

`.github/workflows/ci.yml`, job `l0-l1`, every push and pull request. docs/results/0030.

| Item | Value |
|---|---|
| Runner label | `ubuntu-24.04` (GitHub-hosted, 4 threads as measured by the ACT4 runner) |
| Runner version | 2.338.0 (run #1); 2.338.2 (runs #2, #3) |
| Runner image | `ubuntu-24.04` 20261025.353.1 (runs #1, #2); 20261101.360.1 (run #3) |
| Job container | `ubuntu:22.04@sha256:076e7bf82319619f28dd0aa9c02ab34b055ad37100395b4f49a2ffba04fb5e11`, pinned since `835e265` |
| `actions/checkout@v5` | resolved to `fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09` (all runs) |
| `actions/cache@v4` | resolved to `0057852bfaa89a56745cba8c7296529d2fc39830` (runs #1, #2; Node.js 20 deprecation warning) |
| `actions/cache@v5` | resolved to `caa296126883cff596d87d8935842f9db880ef25` (run #3 onward; no warning) |
| Verilator in CI | built from commit `3d2421f3bf8cda84b49d8f739e39bce73c93cc46`, prefix `$HOME/.local`; guard requires rev `v5.050-60-g3d2421f3b` |
| Verilator cache key | `verilator-v5.050-60-g3d2421f3b-ubuntu22.04-076e7bf82319-v2` (114,382,398 bytes) |
| Cold Verilator build | 4 m 43 s (run #1), 7 m 20 s (run #3) |
| Sail in CI | downloaded from the release above, tarball and binary sha256 checked, installed to `$HOME/src/sail-riscv-bin` |
| Packages (all runs identical, 186 installed) | g++-11 `11.4.0-1ubuntu1~22.04.3`, python3.10 `3.10.12-1~22.04.18`, make `4.3-4.1build1`, perl `5.34.0-3ubuntu1.9`, flex `2.6.4-8build2`, bison `2:3.8.2+dfsg-1ubuntu0.22.04.1`, autoconf `2.71-2`, ccache `4.5.1-1`, git `1:2.34.1-1ubuntu1.18`, zlib1g-dev `1:1.2.11.dfsg-2ubuntu9.2`, curl `7.81.0-1ubuntu1.30`, libc6 `2.35-0ubuntu3.15`, binutils-riscv64-unknown-elf `2.35.1-0ubuntu1`; the full list is printed by every run |

Only binutils is pinned by apt version. The rest are recorded, not pinned: the digest
fixes the base image, but `apt-get update` reads the archive as it is that day.
Changing the container digest means changing the cache key with it (both are in
`ci.yml`, and a comment says so; nothing checks it).
