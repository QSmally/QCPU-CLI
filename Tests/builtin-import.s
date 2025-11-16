
@import awd, "builtin.s"

@define foo, 5 + 3
@define bar, 234

@header Queue, x, y, bar
@entrypoint
@define foo, 123
@end
