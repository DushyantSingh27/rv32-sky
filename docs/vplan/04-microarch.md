# vplan: microarchitecture

**Source:** `PROJECT_CONTEXT.md` §3.2, §3.3 — this project's design decisions
rather than the RISC-V specification.
**RTL:** `rtl/core/regfile.sv` exists; pipeline, hazard unit and memory do not.

## Register file

**Env 3** — `docs/results/0008-regfile-uvm-env3.md`

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| 32 x 32-bit, 2 read / 1 write | §3.2 | UVM | 3 | `cp_rs1`/`cp_rs2`/`cp_rd` (33 bins each) | Covered | Y |
| `x0` reads zero on both ports | §2.1 | UVM + RTL assert | 3 | x0 bins on all three | Covered | Y |
| `x0` discards writes | §2.1 | UVM + RTL assert | 3 | `cp_write_x0` (2 bins) | Covered | Y* |
| **Read-first on collision** | design decision | UVM directed | 3 | `cp_rs1_collides`, `cp_rs2_collides` | Covered | Y |
| Both read ports colliding at once | design | UVM | 3 | `x_both_collide` (4 cells) | Covered | Y |
| Same register on both read ports | §2.4 | UVM | 3 | `cp_same_read` (2 bins) | Covered | Y |
| Write enable low leaves state untouched | design | UVM directed | 3 | `x_rd_we` (66 cells) | Covered | Y |
| Data patterns (zero, ones, walking, alternating) | inferred | UVM | 3 | `cp_wdata` (7 bins) | Covered | Y |
| All registers reset to zero | design decision | UVM | 3 | implicit at time zero | Covered | — |

**Y\*** — the x0 write guard initially SURVIVED mutation testing. A port-level
test cannot distinguish "discards the write" from "stores it and masks the
read", because the DUT has both guards. A mechanism-level RTL assertion was
added to close the gap. See `docs/results/0011-mutation-testing.md`.

6,009 read/write collisions were observed in a single run, all returning the
pre-write value. Read-first is verified, not assumed — M3's forwarding logic
depends on it.

## Pipeline — nothing implemented

| Feature | Source | Method | Env | Coverage | Status | Owner |
|---|---|---|---|---|---|---|
| 5-stage IF/ID/EX/MEM/WB structure | §3.2 | — | — | none | **Deferred** | M3 |
| One instruction retired per cycle, no hazards | §3.2 | — | — | none | **Deferred** | M3 |
| Pipeline register content per stage | §3.2 | — | — | none | **Deferred** | M3 |
| Flush on branch redirect | §3.2 | — | — | none | **Deferred** | M3 |
| Stall propagation across stages | §3.2 | — | — | none | **Deferred** | M3 |
| Multi-cycle op (muldiv) held in EX | §3.2 | — | — | none | **Deferred** | M3 |
| Flush of an in-flight muldiv operation | design gap | — | — | none | **Deferred** | M3 |

## Hazards and forwarding — nothing implemented

| Feature | Source | Method | Env | Coverage | Status | Owner |
|---|---|---|---|---|---|---|
| EX→EX forwarding | §3.2 | directed, mutation | M3.3 | t04 checksum | Covered | Y |
| MEM→EX forwarding | §3.2 | directed, mutation | M3.3 | t04 checksum | Covered | Y |
| WB→ID forwarding (required by read-first) | §3.2 + D-decision | directed, mutation | M3.3 | t04 checksum | Covered | Y |
| Load-use interlock (single-cycle stall) | §3.2 | directed, mutation | M3.3 | t04 checksum | Covered | Y |
| Forwarding priority when multiple sources match | §3.2 | directed, mutation | M3.3 | two writes one cycle apart | Covered | Y |
| No forwarding from or to `x0` | §2.1 | directed, mutation | M3.3 | write x0 then read x0 | Covered | Y |
| Back-to-back dependent instructions | §3.2 | directed | M3.3 | t04, all NOPs removed | Covered | Y |

The read-first decision in env 3 makes WB→ID forwarding **mandatory**, not
optional. Verifying it is the single most important item in M3's plan: without
it, a value written in WB is invisible to an instruction reading in ID, and
programs silently compute wrong answers.

## Branch handling — nothing implemented

