
@Literal<integer>
struct UInt: Byte {

    var container: Byte

    asm operator inc(target: UInt) -> UInt {
        @PREPARE:LOCAL target
        INC target
    }

    asm operator dec(target: UInt) -> UInt {
        @PREPARE:LOCAL target
        DEC target
    }

    // Left shift
    asm operator lsh(lhs: UInt, rhs: UInt) -> UInt {
        @PREPARE:ACCUMULATOR lhs
        @PREPARE:REGISTERS rhs
        BPL rhs
    }

    asm operator lsh(lhs: UInt, rhs: @UInt) -> UInt {
        @PREPARE:ACCUMULATOR lhs
        BSL rhs
    }

    // Right shift
    asm operator rsh(lhs: UInt, rhs: UInt) -> UInt {
        @PREPARE:REGISTERS rhs
        @PREPARE:ACCUMULATOR lhs
        BPR rhs
    }

    asm operator lsh(lhs: UInt, rhs: @UInt) -> UInt {
        @PREPARE:ACCUMULATOR lhs
        BSR rhs
    }
}
