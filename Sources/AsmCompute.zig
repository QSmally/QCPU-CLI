
// Compute

const std = @import("std");
const instruction = @import("instruction.zig");
const Qcu = @import("Qcu.zig");
const SourceFile = @import("SourceFile.zig");
const Token = @import("Token.zig");
const Error = @import("Error.zig");
const AsmAst = @import("AsmAst.zig");
const AsmIr = @import("AsmIr.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");

const AsmCompute = @This();

allocator: std.mem.Allocator,
file_index: Qcu.File.List.Index,
source_file: *const SourceFile,
tree: *const AsmAst,
ir: *const AsmIr,
scope: ?*const AsmSemanticAir,
bridge: Bridge,

pub fn init(
    allocator: std.mem.Allocator,
    file_index: Qcu.File.List.Index,
    source_file: *const SourceFile,
    tree: *const AsmAst,
    ir: *const AsmIr,
    scope: ?*const AsmSemanticAir,
    bridge: Bridge
) AsmCompute {
    return .{
        .allocator = allocator,
        .file_index = file_index,
        .source_file = source_file,
        .tree = tree,
        .ir = ir,
        .scope = scope,
        .bridge = bridge };
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    vtable: VTable,
    context: *anyopaque,

    pub const VTable = struct {
        emitError: *const fn (*anyopaque, Error) AllocatorError!void,
        createScope: *const fn (*anyopaque, Qcu.File.List.Index, ?*const AsmSemanticAir) AsmCompute
    };

    fn emitError(self: *const Bridge, err: Error) !void {
        return try self.vtable.emitError(self.context, err);
    }

    fn createScope(
        self: *const Bridge,
        file_index: Qcu.File.List.Index,
        scope: ?*const AsmSemanticAir
    ) AsmCompute {
        return self.vtable.createScope(self.context, file_index, scope);
    }
};

pub const Result = union(Type) {

    scalar: ScalarType,
    linker_address: LinkerAddressType,
    header: HeaderType,
    register: RegisterType,
    index: IndexType,
    flag: FlagType,
    size: SizeType,
    string: StringType,

    pub const Type = enum(u3) {

        scalar,
        linker_address,
        header,
        register,
        index,
        flag,
        size,
        string,

        pub fn fmt(self: Type) []const u8 {
            return switch (self) {
                .scalar => "a constant value",
                .linker_address => "an address",
                .header => "a @header",
                .register => "a register",
                .index => "an indexable register",
                .flag => "a flag",
                .size => "a size type",
                .string => "a string",
            };
        }
    };

    pub const Comparison = packed struct {
        lhs: Type,
        rhs: Type
    };

    pub fn cmp(lhs: Type, rhs: Type) Comparison {
        return .{ .lhs = lhs, .rhs = rhs };
    }

    pub const ScalarType = struct {
        folded_token: SourceFile.Token,
        value: ComputeTimeInt
    };

    pub const LinkerAddressType = struct {
        folded_token: SourceFile.Token,
        linker_address: instruction.LinkerAddress,

        pub fn fromScalar(scalar: ScalarType) LinkerAddressType {
            return .{
                .folded_token = scalar.folded_token,
                .linker_address = .{
                    .dynamic = null,
                    .bit_mask = 0,
                    .offset = scalar.value } };
        }
    };

    pub const HeaderType = struct {
        folded_token: SourceFile.Token,
        file_index: Qcu.File.List.Index,
        block_index: AsmIr.Block.List.Index
    };

    pub const RegisterType = struct {
        folded_token: SourceFile.Token,
        register: instruction.Register
    };

    pub const IndexType = struct {
        folded_token: SourceFile.Token,
        register: instruction.Register.AddressRegister,
        mode: Mode,

        pub const Mode = union(enum) {
            linker_address: instruction.LinkerAddress,
            predecrement,
            postincrement
        };
    };

    pub const FlagType = struct {
        folded_token: SourceFile.Token,
        flag: instruction.Flag
    };

    pub const SizeType = struct {
        folded_token: SourceFile.Token,
        bytes: u32
    };

    pub const StringType = struct {
        folded_token: SourceFile.Token,
        text: []const u8,
        sentinel: ?u8
    };

    pub fn getFoldedToken(self: Result) SourceFile.Token {
        return switch (self) {
            inline else => |result| result.folded_token
        };
    }
};

pub const ComputeTimeInt = i32;

const EvaluationError = error {
    TypeCast,
    InvalidOperation,
    ParseError,
    SentinelSize,
    InvalidModifier,
    Expected,
    AmbiguousIdentifier,
    UnknownSymbol,
    PrivateSymbol,
    SymbolType,
    NamespaceSymbol,
    IndexAddressRegister,
    DependencyLoop,
    NoteDefinedHere,
    NoteEvaluatedFromHere,
    Note
};

fn addError(
    self: *const AsmCompute,
    comptime err: EvaluationError,
    token: SourceFile.Token,
    comptime format: []const u8,
    arguments: anytype
) !void {
    @branchHint(.cold);

    const message = try self.allocator.print(format, arguments);
    errdefer self.allocator.free(message);

    try self.bridge.emitError(.{
        .err = err,
        .token = token.inner_token,
        .source_file = token.source_file,
        .is_note = switch (err) {
            error.NoteDefinedHere,
            error.NoteEvaluatedFromHere,
            error.Note => true,
            else => false
        },
        .is_preview = err != error.Note,
        .message = message });
}

