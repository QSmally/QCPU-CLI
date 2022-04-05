# `Aliases`

An alias is a built-in instruction which compiles to another instruction during preprocessing.

## Overview

For backwards compatibility or keeping things clear in QCPU 2 assembly, there are references to other instructions by the use of aliases. They can be seen as headers but without any arguments to pass, and they can be used everywhere like instructions due to them being directly implemented into the assembler.

There are also operands which map to other values, because sometimes they differ per instruction.

## Topics

* `FWD` - instruction mapped to `RST 0`;
* `CLR` - instruction mapped to `AST 0`;
* `NOP` - instruction mapped to `ADD 0`;
* `accumulator`/`acc` - sometimes `0b000` is mapped to the accumulator;
* `zero`/`zer` - sometimes `0b000` is mapped to the zero register;
* `forwarded`/`fwd` - in context when the `FWD` and `zero` aliases are used.
