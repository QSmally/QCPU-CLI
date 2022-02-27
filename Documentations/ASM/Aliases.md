# `Aliases`

An alias is a built-in instruction which compiles to another instruction during preprocessing.

## Overview

For backwards compatibility or keeping things clear in QCPU 2 assembly, there are references to other instructions by the use of aliases. They can be seen as headers but without any arguments to pass, and they can be used everywhere like instructions due to them being directly implemented into the assembler.

## Topics

* `NOP` - mapped to `ADD 0`.

## Future implementations

* `accumulator` - for some instructions, either `0b000` or `0b111` are mapped to the accumulator. 
