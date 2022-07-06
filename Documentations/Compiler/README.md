#  QCPU HLL Compiler

Topics are featured in their own file, and general overview of the syntax is down below.

### Configuration

* `import Library`

**Built-ins (all both types and protocols)**
* `Byte` (singularly addressed data, alias to `Object#1`)
* `Object#size` (≥1 byte object of size `size`)
* `Reference<Type>` (pointer to `Type`, syntax sugar to `&Type`)

**Compiler messaging**
* `@Literal<LiteralType> struct` with LiteralType `integer`, `boolean`, `array<LiteralType>`, or all (`any`)

### Variable management

* `var foo: Type = start_value`
* `let foo: Type = start_value`
* `mutate foo = foo operator bar`
* TODO: configure syntax literals for arrays, strings (char arrays), numerics, etc

**Allocation registers and references**
* `weak var in_reg: ByteOrReference = start_value`
* `weak var dyn_ref: Reference<Type> = &foo`
* `weak var dyn_ref_sugar: &Type = &foo`
* TODO: generic pointer types and operations (UInt, Byte)

### Subroutines and embedded code

* `func foo() -> Type { }`
* `func foo(copyable bar: Type) -> Type { }`
* `func foo(mutable bar: Type) -> Type { }`

**Embedded code and custom blocks**
* `clos foo() -> Type { }`
* `clos foo() [element: Element]: Bool -> Array<Element> { }`

**Operators and constant parameters**
* `oper inc(rhs: Int) -> Int { }`
* `oper mod(lhs: Int, rhs: Int) -> Int { }`
* `oper mod(lhs: Int, rhs: @Int) -> Int { }`

**Assembly API**
* `asm oper -(lhs: Int, rsh: Int) -> Int { }`
    - `@PREPARE <target> <variable>` with target `accumulator`, `registers`, or both (`local`)
    - `@WRITEBACK <variable>`
    - `@RETURNS <variable>`

### Complex data types

**Enumerations**
* `enum Type { }`
    - `case one`

**Structures**
* `struct Something: SomeProtocol { }`
    - `computed var`
    - `lazy var`
    - `shared func` or `shared clos`
    - `shared var` or `shared let`
    - preprocessed `size` constant
    - preprocessed `address` start pointer constant

**Protocols**
* `protocol Something { }`
    - `optional var`
    - `internal var`

**Modifiers and hosters**
* `modifier Something { }`
    - `func initialise` or `clos initialise`
    - `func willSet` or `clos initialise`
    - `func retrieve` or `clos retrieve`
    - `@Something var`
