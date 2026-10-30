
@import file, "symbols-1.s"

@define foo, 5 + 3
@define doo, .bar.roo

@define xd, .file.namespace.xd

@section root

.bar:
.bar.roo:

; @err "%a", foo
; @err "%a", .bar
; @err "%a", doo
@err "%a", xd
; @err "%a", .file.xd
