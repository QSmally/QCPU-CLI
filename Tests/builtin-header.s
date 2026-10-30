
@header Queue, xd
@align 2

@define aaa, xd

tail:             reserve u16, 1
head:             reserve u16, 1
mem:              reserve u8, aaa
@end

@section root
@align 2

@define roo, 24
@define bar, .my_queue
@define theheader, Queue

my_queue:         Queue roo
my_queue_1:       theheader bar