fn explainTypeCastError(
    self: *const AsmCompute,
    ty: Result.Type,
    result: Result,
    expression_token: Token
) !noreturn {
    const folded_token = result.getFoldedToken();
    const expression_qualified_token = self.source_file.qualifiedToken(expression_token);
    const result_tag = std.meta.activeTag(result);

    try self.addError(error.TypeCast, expression_qualified_token, "expected {s}, found {s}", .{
        ty.fmt(),
        result_tag.fmt() });

    // TODO: We have no way of knowing whether the result was folded through
    // parameters, and we don't have the stack to unroll from here
    if (self.scope) |the_scope| if (the_scope.deferred_symbols.get(expression_qualified_token.slice()[1..])) |the_deferred_symbol| {
        const qualified_token = self.source_file.qualifiedToken(the_deferred_symbol.token);
        try self.addError(error.NoteDefinedHere, qualified_token, "parameter passed to @{s} header here", .{ the_scope.block.name });
    };

    try self.explainTokenOrigin(expression_qualified_token, folded_token, result_tag.fmt());
    return error.Break;
}

fn explainInvalidUnaryOperationError(
    self: *const AsmCompute,
    result: Result,
    result_token: Token,
    token: Token
) !noreturn {
    const ty = std.meta.activeTag(result);
    const folded_token = result.getFoldedToken();
    const result_qualified_token = self.source_file.qualifiedToken(result_token);
    const qualified_token = self.source_file.qualifiedToken(token);

    try self.addError(error.InvalidOperation, qualified_token, "{s} does not support {s}", .{
        token.tag.operationFmt(),
        ty.fmt() });
    try self.explainTokenOrigin(result_qualified_token, folded_token, ty.fmt());
    return error.Break;
}

fn explainInvalidBinaryOperationError(
    self: *const AsmCompute,
    lhs: Result,
    rhs: Result,
    token: Token
) !noreturn {
    const lhs_ty = std.meta.activeTag(lhs);
    const rhs_ty = std.meta.activeTag(rhs);
    const qualified_token = self.source_file.qualifiedToken(token);

    try self.addError(error.InvalidOperation, qualified_token, "unable to evaluate {s} between {s} and {s}", .{
        token.tag.operationFmt(),
        lhs_ty.fmt(),
        rhs_ty.fmt() });

    switch (rhs) {
        .index => |index| {
            try self.addError(error.Note, qualified_token, "did you mean '( ... )({s})'?", .{ @tagName(index.register) });
        },
        else => {}
    }

    return error.Break;
}

fn explainAddressRegisterError(
    self: *const AsmCompute,
    result_token: SourceFile.Token,
    token: Token
) !noreturn {
    const preview = if (result_token.inner_token.tag == .argument)
        result_token.slice() else
        result_token.inner_token.tag.fmt();
    const qualified_token = self.source_file.qualifiedToken(token);

    try self.addError(error.IndexAddressRegister, qualified_token, "right-hand side of an index must be an address register, found {s}", .{ preview });
    try self.explainTokenOrigin(qualified_token, result_token, preview);
    return error.Break;
}

fn explainTokenOrigin(
    self: *const AsmCompute,
    source_token: SourceFile.Token,
    folded_token: SourceFile.Token,
    message: []const u8
) !void {
    if (!source_token.eql(folded_token)) {
        try self.addError(error.NoteDefinedHere, folded_token, "{s} defined here", .{ message });
    }
}

fn typeCastAddressRegister(
    self: *const AsmCompute,
    register: instruction.Register,
    result_token: SourceFile.Token,
    token: Token
) !instruction.Register.AddressRegister {
    if (register.isAddressRegister()) {
        return instruction.Register.AddressRegister.fromGeneral(register);
    }

    try self.explainAddressRegisterError(result_token, token);
}

pub const ComputeError = error {
    Break
} || std.mem.Allocator.Error;

pub fn evaluateConstantResult(
    self: *const AsmCompute,
    comptime ty: Result.Type,
    node_index: AsmAst.Node.List.Index
) ComputeError!switch (ty) {
    .scalar => Result.ScalarType,
    .linker_address => Result.LinkerAddressType,
    .header => Result.HeaderType,
    .register => Result.RegisterType,
    .index => Result.IndexType,
    .flag => Result.FlagType,
    .size => Result.SizeType,
    .string => Result.StringType
} {
    const expression_node = self.tree.nodes.get(node_index);
    const expression_token = self.tree.tokens.get(expression_node.token);
    const result = try self.evaluateResult(node_index);
    return try self.typeCast(ty, result, expression_token);
}

