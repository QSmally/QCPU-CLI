
# QCPU CLI

> A CLI for compiling Q-code, assembling extended QCPU 2 assembly and emulating machine code.

## Tags
* `@PAGE <upper> <lower>`
* `@HEADER <label> <arguments...?>`
* `@ADDRESSABLE <namespace>.<label>`
* `@OVERFLOWABLE`
* `@MAKEPAGE <name> <upper> <lower>`

**Marcos**
* `@DECLARE <label> <value>` - private-page marco
* `@<macro or header> <header arguments...>` - insert marco/header

**Indented**
* `@IF <CLI flag>` - conditional code
* `@IF !<CLI flag>` - inverse conditional code
* `@DROPTHROUGH <instruction>` - ignores if-scope
* `@ELSE` - negates if-scope
* `@ENUM <namespace>` - public marco-group
* `@END` - closing indent

## Functions
* `%random`
* `%array <size> <repeated ascii value>`

## Addressing
* `.label:` - page-private label
* `.&label:` - segment-scoped label
* `.[&]label(16):` - change address

**Embedded**
* `.label` - lower byte 
* `.label+` - segment byte
* `.label![+]` - ignore scope error

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
