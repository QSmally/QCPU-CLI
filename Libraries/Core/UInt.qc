
struct UInt: Byte {

    var container: Byte

    asm operator inc(target: UInt) -> UInt {
        @PREPARE local target
        INC target
    }

    asm operator dec(target: UInt) -> UInt {
        @PREPARE local target
        DEC target
    }

    // Left shift
    asm operator lsh(lhs: UInt, rhs: UInt) -> UInt {
        @PREPARE accumulator lhs
        @PREPARE registers rhs
        BPL rhs
    }

    asm operator lsh(lhs: UInt, rhs: @UInt) -> UInt {
        @PREPARE accumulator lhs
        BSL rhs
    }

    // Right shift
    asm operator rsh(lhs: UInt, rhs: UInt) -> UInt {
        @PREPARE accumulator lhs
        @PREPARE registers rhs
        BPR rhs
    }

    asm operator lsh(lhs: UInt, rhs: @UInt) -> UInt {
        @PREPARE accumulator lhs
        BSR rhs
    }
}