pub fn typeCast(
    self: *const AsmCompute,
    comptime ty: Result.Type,
    result: Result,
    expression_token: Token
) ComputeError!switch (ty) {
    .scalar => Result.ScalarType,
    .linker_address => Result.LinkerAddressType,
    .header => Result.HeaderType,
    .register => Result.RegisterType,
    .index => Result.IndexType,
    .flag => Result.FlagType,
    .size => Result.SizeType,
    .string => Result.StringType
} {
    return switch (ty) {
        .scalar => switch (result) {
            .scalar => |scalar| scalar,
            else => try self.explainTypeCastError(ty, result, expression_token)
        },
        .linker_address => switch (result) {
            .scalar => |scalar| Result.LinkerAddressType.fromScalar(scalar),
            .linker_address => |linker_address| linker_address,
            else => try self.explainTypeCastError(ty, result, expression_token)
        },
        .header => switch (result) {
            .header => |header| header,
            else => try self.explainTypeCastError(ty, result, expression_token)
        },
        .register => switch (result) {
            .register => |register| register,
            else => try self.explainTypeCastError(ty, result, expression_token)
        },
        .index => switch (result) {
            .scalar => |scalar| blk: {
                const linker_address: Result.LinkerAddressType = .fromScalar(scalar);
                break :blk .{
                    .folded_token = scalar.folded_token,
                    .register = .zr,
                    .mode = .{ .linker_address = linker_address.linker_address } };
            },
            .linker_address => |linker_address| .{
                .folded_token = linker_address.folded_token,
                .register = .zr,
                .mode = .{ .linker_address = linker_address.linker_address } },
            .register => |register| blk: {
                const address_register = try self.typeCastAddressRegister(register.register, register.folded_token, expression_token);
                break :blk .{
                    .folded_token = register.folded_token,
                    .register = address_register,
                    .mode = .{ .linker_address = .{
                        .dynamic = null,
                        .bit_mask = 0,
                        .offset = 0 } } };
            },
            .index => |index| index,
            else => try self.explainTypeCastError(ty, result, expression_token)
        },
        .flag => switch (result) {
            .flag => |flag| flag,
            else => try self.explainTypeCastError(ty, result, expression_token)
        },
        .size => switch (result) {
            .size => |size| size,
            else => try self.explainTypeCastError(ty, result, expression_token)
        },
        .string => switch (result) {
            .string => |string| string,
            else => try self.explainTypeCastError(ty, result, expression_token)
        }
    };
}

pub fn mapTy(comptime T: type) Result.Type {
    return switch (T) {
        instruction.Register.DataRegister => .register,
        instruction.Register.AddressRegister => .register,
        instruction.LinkerAddress => .linker_address,
        instruction.Flag => .flag,
        instruction.LinkerIndex => .index,
        i8, i16, i24, i32,
        u8, u16, u24, u32 => .linker_address,
        else => @compileError("ty not supported: " ++ @typeName(T))
    };
}

pub fn isTypeCastSafe(ty: Result.Type, result: Result) bool {
    return switch (ty) {
        .linker_address => switch (result) {
            .scalar => true,
            .linker_address => true,
            else => false
        },
        .index => switch (result) {
            .scalar => true,
            .linker_address => true,
            .register => |register| register.register.isAddressRegister(),
            .index => true,
            else => false
        },
        else => ty == std.meta.activeTag(result)
    };
}

pub fn evaluateResult(self: *const AsmCompute, node_index: AsmAst.Node.List.Index) ComputeError!Result {
    return self.evaluateResultDepth(node_index, 0) catch |err| switch (err) {
        error.Recursive => blk: {
            const node = self.tree.nodes.get(node_index);
            const token = self.tree.tokens.get(node.token);
            const qualified_token = self.source_file.qualifiedToken(token);
            const namespace, _ = AsmCompute.extractNamespace(qualified_token.slice());

            if (self.getFileScopedSymbol(namespace)) |resolve_single_symbol| {
                const symbol_qualified_token = self.source_file.qualifiedToken(resolve_single_symbol.symbol.token);
                try self.addError(error.DependencyLoop, symbol_qualified_token, "dependency loop", .{});
                try self.addError(error.NoteEvaluatedFromHere, qualified_token, "evaluated from here", .{});
            } else {
                try self.addError(error.DependencyLoop, qualified_token, "dependency loop", .{});
            }

            break :blk error.Break;
        },
        else => |the_err| the_err
    };
}

const depth_loop_max = 64;

