# Extended QCPU 2 assembly

Topics are featured in their own file, and generic syntaxes are below. 

## Numerics
* `255` - decimal
* `0xFF` - hexadecimal
* `0b11111111` - binary

## ASCII
* `$Q` - ascii letter
* `$CPU2` - ascii string

## Conditions
* `#cout` (0b000)
* `#signed` (0b001)
* `#zero` (0b010)
* `#underflow` (0b011)
* `#!cout` (0b100)
* `#!signed` (0b101)
* `#!zero` (0b110)
* `#!underflow` (0b111)

## Separators

A comma can be used to seperate instructions from constants rather than newlines.

Per convention, it's mainly used to bind an immediate to the corresponding instruction, like `IMM 5, 24` or `JMP zer, .some_label`.

## Comments

Comments can be made using two prefixes: `//` and `;`.

* Per convention, `//` is mostly used to describe modules like subroutines, execution files and headers.
* `;` can be used for inline comments and separating blocks of code that don't need a label, such as:

```asm
.start_loop:
    AST @base_register
    SUB @compare_register
    RST @compare_register
; loop if the subtraction is positive
    BRH #cout, .start_loop
; continue
    // ...
```
