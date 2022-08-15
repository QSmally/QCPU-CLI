
@Parsing(array)
struct Array<Element: Byte>#size {

    var container: Object#size

    nonmemory var pointer: &Object = &self.container

    asm inline func append(_ element: Element) {
        @PREPARE:ACCUMULATOR element
        MST self.pointer, 0x00
        INC self.pointer
    }

    asm inline func pull() -> Element {
        DEC self.pointer
        FWD
        MLD forwarded, 0x00
        @RETURNS
    }
}