fn evaluateResultDepth(
    self: *const AsmCompute,
    node_index: AsmAst.Node.List.Index,
    depth: u32
) !Result {
    const node = self.tree.nodes.get(node_index);
    const token = self.tree.tokens.get(node.token);
    const qualified_token = self.source_file.qualifiedToken(token);
    const slice = qualified_token.slice();

    if (depth > depth_loop_max) {
        return error.Recursive;
    }

    switch (node.tag) {
        .instruction,
        .identifier => {
            std.debug.assert(token.tag == .identifier);
            std.debug.assert(node.tag != .identifier or node.operands.lhs == AsmAst.untypedNull);
            std.debug.assert(node.tag != .identifier or node.operands.rhs == AsmAst.untypedNull);

            const result = try self.traverseSymbolTree(.define, qualified_token, depth);

            switch (result.symbol.ty) {
                .define => |define| {
                    return try result.scope.evaluateResultDepth(define, result.depth);
                },
                .header => |header| return .{ .header = .{
                    .folded_token = result.token,
                    .file_index = result.scope.file_index,
                    .block_index = header } },
                // Asserted by `traverseSymbolTree`
                .label,
                .import,
                .deferred => unreachable
            }
        },

        .negation,
        .inversion,
        .mask => {
            std.debug.assert(node.operands.lhs != AsmAst.untypedNull);
            std.debug.assert(node.operands.rhs == AsmAst.untypedNull);

            const operand_node_index: AsmAst.Node.List.Index = .at(node.operands.lhs);
            const operand_node = self.tree.nodes.get(operand_node_index);
            const operand_token = self.tree.tokens.get(operand_node.token);

            const operand = try self.evaluateResult(operand_node_index);

            switch (node.tag) {
                .negation => switch (operand) {
                    .scalar => |scalar| return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = -scalar.value } },
                    else => try self.explainInvalidUnaryOperationError(operand, operand_token, token)
                },

                .inversion => switch (operand) {
                    .scalar => |scalar| return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = ~scalar.value } },
                    else => try self.explainInvalidUnaryOperationError(operand, operand_token, token)
                },

                .mask => {
                    std.debug.assert(token.tag == .modifier);

                    const mask = masks.get(slice) orelse {
                        try self.addError(error.InvalidModifier, qualified_token, "invalid modifier '{s}'", .{ slice });
                        return error.Break;
                    };

                    switch (operand) {
                        .scalar => |scalar| return .{ .scalar = .{
                            .folded_token = qualified_token,
                            .value = scalar.value & mask } },
                        .linker_address => |linker_address| return .{ .linker_address = .{
                            .folded_token = qualified_token,
                            .linker_address = .{
                                .dynamic = linker_address.linker_address.dynamic,
                                .bit_mask = linker_address.linker_address.bit_mask & mask,
                                .offset = linker_address.linker_address.offset & mask } } },
                        else => try self.explainInvalidUnaryOperationError(operand, operand_token, token)
                    }
                },

                else => unreachable
            }
        },

        .predecrement,
        .postincrement => {
            std.debug.assert(node.operands.lhs != AsmAst.untypedNull);
            std.debug.assert(node.operands.rhs == AsmAst.untypedNull);
            std.debug.assert(token.tag == .plusplus or token.tag == .minusminus);

            const operand_node_index: AsmAst.Node.List.Index = .at(node.operands.lhs);
            const operand_node = self.tree.nodes.get(operand_node_index);
            const operand_token = self.tree.tokens.get(operand_node.token);

            const operand = try self.evaluateResult(operand_node_index);

            const mode: Result.IndexType.Mode = switch (node.tag) {
                .predecrement => .predecrement,
                .postincrement => .postincrement,
                else => unreachable
            };

            switch (operand) {
                .register => |register| {
                    const address_register = try self.typeCastAddressRegister(register.register, register.folded_token, operand_token);
                    return .{ .index = .{
                        .folded_token = qualified_token,
                        .register = address_register,
                        .mode = mode } };
                },
                else => try self.explainInvalidUnaryOperationError(operand, operand_token, token)
            }
        },

        .index => {
            std.debug.assert(node.operands.lhs != AsmAst.untypedNull);
            std.debug.assert(node.operands.rhs != AsmAst.untypedNull);

            const lhs_node_index: AsmAst.Node.List.Index = .at(node.operands.lhs);
            const lhs_node = self.tree.nodes.get(lhs_node_index);
            const lhs_token = self.tree.tokens.get(lhs_node.token);

            const rhs_node_index: AsmAst.Node.List.Index = .at(node.operands.rhs);
            const rhs_node = self.tree.nodes.get(rhs_node_index);
            const rhs_token = self.tree.tokens.get(rhs_node.token);

            const lhs = try self.evaluateResult(lhs_node_index);
            const rhs = try self.evaluateResult(rhs_node_index);

            switch (rhs) {
                .register => |register| {
                    const address_register = try self.typeCastAddressRegister(register.register, register.folded_token, rhs_token);

                    switch (lhs) {
                        .scalar => |scalar| {
                            const linker_address = Result.LinkerAddressType.fromScalar(scalar);
                            return .{ .index = .{
                                .folded_token = qualified_token,
                                .register = address_register,
                                .mode = .{ .linker_address = linker_address.linker_address } } };
                        },
                        .linker_address => |linker_address| return .{ .index = .{
                            .folded_token = qualified_token,
                            .register = address_register,
                            .mode = .{ .linker_address = linker_address.linker_address } } },
                        else => try self.explainInvalidUnaryOperationError(lhs, lhs_token, token)
                    }
                },
                else => {
                    const rhs_folded_token = rhs.getFoldedToken();
                    try self.explainAddressRegisterError(rhs_folded_token, rhs_token);
                }
            }
        },

        .addition,
        .subtraction,
        .multiplication,
        .bitwise_or,
        .bitwise_and,
        .left_shift,
        .right_shift,
        .less_than,
        .greater_than,
        .equals => {
            std.debug.assert(node.operands.lhs != AsmAst.untypedNull);
            std.debug.assert(node.operands.rhs != AsmAst.untypedNull);

            const lhs = try self.evaluateResult(.at(node.operands.lhs));
            const rhs = try self.evaluateResult(.at(node.operands.rhs));

            switch (node.tag) {
                .addition => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = lhs.scalar.value + rhs.scalar.value } },
                    Result.cmp(.linker_address, .scalar) => return .{ .linker_address = .{
                        .folded_token = qualified_token,
                        .linker_address = .{
                            .dynamic = lhs.linker_address.linker_address.dynamic,
                            .bit_mask = lhs.linker_address.linker_address.bit_mask,
                            .offset = lhs.linker_address.linker_address.offset + rhs.scalar.value } } },
                    Result.cmp(.scalar, .linker_address) => return .{ .linker_address = .{
                        .folded_token = qualified_token,
                        .linker_address = .{
                            .dynamic = rhs.linker_address.linker_address.dynamic,
                            .bit_mask = rhs.linker_address.linker_address.bit_mask,
                            .offset = rhs.linker_address.linker_address.offset + lhs.scalar.value } } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                .subtraction => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = lhs.scalar.value - rhs.scalar.value } },
                    Result.cmp(.linker_address, .scalar) => return .{ .linker_address = .{
                        .folded_token = qualified_token,
                        .linker_address = .{
                            .dynamic = lhs.linker_address.linker_address.dynamic,
                            .bit_mask = lhs.linker_address.linker_address.bit_mask,
                            .offset = lhs.linker_address.linker_address.offset - rhs.scalar.value } } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                .multiplication => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = lhs.scalar.value * rhs.scalar.value } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                .bitwise_or => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = lhs.scalar.value | rhs.scalar.value } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                .bitwise_and => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = lhs.scalar.value & rhs.scalar.value } },
                    Result.cmp(.linker_address, .scalar) => return .{ .linker_address = .{
                        .folded_token = qualified_token,
                        .linker_address = .{
                            .dynamic = lhs.linker_address.linker_address.dynamic,
                            .bit_mask = lhs.linker_address.linker_address.bit_mask & rhs.scalar.value,
                            .offset = lhs.linker_address.linker_address.offset & rhs.scalar.value } } },
                    Result.cmp(.scalar, .linker_address) => return .{ .linker_address = .{
                        .folded_token = qualified_token,
                        .linker_address = .{
                            .dynamic = rhs.linker_address.linker_address.dynamic,
                            .bit_mask = rhs.linker_address.linker_address.bit_mask & lhs.scalar.value,
                            .offset = rhs.linker_address.linker_address.offset & lhs.scalar.value } } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                // TODO: check overflow u5
                // TODO: negative rhs

                .left_shift => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = lhs.scalar.value << @intCast(rhs.scalar.value) } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                .right_shift => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = lhs.scalar.value >> @intCast(rhs.scalar.value) } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                .less_than => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = if (lhs.scalar.value < rhs.scalar.value) -1 else 0 } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                .greater_than => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = if (lhs.scalar.value > rhs.scalar.value) -1 else 0 } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                .equals => switch (Result.cmp(lhs, rhs)) {
                    Result.cmp(.scalar, .scalar) => return .{ .scalar = .{
                        .folded_token = qualified_token,
                        .value = if (lhs.scalar.value == rhs.scalar.value) -1 else 0 } },
                    else => try self.explainInvalidBinaryOperationError(lhs, rhs, token)
                },

                else => unreachable
            }
        },

        .integer => {
            std.debug.assert(token.tag == .numeric_literal);
            std.debug.assert(node.operands.lhs == AsmAst.untypedNull);
            std.debug.assert(node.operands.rhs == AsmAst.untypedNull);

            const auto_base = 0;

            const numeric_literal = std.fmt.parseInt(ComputeTimeInt, slice, auto_base) catch {
                try self.addError(error.ParseError, qualified_token, "invalid numeric literal", .{});
                return error.Break;
            };

            return .{ .scalar = .{
                .folded_token = qualified_token,
                .value = numeric_literal } };
        },

        .character => {
            std.debug.assert(token.tag == .char_literal);
            std.debug.assert(node.operands.lhs == AsmAst.untypedNull);
            std.debug.assert(node.operands.rhs == AsmAst.untypedNull);
            std.debug.assert(slice.len == 1);

            return .{ .scalar = .{
                .folded_token = qualified_token,
                .value = @intCast(slice[0]) } };
        },

        .string => {
            std.debug.assert(token.tag == .string_literal);
            std.debug.assert(node.operands.rhs == AsmAst.untypedNull);

            const sentinel: ?u8 = blk: {
                if (node.operands.lhs == AsmAst.untypedNull)
                    break :blk null;

                const sentinel_node = self.tree.nodes.get(.at(node.operands.lhs));
                const sentinel_token = self.tree.tokens.get(sentinel_node.token);
                const sentinel_qualified_token = self.source_file.qualifiedToken(sentinel_token);
                const sentinel_slice = sentinel_qualified_token.slice();

                std.debug.assert(sentinel_node.tag == .integer);
                std.debug.assert(sentinel_token.tag == .numeric_literal);

                const auto_base = 0;

                break :blk std.fmt.parseInt(u8, sentinel_slice, auto_base) catch |err| switch (err) {
                    error.InvalidCharacter => {
                        try self.addError(error.ParseError, sentinel_qualified_token, "invalid numeric literal", .{});
                        return error.Break;
                    },
                    error.Overflow => {
                        try self.addError(error.SentinelSize, sentinel_qualified_token, "sentinel must fit in an 8 bit unsigned integer", .{});
                        return error.Break;
                    }
                };
            };

            return .{ .string = .{
                .folded_token = qualified_token,
                .text = slice,
                .sentinel = sentinel } };
        },

        .reference => {
            std.debug.assert(token.tag == .reference_label or token.tag == .difference_label);
            std.debug.assert(node.operands.lhs == AsmAst.untypedNull);
            std.debug.assert(node.operands.rhs == AsmAst.untypedNull);

            const ty: SymbolType = switch (token.tag) {
                .reference_label => .reference_label,
                .difference_label => .difference_label,
                else => unreachable
            };
            const result = try self.traverseSymbolTree(ty, qualified_token, depth);

            switch (result.symbol.ty) {
                .label => |block_index| return .{ .linker_address = .{
                    .folded_token = result.token,
                    .linker_address = .{
                        .dynamic = .{
                            .file_index = result.scope.file_index,
                            .block_index = block_index,
                            .locality = if (result.symbol.token.tag == .label) .global else .local,
                            .namespace = result.scope.getNamespace(),
                            .label = result.label,
                        },
                        // 0b11111111...
                        .bit_mask = ~@as(ComputeTimeInt, 0),
                        .offset = 0 } } },
                // Asserted by `traverseSymbolTree`
                .define,
                .header,
                .import,
                .deferred => unreachable
            }
        },

        .argument => {
            std.debug.assert(token.tag == .argument or token.tag == .instruction);
            std.debug.assert(node.operands.lhs == AsmAst.untypedNull);
            std.debug.assert(node.operands.rhs == AsmAst.untypedNull);

            const argument = typed_arguments.get(slice) orelse {
                try self.addError(error.Expected, qualified_token, "expected an argument type, found {s}", .{ token.tag.fmt() });
                return error.Break;
            };

            switch (argument) {
                .size => |size| return .{ .size = .{
                    .folded_token = qualified_token,
                    .bytes = size } },
                .register => |register| return .{ .register = .{
                    .folded_token = qualified_token,
                    .register = register } },
                .flag => |flag| return .{ .flag = .{
                    .folded_token = qualified_token,
                    .flag = flag } }
            }
        },

        .container,
        .composite,
        .builtin,
        .label => unreachable
    }
}

