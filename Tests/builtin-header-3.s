
@header foo, num

@if !(num = 8)
@err "num=%d = 8, pass", num
@end

                  reserve u8, num

@end

@section root

                  foo 9