| Feature | Source | Method | Env | Coverage | Status | Owner |
|---|---|---|---|---|---|---|
| Static backward-taken / forward-not-taken | §3.2 phase 1 | — | — | none | **Deferred** | M3 |
| Misprediction recovery | §3.2 | — | — | none | **Deferred** | M3 |
| Bimodal predictor, 64-entry BTB | §3.2 phase 2 | — | — | none | **Deferred** | M6 |
| 2-bit saturating counter state transitions | §3.2 phase 2 | — | — | none | **Deferred** | M6 |
| Before/after CoreMark/MHz measurement | §3.2 | — | — | none | **Deferred** | M6 |

## Memory subsystem — nothing implemented

| Feature | Source | Method | Env | Coverage | Status | Owner |
|---|---|---|---|---|---|---|
| Tightly-coupled memory, 4–8 KB | §3.3 | — | — | none | **Deferred** | M3 |
| Boot ROM | §3.3 | — | — | none | **Deferred** | M5 |
| I-cache, 2 KB direct-mapped | §3.3 phase 2 | — | — | none | **Deferred** | M6 |
| D-cache, write-through + write buffer | §3.3 phase 2 | — | — | none | **Deferred** | M6 |
| Cache hit / miss / eviction coverage | §5.2 env 6 | — | — | none | **Deferred** | M6 |

## Bus and SoC — nothing implemented

| Feature | Source | Method | Env | Coverage | Status | Owner |
|---|---|---|---|---|---|---|
| AXI4-Lite fabric | §3.4, D3 | — | — | none | **Deferred** | M5 |
| AXI protocol checkers | §5.2 env 5 | — | — | none | **Deferred** | M5 |
| UART (16550-lite) | §3.4 | — | — | none | **Deferred** | M5 |
| QSPI master | §3.4 | — | — | none | **Deferred** | M5 |
| GPIO | §3.4 | — | — | none | **Deferred** | M5 |
| CLINT timer and software interrupts | §3.4 | — | — | none | **Deferred** | M5 |
| Boot from simulated SPI flash | §7 M5 gate | — | — | none | **Deferred** | M5 |

## Compressed instructions (C extension)

| Feature | Source | Method | Env | Coverage | Status | Owner |
|---|---|---|---|---|---|---|
| 16-bit instruction decode | C ext. | — | — | none | **Deferred** | M4 |
| Expansion to the 32-bit equivalent | C ext. | — | — | none | **Deferred** | M4 |
| Mixed 16/32-bit instruction streams | C ext. | — | — | none | **Deferred** | M4 |
| Unaligned 32-bit fetch across a boundary | C ext. | — | — | none | **Deferred** | M4 |
| IALIGN=16 effect on `mepc` | C ext. + priv. | UVM | 4 | `mepc[0]` field RO | **Partial** | M4 |

## Physical implementation

Not functional verification, but part of the project's gate criteria.

| Feature | Source | Method | Status | Evidence |
|---|---|---|---|---|
| ALU closes 50 MHz, all corners | §3.5 | LibreLane STA | Covered | `docs/results/0003` |
| muldiv closes 50 MHz | §3.5 | LibreLane STA | **FAILS — closes 43.5 MHz** | `docs/results/0006` |
| regfile closes 50 MHz | §3.5 | LibreLane STA | Covered | `docs/results/0007` |
| CSR closes 50 MHz | §3.5 | LibreLane STA | Covered | `docs/results/0009` |
| Full SoC closes 50 MHz | §3.5 | — | **Deferred** | M7 |
| DRC / LVS / antenna clean per block | §3.5 | Magic, KLayout, Netgen | Covered | results 0003, 0006, 0007, 0009 |
| Scan insertion, ATPG ≥90% | §3.5 | — | **Deferred** | M8 |

## Summary for this file

| Status | Count |
|---|---|
| Covered | 15 |
| Partial | 1 |
| Deferred | 36 |
| Failing | 1 |

**36 Deferred rows.** The register file is verified; nothing that connects the
four blocks into a CPU exists yet. That is an accurate picture of a project
that has finished its leaf blocks and not started integration.

The one **Failing** row — muldiv at 43.5 MHz against a 50 MHz target — is
recorded rather than hidden. It is a standalone measurement with estimated
constraints, and M7 re-times it inside a real floorplan.