const masks = std.StaticStringMap(ComputeTimeInt).initComptime(.{
    .{ "h", 0xFF00 }, // high
    .{ "l", 0x00FF }, // low
    .{ "w", 0xFFFF }  // word
});

const ArgumentType = union(enum) {
    size: u32,
    register: instruction.Register,
    flag: instruction.Flag
};

const typed_arguments = std.StaticStringMap(ArgumentType).initComptime(.{
    .{ "u8", ArgumentType { .size = 1 } },
    .{ "i8", ArgumentType { .size = 1 } },
    .{ "u16", ArgumentType { .size = 2 } },
    .{ "i16", ArgumentType { .size = 2 } },
    .{ "u24", ArgumentType { .size = 3 } },
    .{ "i24", ArgumentType { .size = 3 } },
    .{ "u32", ArgumentType { .size = 4 } },
    .{ "i32", ArgumentType { .size = 4 } },
    .{ "zr", ArgumentType { .register = .zr } },
    .{ "rp", ArgumentType { .register = .rp } },
    .{ "d1", ArgumentType { .register = .d1 } },
    .{ "d2", ArgumentType { .register = .d2 } },
    .{ "d3", ArgumentType { .register = .d3 } },
    .{ "d4", ArgumentType { .register = .d4 } },
    .{ "d5", ArgumentType { .register = .d5 } },
    .{ "d6", ArgumentType { .register = .d6 } },
    .{ "ip", ArgumentType { .register = .ip } },
    .{ "sp", ArgumentType { .register = .sp } },
    .{ "fp", ArgumentType { .register = .fp } },
    .{ "a1", ArgumentType { .register = .a1 } },
    .{ "a2", ArgumentType { .register = .a2 } },
    .{ "a3", ArgumentType { .register = .a3 } },
    .{ "a4", ArgumentType { .register = .a4 } },
    .{ "c", ArgumentType { .flag = .c } },
    .{ "h", ArgumentType { .flag = .h } },
    .{ "s", ArgumentType { .flag = .s } },
    .{ "z", ArgumentType { .flag = .z } },
    .{ "nc", ArgumentType { .flag = .nc } },
    .{ "nh", ArgumentType { .flag = .nh } },
    .{ "ns", ArgumentType { .flag = .ns } },
    .{ "nz", ArgumentType { .flag = .nz } }
});

