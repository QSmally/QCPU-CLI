
@symbols main, "sample.s"

@section root
@region 256
@align 2

_:                u16 .main.start   // entrypoint
                  u16 0             // interrupt
                  u16 0x0000        // CPU flags

@end

@linkinfo(origin) root, 0
@linkinfo(align) text, 256
@linkinfo(align) data, 256
