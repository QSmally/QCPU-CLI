
@section text

@offset(expose) foo, bar

@if @foo
                  bkpt
@offset(expose) foo, aaa
                  bkpt
                  ascii "Hello world" 0xFF
@offset(expose) foo, bbb
                  bkpt
                  @err "hello"
                  bkpt
@else
                  bkpt
@offset(expose) foo, bar
                  bkpt
@end
