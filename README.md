
# QCPU CLI

A software description of the QCPU 2 architecture

Tracks the [QCPU 2 specification](https://github.com/QSmally/QCPU). For older
versions written in Swift, see the [repository tags](https://github.com/QSmally/QCPU-CLI/tree/2CI).

## Installation

A compiled version of the CLI can be created through the Zig build system (Zig `0.14.1`).

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

## Contributing

The assembler has a lot of quirks, mainly for cross-file references (`@symbols`) with header
arguments and the Liveness pass. If you'd like to contribute to this project, you can take a look at
all the `fixme` comments. Most of these TODOs reside in the semantic analysis unit.
