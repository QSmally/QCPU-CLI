
@section foo
@entrypoint
@align 2

@err "init not found: %", @foo

_:                bkpt

@header foo, bar
@offset q, b
@alignop 2
                  bkpt
@end
