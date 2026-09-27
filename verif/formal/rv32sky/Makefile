# riscv-formal driver for RV32-SKY. M3.6.
#
# Lives in the repo at verif/formal/rv32sky/Makefile and is symlinked into
# ~/src/riscv-formal/cores/rv32sky/. genchecks.py derives the core name from
# the CURRENT DIRECTORY NAME (genchecks.py:39) and basedir from ../.. (:38), so
# this only works when run from inside riscv-formal's cores/<name>/ directory -
# not from the repo.

.PHONY: checks one clean

# Regenerate every .sby and its makefile, then run all of them.
#
# READ THE CHECK COUNT, not the exit status. If insns/isa_rv32i.txt were
# missing, genchecks prints "skipping instruction checks" to stderr, generates
# the consistency checks only, and still exits 0 (genchecks.py:554).
checks:
	python3 ../../checks/genchecks.py
	$(MAKE) -C checks

# Run ONE generated check, for bring-up:  make one CHECK=insn_add_ch0
# Generating without running everything is the point - the first check is a
# test of the plumbing, not of the core, and nine failures all caused by one
# broken define is nine times the log for the same information.
one:
	python3 ../../checks/genchecks.py
	@test -n "$(CHECK)" || { echo "usage: make one CHECK=<name>   e.g. insn_add_ch0"; exit 2; }
	@test -f checks/$(CHECK).sby || { \
	    echo "ERROR: checks/$(CHECK).sby was not generated."; \
	    echo "       Generated .sby files are:"; \
	    ls checks/*.sby; \
	    exit 2; }
	$(MAKE) -C checks $(CHECK)

clean:
	rm -rf checks cexdata
