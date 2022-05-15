
struct UInt: Byte {

    var container: Byte

    asm operator inc(target: UInt) -> UInt {
        INC target
    }

    asm operator dec(target: UInt) -> UInt {
        DEC target
    }

    // Left shift
    asm operator lsh(lhs: UInt, rhs: UInt) -> UInt {
        @ACCUMULATOR lhs
        BPL lhs
    }

    asm operator lsh(lhs: UInt, rhs: @UInt) -> UInt {
        @ACCUMULATOR lhs
        BSL lhs
    }

    // Right shift
    asm operator rsh(lhs: UInt, rhs: UInt) -> UInt {
        @ACCUMULATOR lhs
        BPR lhs
    }

    asm operator lsh(lhs: UInt, rhs: @UInt) -> UInt {
        @ACCUMULATOR lhs
        BSR lhs
    }
}
