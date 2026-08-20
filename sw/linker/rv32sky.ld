/* RV32-SKY linker script.
 *
 * MEMORY MAP (docs/results/0013-core-bringup.md):
 *   0x0000_0000 .. 0x0000_1FFF   8 KB TCM, unified instruction and data
 *   0x8000_0000                  test control (a store here ends the run)
 *   0x8000_0004                  console
 *
 * TOHOST. Both Sail and the ACT4 compliance framework terminate on a write to
 * a symbol named `tohost`. Without it Sail runs the halt loop forever - the
 * first attempt produced a 10.5 GB trace in seconds.
 *
 * `tohost` is placed at 0x1000, halfway up the TCM and clear of the code.
 * The Verilator harness keeps its own 0x8000_0000 convention; the two coexist,
 * so one binary terminates cleanly under both.
 *
 * Data is placed AFTER the code deliberately. An earlier test program used
 * address 0x100 for data, inside the instruction stream: a store overwrote a
 * NOP and the fetch unit read 0xdeadbeef back as an instruction.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  TCM (rwx) : ORIGIN = 0x00000000, LENGTH = 8K
}

SECTIONS
{
  .text 0x00000000 : {
    *(.text.init)
    *(.text)
    *(.text.*)
  } > TCM

  .rodata : { *(.rodata) *(.rodata.*) } > TCM

  /* HTIF communication area at a FIXED address, clear of the code.
   *
   * The section needs an explicit load address, not just a location-counter
   * assignment before it - the counter form was ignored and tohost landed at
   * 0x124, immediately after .text. That is inside the instruction stream for
   * any program longer than ~300 bytes, so a write to it would corrupt code:
   * exactly the failure recorded in docs/results/0013 where a store to 0x100
   * overwrote a NOP with 0xdeadbeef.
   *
   * 0x1000 is halfway up the 8 KB TCM and clear of every current program
   * (largest .text is 1,088 bytes).
   */
  .tohost 0x00001000 : {
    /* Plain assignment, NOT PROVIDE(). PROVIDE only defines a symbol if
       something references it, and until the test programs actually write to
       tohost nothing does - so the symbol was silently discarded and Sail
       reported "Unable to locate tohost symbol". */
    tohost   = .;
    . += 8;
    fromhost = .;
    . += 8;
  } > TCM

  /* Test data after the HTIF area, also at a fixed address. */
  .data 0x00001100 : { *(.data) *(.data.*) } > TCM
  .bss  : { *(.bss)  *(.bss.*) *(COMMON) } > TCM

  _end = .;
}
