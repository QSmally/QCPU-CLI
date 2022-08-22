
// var object: Something = Something.create()
// var location: &Something = &object
// var second_byte: Byte = location + 1

@ReferenceType
struct Reference<Object>: UInt {

    asm operator +(lhs: Reference, rhs: UInt) -> Object {
        @PREPARE:REGISTERS rhs
        @PREPARE:ACCUMULATOR lhs
        ADD rhs
        FWD
        MLD forwarded, 0x00
        @RETURNS
    }

    asm operator +(lhs: Reference, rhs: @UInt) -> Object {
        @PREPARE:LOCAL lhs
        MLD lhs, rhs
        @RETURNS
    }
}
