=== date ===
Thu Jul 30 08:06:22 UTC 2026
=== os ===
Linux Jeffery 6.6.114.1-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Mon Dec  1 20:46:23 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
PRETTY_NAME="Ubuntu 22.04.5 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION="22.04.5 LTS (Jammy Jellyfish)"
=== wsl ===
WSL detected
=== cpu/mem ===
20
               total        used        free      shared  buff/cache   available
Mem:           7.6Gi       407Mi       6.7Gi       3.0Mi       517Mi       7.1Gi
=== disk ===
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdd       1007G   23G  934G   3% /
/dev/sdd       1007G   23G  934G   3% /
=== python ===
Python 3.10.12
venv ok
=== pid1 (matters for Nix on WSL) ===
systemd
=== existing tools ===
git                           /usr/bin/git
make                          /usr/bin/make
curl                          /usr/bin/curl
nix                           absent
docker                        absent
yosys                         absent
verilator                     absent
iverilog                      absent
gtkwave                       absent
surfer                        absent
sv2v                          absent
slang                         absent
riscv64-unknown-elf-gcc       absent
riscv32-unknown-elf-gcc       absent
vivado                        absent
dsim                          absent

## Notes (2026-07-30)
- WSL2 memory raised to 10 GiB via .wslconfig (memory=11GB, swap=8GB).
- libfuse2 required for LibreLane AppImage; not documented upstream.
- LibreLane v3.0.5 smoke test PASSED.

## Notes (2026-07-30)
- WSL2 memory raised to 10 GiB via .wslconfig (memory=11GB, swap=8GB).
- libfuse2 required for LibreLane AppImage; not documented upstream.
- LibreLane v3.0.5 smoke test PASSED.
