# Extended QCPU 2 assembly

Topics are featured in their own file, and generic syntaxes are below. 

### Numerics
* `255` - decimal
* `0xFF` - hexadecimal
* `0b11111111` - binary

### ASCII
* `$Q` - ascii letter
* `$CPU2` - ascii string

### Conditions
* `#cout`
* `#signed`
* `#zero`
* `#underflow`
* `#!cout`
* `#!signed`
* `#!zero`
* `#!underflow`

### Separators

A comma can be used to seperate instructions rather than newlines.

Per convention, it's mainly used to bind an immediate to the corresponding instruction, like `IMM 5, 24` or `JMP 0, .some_label`.

### Comments

Comments can be made using two prefixes:

* `//`
* `;`

Per convention, `//` is mostly used to describe modules like subroutines, execution files and headers. `;` can be used for inline comments and separating blocks of code that don't need a label, such as:

```asm
; main
    CND #cout
.start_loop:
    AST @base_register
    SUB @compare_register
; loop if the subtraction is positive
    BRH 0, .start_loop
; continue
    // ...
```