const SymbolType = enum {

    define,
    reference_label,
    difference_label,

    pub fn matches(self: SymbolType, symbol_type: AsmIr.Symbol.Type) bool {
        return switch (symbol_type) {
            .define => self == .define,
            .header => self == .define,
            .label => self == .reference_label or self == .difference_label,
            .import, .deferred => false
        };
    }

    pub fn fmt(self: SymbolType) []const u8 {
        return switch (self) {
            .define => "symbol",
            .reference_label, .difference_label => "label"
        };
    }
};

const TraversedSymbol = struct {
    token: SourceFile.Token,
    label: []const u8,
    scope: AsmCompute,
    // Asserts symbol.ty != .import, and AsmSemanticAir must prepare .deferred
    // symbols within a @header scope ahead of time.
    symbol: AsmIr.Symbol,
    depth: u32
};

fn traverseSymbolTree(
    self: *const AsmCompute,
    ty: SymbolType,
    token: SourceFile.Token,
    depth: u32
) !TraversedSymbol {
    const identifier = token.slice();
    return try self.traverseSymbolTreeInner(ty, token, identifier, .internal, depth);
}

fn traverseSymbolTreeInner(
    self: *const AsmCompute,
    ty: SymbolType,
    token: SourceFile.Token,
    identifier: []const u8,
    access: enum { internal, external },
    depth: u32
) !TraversedSymbol {
    std.debug.assert(identifier.len > 0);

    if (depth > depth_loop_max) {
        return error.Recursive;
    }

    const namespace, const child_identifier = AsmCompute.extractNamespace(identifier);

    const result = self.getFileScopedSymbol(namespace) orelse {
        try self.addError(error.UnknownSymbol, token, "unknown {s} '{s}'", .{ ty.fmt(), namespace });

        const token_str = token.slice();

        if (namespace.len != token_str.len) {
            const namespace_index = std.mem.find(u8, token_str, namespace);
            try self.addError(error.Note, token, "{s} '{s}' does not exist in namespace '{s}'", .{
                ty.fmt(),
                namespace,
                token_str[0..(namespace_index.? - 1)] });
        }

        return error.Break;
    };

    const qualified_symbol_token = result.scope.source_file.qualifiedToken(result.symbol.token);

    if (access == .external and result.symbol.privacy != .public) {
        try self.addError(error.PrivateSymbol, token, "'{s}' is marked private", .{ namespace });
        try self.addError(error.NoteDefinedHere, qualified_symbol_token, "a private symbol defined here", .{});

        switch (result.symbol.ty) {
            .define, .header, .import => {
                try self.addError(error.Note, qualified_symbol_token, "use '{s}(expose) {s}' to mark it public", .{
                    result.symbol.ty.fmt(),
                    qualified_symbol_token.slice() });
            },
            .label => {
                try self.addError(error.Note, qualified_symbol_token, "use '{s}:' to mark it public", .{ qualified_symbol_token.slice() });
            },
            .deferred => unreachable
        }

        return error.Break;
    }

    switch (result.symbol.ty) {
        .define, .header, .label => {
            if (!ty.matches(result.symbol.ty)) {
                try self.addError(error.SymbolType, token, "expected {s}, found {s}", .{
                    token.inner_token.tag.fmt(),
                    result.symbol.ty.fmt() });
                try self.explainTokenOrigin(token, qualified_symbol_token, result.symbol.ty.fmt());
                return error.Break;
            }

            return .{
                .token = token,
                .label = identifier,
                .scope = result.scope,
                .symbol = result.symbol,
                .depth = depth + 1 };
        },
        .import => |file_index| {
            const new_scope = self.bridge.createScope(file_index, null);

            if (child_identifier.len == 0) {
                try self.addError(error.NamespaceSymbol, token, "symbol is a namespace", .{});
                try self.addError(error.NoteDefinedHere, qualified_symbol_token, "{s} defined here", .{ result.symbol.ty.fmt() });
                return error.Break;
            }

            return try new_scope.traverseSymbolTreeInner(ty, token, child_identifier, .external, depth + 1);
        },
        .deferred => unreachable
    }
}

