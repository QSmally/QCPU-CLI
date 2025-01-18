
# QCPU CLI

A hardware description of the QCPU 2 architecture

Tracks the [QCPU 2 specification](https://github.com/QSmally/QCPU). For older
versions written in Swift, see the [repository tags](https://github.com/QSmally/QCPU-CLI/tree/2CI).

## Installation

A compiled version of the CLI can be created through the Zig build system (Zig
`0.14.0-dev.2647+5322459a0`).

```bash
$ zig build
```

## Tests

QCPU CLI comes with use cases written as tests.

```bash
$ zig build test
```

An inspection dump can be done with `-Ddump`.

```bash
$ zig build test -Ddump
```
