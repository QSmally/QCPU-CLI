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
* `weak var in_reg: ByteOrReference = start_value`
* `weak var dyn_ref: Reference<Type> = &foo`
* `weak var dyn_ref_sugar: &Type = &foo`

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
* `asm clos foo() -> Foo { }`
    - `@PREPARE:ACCUMULATOR <variable>`
    - `@PREPARE:REGISTERS <variable>`
    - `@PREPARE:LOCAL <variable>`
    - `@WRITEBACK <variable>`
    - `@RETURNS <variable>`

### Complex data types

**Enumerations**
* `enum Type { }`
    - `case one`

**Structures**
* `struct Something: SomeProtocol { }`
    - preprocessed `address` start pointer constant
    - value type init `shared clos create(...) -> Something { }`
    - dynamic init `shared clos create(...) -> &Something { }`
* `struct Something<GenericSomething: SomeProtocol>: SomeProtocol { }`
    - associated `GenericSomething` type
* `computed var`
* `lazy var`
* `shared func` or `shared clos`
* `shared var` or `shared let`

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