fn extractNamespace(identifier: []const u8) struct {
    []const u8,
    []const u8
} {
    var namespaces = std.mem.splitScalar(u8, identifier, '.');
    const namespace = namespaces.first();
    const child_identifier = namespaces.rest();

    return .{ namespace, child_identifier };
}

const FileScopedSymbol = struct {
    scope: AsmCompute,
    symbol: AsmIr.Symbol
};

fn getFileScopedSymbol(self: *const AsmCompute, identifier: []const u8) ?FileScopedSymbol {
    if (self.scope) |the_scope| {
        std.debug.assert(the_scope.output != .suppressed);

        // it's a deferred symbol, e.g. a header argument, so we're moving our
        // scope to where the argument was passed; it might be a totally
        // different file, so we're creating a dummy token for it
        if (the_scope.deferred_symbols.get(identifier)) |the_deferred_symbol| {
            const local_symbol = the_scope.block.symbols.get(identifier) orelse unreachable;
            std.debug.assert(local_symbol.ty == .deferred);

            const scope = self.bridge.createScope(
                the_deferred_symbol.file_index,
                the_deferred_symbol.scope);

            const argument_symbol = AsmIr.Symbol {
                .token = the_deferred_symbol.token,
                .ty = .{ .define = the_deferred_symbol.node_index },
                .privacy = .private };
            return .{ .scope = scope, .symbol = argument_symbol };
        }

        // this is inside the current scope, so we keep our scope
        if (the_scope.block.symbols.get(identifier)) |the_local_symbol| {
            return .{ .scope = self.*, .symbol = the_local_symbol };
        }
    }

    // we're going to the global scope, so demote our possibly local scope so
    // any future dereferencing cannot access locally-scoped symbols
    if (self.ir.symbols.get(identifier)) |the_global_symbol| {
        return .{ .scope = self.demoteGlobalScope(), .symbol = the_global_symbol };
    }

    return null;
}

fn demoteGlobalScope(self: *const AsmCompute) AsmCompute {
    return .init(
        self.allocator,
        self.file_index,
        self.source_file,
        self.tree,
        self.ir,
        null,
        self.bridge);
}

fn getNamespace(self: *const AsmCompute) []const u8 {
    if (self.scope) |the_scope| {
        return the_scope.namespace;
    }

    return self.source_file.fileName();
}

// Tests

const build_options = @import("options");

