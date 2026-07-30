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
| PDK (sky130A) | TBD - capture ciel version/hash | fetched by LibreLane smoke test | |
| Yosys | TBD | bundled in LibreLane devshell | |
| OpenROAD | TBD | bundled in LibreLane devshell | |
| Magic | TBD | bundled in LibreLane devshell | |
| KLayout | TBD | bundled in LibreLane devshell | |
| Netgen | TBD | bundled in LibreLane devshell | |

## Verification stack
| Tool | Version | Licence | Expiry | Recorded |
|---|---|---|---|---|
| Altair DSim | TBD | Free Individual License | TBD (90 days from generation) | |
| Verilator | not yet installed | | | |
| Icarus Verilog | not yet installed | | | |
| GTKWave / Surfer | not yet installed | | | |
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
