
# QCPU CLI

QCPU assembly language

Tracks the [QCPU 2 specification](https://github.com/QSmally/QCPU). For older
versions written in Swift, see the [repository tags](https://github.com/QSmally/QCPU-CLI/tree/2CI).

## Installation

A compiled version of the CLI can be created through the Zig build system (Zig `0.17.0`).

```bash
$ zig build
```

Listing of the available options is done using the `--help` option:

```bash
$ zig-out/bin/qcpu --help
```

Read also: [QCPU language reference](https://qcpu.qsmally.org/pages/assembly)

## Tests

QCPU CLI comes with use cases written as tests.

```bash
$ zig build test
```

There are test files in `Tests/`, which can be inspected with:

```bash
$ zig-out/bin/qcpu --dlinker [--verbose] Tests/name-of-test.s
```

Or ran with:

```bash
$ zig-out/bin/qcpu --virtualise [--step] Tests/name-of-test.s
```

## Contributing

Contributions with the help of LLMs/AI tools will be rejected. Otherwise, thanks!
