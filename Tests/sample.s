
@import library, "Library.s"

; @define roo, 0x05
; @define(expose) foo, @roo

@header hdr, a
                  rst @a
@end

@section text
start:            cli
                  @hdr  @library.foo
                  jmpr  .library.spinlock

@section data
dead:             u8 255
@align 2
beef:             u16 @library.bar
