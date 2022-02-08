# `Macros`

A macro is an operand shortcut to make a programmer's life easier and more organised.

## Overview

Marcos defined with `@DECLARE` are always bound to the file they're defined in.

```asm
@DECLARE maximum_value 24
@DECLARE compare_register 5

IMM 0, @maximum_value
SUB @compare_register
```

## Topics

### `Enumerations`

An enumeration is a group of macros with a namespace. Currently, only one can be defined per file, but that's subject to change in the future.

```asm
@ENUM <namespace>
    @DECLARE <case 0> <value 0>
    @DECLARE <case 1> <value 1>
    @DECLARE <case 2> <value 2>
@END
```

A particular enumeration case is accessible by `@<namespace>.<case>`.
