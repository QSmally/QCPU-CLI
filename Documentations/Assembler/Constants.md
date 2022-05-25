# `Constants`

Arithmetic and logic functions on preprocessor constants, including labels.

## Overview

The order of calculation is from left-to-right, with no support for braces or operator priority.

Take this example, `.array_end_label & 0x1F`; It filters out the lower 5 bits of the label, giving the size of the array given that it starts at `0b###00000`. It's possible to calculate the size with `.array_end_label - .array_start_label` as well.

The `.label-` operator can be simulated with `.label and 0xE0 rsh 5`.

## Topics

* `add`, `+`: adds lhs and rsh together;
* `sub`, `-`: subtracts rhs from lhs;
* `ior`, `|`: bitwise OR to insert bits;
* `and`, `&`: bitwise AND to filter out bits;
* `xor`, `^`: bitwise XOR to invert certain bits.

### Advanced

* `lsh`: shifts lhs to the left rsh times;
* `rsh`: shifts lhs to the right rsh times;
* `mul`: multiplies lhs and rsh;
* `div`: divides lhs by rsh, returns full integer;
* `mod`: returns the remainder of division.
