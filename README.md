
# QCPU CLI

> A CLI for compiling Q-code, assembling extended QCPU 2 assembly and emulating machine code.

## Tags
* `@PAGE <upper> <lower>`
* `@HEADER <label> <arguments...?>`
* `@ADDRESSABLE <namespace>.<label>`
* `@OVERFLOWABLE`

**Marcos**
* `@DECLARE <label> <value>`

**Indented**
* `@IF <flag>`
* `@ENUM <namespace>`
* `@END`

## Functions
* `%random`
* `%array <size> <values...?>`

## Addressing
* `.label:` - define label
* `.label` - lower five bits
* `.label-` - lower byte
* `.label+` - upper byte

## Flags
* `DEBUG`

## Flags

* `#true`
* `#cout`
* `#signed`
* `#zero`
* `#underflow`
* `#!cout`
* `#!signed`
* `#!zero`
