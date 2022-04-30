# `Preprocessor`

A list of generic and miscellaneous tags.

### `@PAGE <upper> <lower>`

Attaches the 8 bit segment address and 3 bit page address to the file.

### `@OVERFLOWABLE`

If the 5 bit lower address overflows, increments the 3 bit page address and continues with writing instructions to that component.

On the occasion that it may override an existing component with that address, it throws an error.

**Known issue**: a string made with this `$operator` does not trigger an overflow.

### `@MAKEPAGE <name> <upper> <lower>`

Solely for naming an empty (data) component, it's only visible in the emulator.

### `@IF <cli flag>` / `@IF !<cli flag>` / `@ELSE`

A conditional block of code, and must end with the `@END` tag like with `@ENUM` blocks.

```asm
@IF unsafe-block
    .lock:
        JMP 0, .lock
@END
```

Take the case above, it will only process the block when `--unsafe-block` is present in the CLI arguments. In retrospect, it can be negated by adding an `@ELSE` block to the end of the if-block, moving the `@END` tag below.

```asm
@IF something
    // if something
@ELSE
    // if not something
@END
```

### `@DROPTHROUGH <byte>`

Always ignores the if-scope.

```asm
AST 1
@IF debug
    PST 0, 0
    @DROPTHROUGH BRH #zero, .loop
    JMP 0, .breakpoint
@END
```
