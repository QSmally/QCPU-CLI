
@header foo, local
bkpt
@err "%a", local
@end

@section root

_local_label:     bkpt

; @err "%a", .local_label

xd:               foo .local_label
