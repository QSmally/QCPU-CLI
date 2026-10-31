
@import foo, "builtin-define.s"

@define bar, foo.bar

@section root
@align foo.aaa

_:                bkpt

@barrier
@align bar

_:                bkpt
