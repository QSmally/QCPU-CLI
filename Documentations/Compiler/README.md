#  QCPU HLL Compiler

Topics are featured in their own file, and general overview of the syntax is down below.

### Configuration

* `import Library`

**Built-ins (all both types and protocols)**
* `Byte` (singularly addressed data, alias to `Object#1`)
* `Object#size` (≥1 byte object of size `size`)
* `Reference<Type>` (pointer to `Type`, is a `Byte`, syntax sugar to `&Type`)

**Compiler messaging**
* `@Parsing(LiteralType) struct`
    - LiteralType `integer`, `boolean`, `array` or `any`
    - Passes literal context to compiler
* `@ReferenceType struct`
    - Attaching implementation to pointer type `&Type`
* `@ApplicationMain struct`
    - A struct to initialise when starting the application

### Variable management

* `var foo: Type = start_value`
* `let foo: Type = start_value`
* `mutate foo = foo operator bar`

**Allocation registers and references**
* `nonmemory var in_reg: ByteOrReference = start_value`
* `nonmemory var dyn_ref: Reference<Type> = &foo`
* `nonmemory var dyn_ref_sugar: &Type = &foo`

### Subroutines and embedded code

* `func foo() -> Type { }`
* `func foo(copyable bar: Type) -> Type { }`
* `func foo(mutable bar: Type) -> Type { }`
    - `returns some_typed_var`

**Embedded code and custom blocks**
* `inline func foo() -> Type { }`
* `inline func foo() [element: Element]: Bool -> Array<Element> { }`
    - `let ... = closure(element: ...)`

**Operators and constant parameters**
* `oper inc(target: Int) -> Int { }`
* `oper mod(lhs: Int, rhs: Int) -> Int { }`
* `oper mod(lhs: Int, rhs: @Int) -> Int { }`

**Assembly API**
* `asm oper -(lhs: Int, rsh: Int) -> Int { }`
* `asm inline func foo() -> Foo { }`
    - `@PREPARE:ACCUMULATOR <variable>`
    - `@PREPARE:REGISTERS <variable>`
    - `@PREPARE:LOCAL <variable>`
    - `@WRITEBACK <variable>`
    - `@RETURNS <variable>` or `@RETURNS` for accumulator
* `asm inline func conditional() flags(notzero) { }`

### Complex data types

**Enumerations**
* `enum Type { }`
    - `case one`

**Structures**
* `struct Something: SomeProtocol { }`
    - preprocessed `address` start pointer from compiler or kernel
    - value type init `shared clos create(...) -> Something { }`
    - dynamic init `shared clos create(...) -> &Something { }`
* `struct Something<GenericSomething: SomeProtocol>: OtherProtocol { }`
    - associated `GenericSomething` type
* `computed var`
* `lazy var`
* `shared func` or `shared inline func`
* `shared var` or `shared let`

**Protocols**
* `protocol Something { }`
    - `optional var` or `optional func`
    - `internal var` or `internal func`

**Modifiers and hosters**
* `modifier Something { }`
    - `func initialise`
    - `func willSet`
    - `func retrieve`
    - `@Something var`