const TestBridge = struct {

    allocator: std.mem.Allocator,
    errors: std.ArrayList(Error) = .empty,

    pub fn deinit(self: *TestBridge) void {
        for (self.errors.items) |*err|
            err.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    const astTable = AsmAst.Bridge.VTable {
        .emitError = emitError
    };

    const irTable = AsmIr.Bridge.VTable {
        .emitError = emitError,
        .import = import
    };

    const computeTable = Bridge.VTable {
        .emitError = emitError,
        .createScope = createScope
    };

    fn emitError(context: *anyopaque, err: Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    fn import(_: *anyopaque, _: []const u8) !Qcu.File.List.Index {
        return .root;
    }

    fn createScope(_: *anyopaque, _: Qcu.File.List.Index, _: ?*const AsmSemanticAir) AsmCompute {
        @panic("bug: not implemented");
    }

    pub fn ast(self: *TestBridge) AsmAst.Bridge {
        return .{ .vtable = astTable, .context = self };
    }

    pub fn ir(self: *TestBridge) AsmIr.Bridge {
        return .{ .vtable = irTable, .context = self };
    }

    pub fn compute(self: *TestBridge) Bridge {
        return .{ .vtable = computeTable, .context = self };
    }
};

fn testCompute(func: anytype, input: [:0]const u8, errors: []const anyerror) !void {
    const stderr_file = std.Io.File.stderr();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = stderr_file.writer(std.testing.io, &stderr_buffer);
    defer stderr.flush() catch {};

    const source_file = SourceFile {
        .pwd = std.Io.Dir.cwd(),
        .real_path = "Sources/AsmCompute.zig",
        .buffer = input,
        .inode = undefined,
        .size = undefined };
    var bridge = TestBridge { .allocator = std.testing.allocator };
    defer bridge.deinit();
    var ast = try AsmAst.init(std.testing.allocator, &source_file, bridge.ast());
    defer ast.deinit(std.testing.allocator);
    std.debug.assert(bridge.errors.items.len == 0);
    var ir = try AsmIr.init(std.testing.allocator, &source_file, &ast, bridge.ir());
    defer ir.deinit(std.testing.allocator);
    std.debug.assert(bridge.errors.items.len == 0);

    var compute = AsmCompute.init(std.testing.allocator, .root, &source_file, &ast, &ir, null, bridge.compute());

    func(&compute) catch |err| switch (err) {
        error.Break => try std.testing.expect(bridge.errors.items.len > 0),
        else => |the_err| return the_err
    };

    if (errors.len != bridge.errors.items.len) {
        for (bridge.errors.items) |err|
            try err.write(&stderr.interface);
    }

    try std.testing.expectEqual(errors.len, bridge.errors.items.len);
    for (errors, 0..) |err, i| try std.testing.expectEqual(err, bridge.errors.items[i].err);
}

fn testDefineEvaluation(compute: *AsmCompute) !void {
    var iterator = compute.ir.symbols.iterator();

    while (iterator.next()) |symbol| if (symbol.value_ptr.ty == .define) {
        const result = try compute.evaluateResult(symbol.value_ptr.ty.define);
        std.log.debug("{any}", .{ result });
    };
}

test "unary operations" {
    try testCompute(testDefineEvaluation, "@define foo, 5", &.{});
    try testCompute(testDefineEvaluation, "@define foo, -1", &.{});
    try testCompute(testDefineEvaluation, "@define foo, -(-1)", &.{});
    try testCompute(testDefineEvaluation, "@define foo, !0x00", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 0x00'l", &.{});
    try testCompute(testDefineEvaluation, "@define foo, .reference'l", &.{ error.UnknownSymbol });
    try testCompute(testDefineEvaluation, "@define foo, -.reference", &.{ error.UnknownSymbol });
    try testCompute(testDefineEvaluation, "@define foo, -rp", &.{ error.InvalidOperation });
    try testCompute(testDefineEvaluation, "@define foo, --rp", &.{ error.IndexAddressRegister });
    try testCompute(testDefineEvaluation, "@define foo, --ip", &.{});
    try testCompute(testDefineEvaluation, "@define foo, (ip)++", &.{});
    try testCompute(testDefineEvaluation, "@define foo, --c", &.{ error.InvalidOperation });

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, .foo
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, -.foo
    , &.{ error.InvalidOperation });
}

test "binary operations" {
    try testCompute(testDefineEvaluation, "@define foo, 5 + 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 'A' + 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5 - 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5 * 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5 << 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5 >> 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5 > 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5 = 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5 < 3", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5 + rp", &.{ error.InvalidOperation });
    try testCompute(testDefineEvaluation, "@define foo, 5 * rp", &.{ error.InvalidOperation });
    try testCompute(testDefineEvaluation, "@define foo, 5 << rp", &.{ error.InvalidOperation });
    try testCompute(testDefineEvaluation, "@define foo, 5 > rp", &.{ error.InvalidOperation });
    try testCompute(testDefineEvaluation, "@define foo, 5 = rp", &.{ error.InvalidOperation });
    try testCompute(testDefineEvaluation, "@define foo, 5 < rp", &.{ error.InvalidOperation });

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, .foo + 1
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, .foo'l + 1
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, .foo'l | 1
    , &.{ error.InvalidOperation });

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, 1 + .foo
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, -1 + .foo
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\.roo:
        \\@define bar, .foo + .roo
    , &.{ error.InvalidOperation });

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\.roo:
        \\@define bar, .foo + rp
    , &.{ error.InvalidOperation });

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\.roo:
        \\@define bar, .foo * 5
    , &.{ error.InvalidOperation });
}

test "indexing" {
    try testCompute(testDefineEvaluation, "@define foo, 5(a1)", &.{});
    try testCompute(testDefineEvaluation, "@define foo, 5(d1)", &.{ error.IndexAddressRegister });
    try testCompute(testDefineEvaluation, "@define foo, a1(ip)", &.{ error.InvalidOperation });

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, .foo(a1)
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, .foo + 1(a1)
    , &.{ error.InvalidOperation, error.Note });

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, (.foo + 1)(a1)
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, .foo'l(a1)
    , &.{});
}

test "lowering" {
    try testCompute(testDefineEvaluation,
        \\@define foo, 5
        \\@define bar, foo
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@define foo, 5
        \\@define bar, foo + 3
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@define foo, rp
        \\@define bar, -foo
    , &.{ error.InvalidOperation, error.NoteDefinedHere });

    try testCompute(testDefineEvaluation,
        \\@define foo, 5
        \\@define bar, .foo
    , &.{ error.SymbolType, error.NoteDefinedHere });

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo:
        \\@define bar, .foo
    , &.{});
}

test "labels" {
    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo.roo:
        \\@define bar, .foo
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo: ; qualified label validated in linker
        \\@define bar, .foo.does.not.exist
    , &.{});

    try testCompute(testDefineEvaluation,
        \\@section root
        \\.foo.roo:
        \\@define bar, .foo.roo
    , &.{});
}

test "dependency loop" {
    try testCompute(testDefineEvaluation,
        \\@define foo, bar
        \\@define bar, foo
    , &.{ error.DependencyLoop, error.NoteEvaluatedFromHere });
}
