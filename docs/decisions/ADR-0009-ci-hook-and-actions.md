# ADR-0009: CI is a pre-push hook for L0 and GitHub Actions for L0 + L1
**Date:** 2026-11-04 (decided 2026-10-28; implemented `9cd05c0` to `835e265`)
**Status:** Accepted

## Context

Until M3.7 every check in this project ran when someone remembered to run it, on one
machine, in whatever shell was open. Three recorded results had already passed
silently for reasons a routine run would have caught (`0018`, `0028`, `0030` §4.1), and
sourcing the OSS CAD Suite swaps Verilator 5.053 in for the pinned 5.050 without a word
(`0026`). PROJECT_CONTEXT §5.3 asks that every result be reproducible from what the
repository pins; until a clean machine had run it, that was a claim.

Constraints: solo project, public repo, no budget. L0 (static checks) takes under a
second; L1 (lockstep, coverage, classification) about 6 s on the dev machine. Formal and
slang need the OSS CAD Suite.

Facts the decision rests on (T2, GitHub documentation, read during M3.7 planning,
late October 2026): standard
GitHub-hosted runners are free for public repositories, 4 CPU / 16 GB / 14 GB SSD; the
`ubuntu-22.04` label exists; a job is limited to 6 h; the cache limit is 10 GB per
repository; GitHub advises against self-hosted runners on public repositories.

## Options considered

1. **A. Local only: a pre-push hook running L0 and L1.** Pros: no external service.
   Cons: proves nothing about a clean machine; the hook is per-clone and bypassable; L1
   on every push is slow enough that it would be bypassed.
2. **B. GitHub Actions only, L0 + L1.** Pros: clean-room reproduction on every push.
   Cons: a bad push is found minutes later, after it is public.
3. **C. Both: the hook runs L0 (under a second), Actions runs L0 + L1 in a bare
   `ubuntu:22.04` container.** Pros: cheap mistakes stop before they leave the machine;
   the clean machine is the gate. Cons: two places to maintain; the container must
   install every tool itself.
4. **Self-hosted runner on the dev machine.** Rejected: GitHub advises against it for
   public repositories, and it would test the dev machine, not a clean one.

Within C, two sub-decisions:

- **Formal and slang stay out of CI for M3.7.** Bringing in the OSS CAD Suite brings in
  its Verilator 5.053; keeping CI to plain packages keeps the pinned 5.050 the only
  Verilator present. slang lint is deferred, not dropped.
- **The CI container is bare `ubuntu:22.04`**, the dev machine's release, rather than the
  runner image, so a tool missing from `tools/versions.md` fails CI instead of being
  supplied by GitHub's image.

## Decision

Option C, with formal and slang deferred, in a bare `ubuntu:22.04` container pinned by
digest (`sha256:076e7bf8…`).

## Rationale

Measured, `0030`:

- L0 is 0.61-0.71 s locally, so the hook costs nothing worth bypassing.
- CI reproduced `0028`'s numbers exactly from nothing but the repository's pins, on two
  clean runs a week apart with 186 identical packages.
- The deliberate fault (run #2) was let through by the hook, as designed, and failed CI
  at L1 on three independent detectors.
- Every check at both levels has a mutant that makes it fail: 26 of 26 at L0, 11 of 11
  at L1.

The bare container forced every dependency to be named in the workflow: binutils for
`sw/tests` is pinned by exact apt version so the rebuilt `.hex` files match byte for
byte, and Sail is pinned by release and hash because two different binaries report
`0.13.1` (`0030` §4.3).

## Consequences

- **Every push is checked on a clean machine.** A result that only one machine can
  produce now fails visibly.
- **Two pins must move together:** the container digest appears in `container:` and in
  the Verilator cache key. Changing the image is a deliberate step and costs one cold
  build (4 m 43 s to 7 m 20 s measured).
- **The hook is advisory.** It is per-clone (`git config core.hooksPath tools/hooks`)
  and `--no-verify` skips it. CI is the gate.
- **Not covered by CI:** formal (SBY, riscv-formal), slang lint, UVM env 7, ACT4 ELF
  generation (GCC 16.1.0 is not in the container; the committed ELFs and their manifest
  are checked instead).
- **Revisit** when slang lint or formal is wanted in CI: the OSS CAD Suite would need to
  be installed without its Verilator on PATH, and `tools/guards.mk` would need to be
  shown to catch it if it were.
