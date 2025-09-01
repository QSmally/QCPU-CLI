
@section root
@region 256
@align 2

_:                u16 .foo

@end

@linkinfo(origin) root, 0
@linkinfo(align) example, 256
@linkinfo(align) example2, 256
@linkinfo(align) example3, 256
@linkinfo(align) example4, 256
@linkinfo(align) example5, 256

; this section is referenced by the root section
@section example
foo:              u16 .example2

; this section is referenced by a section from the root tree
@section example2
example2:         u8 0xEA

; next sections are referencing each other, but are unreachable otherwise
@section example3
example3:         u16 0xFFFF lsh 8  ; this overflows u16, but it's not evaluated by the linker
                  u16 .example4

@section example4
example4:         u16 .example3

; this section is not referenced, but has the noelimination option
@section(noelimination) example5
example5:         u16 0xDEAD
