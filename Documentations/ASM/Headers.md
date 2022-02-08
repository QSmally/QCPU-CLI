# `Headers`

A header is an insertable block of code. At assemble-time, arguments are inserted like macros.

## Overview

Take the example from below. The three bytes, `CPA`, `JMP 0x00` and `0x00`, will be placed directly into the source component. Accessing this header is done with `@<header name>`, so `@RETURN` in this case. 

```asm
@HEADER RETURN

CPA
JMP 0, 0
```

## Topics

### `Arguments`

Each header can have a strict amount of arguments, and these are treated like macros (see `Macros.md`).

```asm
@HEADER GOTO jump_label

JMP 0
.@jump_label
```

In this example, the header already decodes the label with the `.` in front of it, so the argument must not have that: `@GOTO some_label`.

### `Multi-word arguments`

Trailing arguments can be extended to, virtually, infinity. It's identified with the `...` operator at the end of the argument name. It means arguments with a variable word length can be passed into the header initiator, like instructions with an operand. There's currently no test for multiple arguments, explicitly, so using multiple of them is considered to be undefined behaviour.

```asm
@HEADER PUSH_PORT port generator...

@generator...
PST 0, @port
```

Take the example from above to generate an accumulator value to push to some port. Note that the macro must also have the `...` operator.

```asm
@PUSH_PORT 5 AST 1
; port: 5
; generator...: AST 1

@PUSH_PORT 24 CPL
; port: 24
; generator...: CPL
```

### `Embedded labels`

Headers can generate labels, but the assembler throws an error if a duplicate label is used within the source file. Automatically generated labels could use the `%random` function to create labels.

```asm
@HEADER PSEUDO_CALL jump_label

@DECLARE return_label %random

CPS, .@return_label
JMP 0, .@jump_label
.@return_label:
```
