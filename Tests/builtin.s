
@section root
@align 2
@entrypoint

_:                      jmpr .entrypoint

@section text
@align 2

@header Queue, len
      @align 2
      @offset queue, head
                        bkpt
      @offset queue, tail
                        bkpt
@end

.entrypoint:            bkpt

@if @foo
                        bkpt
@else
      @err "hello there"
@end

@barrier

                        bkpt

@linkinfo(origin) root, 0x0800
@linkinfo(align) text, 32

@buildinfo foo, 1

@define(expose, 5 + 3) bar, @foo * 5 + 5
@define roo, (@bar >> 8) * !3
@define doo, -@roo
@define zoo, "Hello world!" 1 + 2
