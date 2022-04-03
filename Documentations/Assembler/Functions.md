# `Functions`

Provided by the assembler, functions provide predictable shortcuts to the programmer.

### `%random`

Generates a random string of characters, and it's mainly used to make labels in headers to prevent duplication conflicts by the insertion of multiple headers.

```asm
@DECLARE return_segment_label %random

CPS, @return_segment_label+
CAL @some_call_label 
.@return_segment_label:
```

### `%array <size> <value?>`

Repeats `<value>`, or 0, `<size>` times.
