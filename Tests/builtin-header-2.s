
@header(expose) Queue, xd
@align 2

@define aaa, xd

tail:             reserve u16, 1
head:             reserve u16, 1
mem:              reserve u8, aaa
@end
