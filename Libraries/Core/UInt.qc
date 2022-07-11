
@Parsing(integer)
@ReferenceType
struct UInt {

    var container: Byte

    // Increment
    asm operator inc(target: UInt) -> UInt {
        @PREPARE:LOCAL target
        INC target
        @RETURNS target
    }

    // Decrement
    asm operator dec(target: UInt) -> UInt {
        @PREPARE:LOCAL target
        DEC target
        @RETURNS target
    }

    // Addition
    asm operator +(lhs: UInt, rhs: UInt) -> UInt {
        @PREPARE:REGISTERS rhs
        @PREPARE:ACCUMULATOR lhs
        ADD rhs
        @RETURNS
    }

    // Left shift
    asm operator lsh(lhs: UInt, rhs: UInt) -> UInt {
        @PREPARE:REGISTERS rhs
        @PREPARE:ACCUMULATOR lhs
        BPL rhs
        @RETURNS
    }

    asm operator lsh(lhs: UInt, rhs: @UInt) -> UInt {
        @PREPARE:ACCUMULATOR lhs
        BSL rhs
        @RETURNS
    }

    // Right shift
    asm operator rsh(lhs: UInt, rhs: UInt) -> UInt {
        @PREPARE:REGISTERS rhs
        @PREPARE:ACCUMULATOR lhs
        BPR rhs
        @RETURNS
    }

    asm operator lsh(lhs: UInt, rhs: @UInt) -> UInt {
        @PREPARE:ACCUMULATOR lhs
        BSR rhs
        @RETURNS
    }
}
