# `Labels`

A label is the address of the byte it represents below it. In extended QCPU 2 assembly, they are used everywhere to address anything.  

## Overview

The most basic label is a page-private, low-byte insertion label.

```asm
.loop:
    JMP 0, .loop
```

## Topics

### `Page bits`

For instructions such as `PRF` (Prefetch), the upper 3 bit page address of a lable is needed, which is accessible with the `-` symbol: `.some_label-`.

### `High-byte`

As QCPU 2 has a privileged segment layer, the high byte is accessible with the `+` symbol: `.some_label+`.

### `Change label org`

The 5 bit line address of a page may be changed, perhaps to conform to addressing specifications due to the OR-merged pointers.

```asm
.string(16):
    $Something
    0x00
```

Please note that, if you set the address lower than has been used, you may override existing assembly.

### `Addressable`

Any file can be bound to an address, and it's equivalent to putting a normal label at the start of the file, but doesn't have drawbacks:

* Segment permission is public (there's no need to use `!`);
* It's mentioned inside of automatically-generated code documentation.

It's conventional to use an enum-like format with a namespace and subtext.

```asm
@ADDRESSABLE kernel.schedule_task
``` 

### `Segment public labels`

A label might be used on another page in the same segment, and an additional character must be used to identify such labels, to prevent conflicts between existing and page-private labels: `.&some_label:` 

### `Override segment error`

Above is mentioned that the label can be used across pages, but throws an error if the segment is different.

An override can be applied to omit the error, the `!` operator:

* `.some_label!`
* `.some_label!+`
