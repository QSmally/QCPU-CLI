
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
* `.label:` - page-private label
* `.&label:` - segment-scoped label
* `.label` - lower five bits
* `.label-` - lower byte
* `.label+` - upper byte
* `.label!` (+, -) - ignore scope error

## Immediate formats
* `255` - decimal
* `0xFF` - hexadecimal
* `0b11111111` - binary
* `$Q` - ascii letter
* `$CPU2` - ascii string

## Conditions
* `#true`
* `#cout`
* `#signed`
* `#zero`
* `#underflow`
* `#!cout`
* `#!signed`
* `#!zero`

## Assemble flags
* `DEBUG`
