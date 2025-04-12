
// Liveness
//
//  points out bullshit assembly
//  - empty sections
//  - unlabeled instruction after unconditional jump/@section
//  - consecutive register store operations to same locations
//  - control flow spilling into padding or data
//  - unlabeled instructions after data
//  - unused private defines/headers
//  - unused private labels?
//  ran after semantic analysis
//  recursive symbol usage is verified in SemanticAir

const std = @import("std");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const Error = @import("Error.zig");
const Qcu = @import("Qcu.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

const AsmLiveness = @This();

qcu: ?*Qcu.File,
allocator: std.mem.Allocator,
source: Source,
symbols: *const SymbolMap,
sections: *const SectionMap,
/// Only populated in freestanding.
errors: ErrorList,

pub fn init(
    qcu: *Qcu.File,
    source: Source,
    symbols: *const SymbolMap,
    sections: *const SectionMap
) !AsmLiveness {
    var self = AsmLiveness {
        .qcu = qcu,
        .allocator = qcu.allocator,
        .source = source,
        .symbols = symbols,
        .sections = sections,
        .errors = .empty };
    errdefer self.deinit();
    try self.liveness_root();
    return self;
}

pub fn init_freestanding(
    allocator: std.mem.Allocator,
    source: Source,
    symbols: *const SymbolMap,
    sections: *const SectionMap
) !AsmLiveness {
    var self = AsmLiveness {
        .qcu = null,
        .allocator = allocator,
        .source = source,
        .symbols = symbols,
        .sections = sections,
        .errors = .empty };
    errdefer self.deinit();
    try self.liveness_root();
    return self;
}

pub fn deinit(self: *AsmLiveness) void {
    for (self.errors.items) |err|
        self.allocator.free(err.message);
    self.errors.deinit(self.allocator);
}

const SymbolMap = std.StringArrayHashMapUnmanaged(AsmSemanticAir.Symbol.Locatable);
const SectionMap = std.StringArrayHashMapUnmanaged(*Section);
const ErrorList = std.ArrayListUnmanaged(Error);

const LivenessError = error {
    EmptySection,
    UnreachableOpaque,
    DuplicateStore,
    UncoordinatedPadding,
    UncoordinatedData,
    UndefinedControlFlow,
    UnusedPrivateSymbol,
    NoteDivertedHere,
    NotePaddingHere,
    NoteConfusingSize,
    NoteDefinedHere
};

fn add_error(self: *AsmLiveness, comptime err: LivenessError, argument: anytype) !void {
    @branchHint(.unlikely);

    const message = switch (err) {
        error.EmptySection => "empty section",
        error.UnreachableOpaque => "unlabeled/unreachable instruction '{s}'",
        error.DuplicateStore => "duplicate write of same register '{s}'",
        error.UncoordinatedPadding => "execution flow spills into padding",
        error.UncoordinatedData => "execution flow spills into non-executable opaque",
        error.UndefinedControlFlow => "execution flow reaches end of section",
        error.UnusedPrivateSymbol => "unused private symbol",
        error.NoteDivertedHere => "control flow diverted here",
        error.NotePaddingHere => "padding is generated here",
        error.NoteConfusingSize => "'{s}' has a confusing size",
        error.NoteDefinedHere => "{s} defined here"
    };

    const is_note = switch (err) {
        error.NoteDivertedHere,
        error.NotePaddingHere,
        error.NoteConfusingSize,
        error.NoteDefinedHere => true,
        else => false
    };

    const token: ?Token = switch (err) {
        error.DuplicateStore => argument[0],
        else => argument
    };
    const token_location = if (token) |token_|
        self.source.location_of(token_.location) else
        null;
    const token_slice = if (token) |token_|
        token_.location.slice(self.source.buffer) else
        null;
    const arguments = switch (err) {
        error.UnreachableOpaque,
        error.NoteConfusingSize => .{ token_slice.? },
        error.DuplicateStore => .{ @tagName(argument[1]) },
        error.NoteDefinedHere => .{ argument.tag.fmt() },
        else => .{}
    };

    const format = try std.fmt.allocPrint(self.allocator, message, arguments);
    errdefer self.allocator.free(format);

    const err_data = Error {
        .id = err,
        .token = token,
        .is_note = is_note,
        .message = format,
        .location = token_location };
    if (self.qcu) |qcu|
        try qcu.add_error(err_data) else
        try self.errors.append(self.allocator, err_data);
}

const Section = AsmSemanticAir.Section;

fn liveness_root(self: *AsmLiveness) !void {
    for (self.sections.values()) |section| {
        var barrier_section: ?*Section = section;
        while (barrier_section) |barrier_section_| {
            try self.liveness_inner(barrier_section_);
            barrier_section = barrier_section_.next;
        }
    }

    for (self.symbols.values()) |symbol| {
        const is_public = switch (symbol.symbol) {
            inline else => |symbol_| symbol_.is_public
        };

        if (!symbol.is_used and !is_public)
            try self.add_error(error.UnusedPrivateSymbol, symbol.token);
    }
}

const LivenessTrack = struct {
    token: Token,
    is_labeled: bool,
    instruction: AsmSemanticAir.Instruction,
    tag: AsmSemanticAir.Instruction.Tag
};

fn liveness_inner(self: *AsmLiveness, section: *const Section) !void {
    const tokens = section.content.items(.token);
    const is_labeleds = section.content.items(.is_labeled);
    const instructions = section.content.items(.instruction);

    var previous_track: ?LivenessTrack = null;

    for (tokens, is_labeleds, instructions) |token, is_labeled, instruction| {
        const track = LivenessTrack {
            .token = token,
            .is_labeled = is_labeled,
            .instruction = instruction,
            .tag = std.meta.activeTag(instruction) };
        if (track.tag == .ld_padding) {
            if (previous_track) |previous_track_|
                try self.pass_uncoordinated_padding(&track, &previous_track_);
            continue;
        }

        defer previous_track = track;

        if (previous_track) |previous_track_| {
            try self.pass_duplicate_store(&track, &previous_track_);
            try self.pass_unreachable_opaque(&track, &previous_track_);
            try self.pass_uncoordinated_data(&track, &previous_track_);
        } else {
            try self.pass_unreachable_section(section, &track);
        }
    }

    if (previous_track) |last_track|
        try self.pass_undefined_control_flow(&last_track) else
        try self.add_error(error.EmptySection, section.token); // 'reserve' succeeds, padding does not
}

fn pass_uncoordinated_padding(
    self: *AsmLiveness,
    current: *const LivenessTrack,
    previous: *const LivenessTrack
) !void {
    std.debug.assert(current.tag == .ld_padding);
    if (!previous.tag.is_jump() and previous.tag.is_executable()) {
        try self.add_error(error.UncoordinatedPadding, previous.token);
        try self.add_error(error.NotePaddingHere, current.token);
    }
}

fn pass_unreachable_opaque(
    self: *AsmLiveness,
    current: *const LivenessTrack,
    previous: *const LivenessTrack
) !void {
    if (!current.is_labeled and
        (previous.tag.is_jump() or
         (previous.tag.is_fixed_data() and !current.tag.is_fixed_data()) or
         previous.tag.is_confusing_size())
    ) {
        try self.add_error(error.UnreachableOpaque, current.token);
        if (previous.tag.is_confusing_size())
            try self.add_error(error.NoteConfusingSize, previous.token) else
            try self.add_error(error.NoteDivertedHere, previous.token);
    }
}

fn pass_uncoordinated_data(
    self: *AsmLiveness,
    current: *const LivenessTrack,
    previous: *const LivenessTrack
) !void {
    if (!current.tag.is_executable() and
        previous.tag.is_executable() and
        !previous.tag.is_jump()
    ) {
        try self.add_error(error.UncoordinatedData, previous.token);
        try self.add_error(error.NoteDefinedHere, current.token);
    }
}

fn pass_duplicate_store(
    self: *AsmLiveness,
    current: *const LivenessTrack,
    previous: *const LivenessTrack
) !void {
    if (current.tag == .ast and
        previous.tag == .ast and
        current.instruction.ast[0] == previous.instruction.ast[0]
    ) {
        try self.add_error(error.DuplicateStore, .{ current.token, current.instruction.ast[0] });
    }

    if (current.tag == .rst and
        previous.tag == .rst and
        current.instruction.rst[0] == previous.instruction.rst[0]
    ) {
        try self.add_error(error.DuplicateStore, .{ current.token, current.instruction.rst[0] });
    }
}

fn pass_undefined_control_flow(self: *AsmLiveness, current: *const LivenessTrack) !void {
    if (current.tag.is_executable() and !current.tag.is_jump())
        try self.add_error(error.UndefinedControlFlow, current.token);
}

fn pass_unreachable_section(
    self: *AsmLiveness,
    section: *const Section,
    current: *const LivenessTrack
) !void {
    if (!current.is_labeled) {
        try self.add_error(error.UnreachableOpaque, current.token);
        try self.add_error(error.NoteDefinedHere, section.token);
    }
}

// Tests

const options = @import("options");
const AsmAst = @import("AsmAst.zig");
const Tokeniser = @import("AsmTokeniser.zig");

const stderr = std.io
    .getStdErr()
    .writer();

fn testLiveness(input: [:0]const u8) !struct { AsmAst, AsmSemanticAir, AsmLiveness } {
    var tokeniser = Tokeniser.init(input);
    const source = try Source.init(std.testing.allocator, &tokeniser);
    errdefer source.deinit();
    var ast = try AsmAst.init(std.testing.allocator, source);
    errdefer ast.deinit();

    for (ast.errors) |err|
        try err.write("test.s", input, stderr);
    try std.testing.expect(ast.errors.len == 0);

    var sema = try AsmSemanticAir.init_freestanding(std.testing.allocator, source, ast.nodes);
    errdefer sema.deinit();
    try sema.semantic_analyse();

    for (sema.errors.items) |err|
        try err.write("test.s", input, stderr);
    try std.testing.expect(sema.errors.items.len == 0);

    return .{ ast, sema, try AsmLiveness.init_freestanding(std.testing.allocator, source, &sema.symbols, &sema.sections) };
}

fn testLivenessFree(ast: *AsmAst, sema: *AsmSemanticAir, liveness: *AsmLiveness) void {
    ast.deinit();
    sema.deinit();
    sema.source.deinit();
    liveness.deinit();
}

fn testLivenessErr(input: [:0]const u8, errors: []const LivenessError) !void {
    var ast, var sema, var liveness = try testLiveness(input);
    defer testLivenessFree(&ast, &sema, &liveness);

    var liveness_errors = std.ArrayList(anyerror).init(std.testing.allocator);
    defer liveness_errors.deinit();
    for (liveness.errors.items) |err|
        try liveness_errors.append(err.id);
    if (!std.mem.eql(anyerror, errors, liveness_errors.items)) {
        for (liveness.errors.items) |err|
            try err.write("test.s", input, stderr);
        try std.testing.expectEqualSlices(anyerror, errors, liveness_errors.items);
    } else if (options.dump) {
        for (liveness.errors.items) |err|
            try err.write("test.s", input, stderr);
    }
}

test "unused sections" {
    try testLivenessErr(
        \\@section foo
        \\foo: jmpr 0x00
        \\@barrier
        \\bar: jmpr 0x00
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\@barrier
        \\foo: cli
        \\     jmpr 0x00
    , &.{ error.EmptySection });

    try testLivenessErr(
        \\@section foo
        \\@barrier
    , &.{
        error.EmptySection,
        error.EmptySection
    });
}

test "unlabeled instruction after unconditional jump/unknown sized instructions" {
    try testLivenessErr(
        \\@section foo
        \\foo: jmpr 0x0000
        \\bar:
        \\ascii "hi mum!"
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\foo: cli
        \\ast ra
        \\ast rb
        \\jmpr 0x00
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\foo: jmpr 0x0000
        \\ascii "hi mum!"
    , &.{
        error.UnreachableOpaque,
        error.NoteDivertedHere
    });

    try testLivenessErr(
        \\@section foo
        \\foo: ascii "hi mum!"
        \\     ascii "bye mum!"
    , &.{
        error.UnreachableOpaque,
        error.NoteConfusingSize
    });

    try testLivenessErr(
        \\@section foo
        \\foo: u8 0x00
        \\     u16 0x0000
        \\bar: ascii "bye mum!"
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\foo: u8 0x00
        \\     u16 0x0000
        \\     ascii "bye mum!"
    , &.{
        error.UnreachableOpaque,
        error.NoteDivertedHere // fixme: confusing note?
    });

    try testLivenessErr(
        \\@section foo
        \\@align 16
        \\     ascii "bye mum!"
    , &.{
        error.UnreachableOpaque,
        error.NoteDefinedHere
    });
}

test "execution spills into padding" {
    try testLivenessErr(
        \\@section foo
        \\@align 16
    , &.{
        error.EmptySection
    });

    try testLivenessErr(
        \\@section foo
        \\foo: ascii "Hello world!"
        \\@align 16
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\foo: jmp 0x0000
        \\@align 16
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\foo: jmp 0x0000
        \\@align 16
        \\u8 0x00
    , &.{
        error.UnreachableOpaque,
        error.NoteDivertedHere
    });

    try testLivenessErr(
        \\@section foo
        \\foo: cli
        \\@align 16
        \\jmpr 0x00
    , &.{
        error.UncoordinatedPadding,
        error.NotePaddingHere
    });

    try testLivenessErr(
        \\@section foo
        \\foo: ascii "no errors here"
        \\@align 16
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\@region 24
        \\foo: cli
        \\@end
        \\jmpr 0x00
    , &.{
        error.UncoordinatedPadding,
        error.NotePaddingHere
    });

    try testLivenessErr(
        \\@section foo
        \\@region 24
        \\foo: jmp 0x0000
        \\@end
    , &.{});
}

test "execution spills into data" {
    try testLivenessErr(
        \\@section foo
        \\foo: cli
        \\     u8 0x00
    , &.{
        error.UncoordinatedData,
        error.NoteDefinedHere
    });

    try testLivenessErr(
        \\@section foo
        \\@region 24
        \\foo: cli
        \\     u8 0x00
        \\@end
    , &.{
        error.UncoordinatedData,
        error.NoteDefinedHere
    });

    try testLivenessErr(
        \\@section foo
        \\@region 24
        \\foo: u8 0x00
        \\     u16 0x00
        \\     u24 0x00
        \\@end
    , &.{});
}

test "doubly write to same register" {
    try testLivenessErr(
        \\@section foo
        \\foo:
        \\ast ra
        \\ast rb
        \\ast rc
        \\jmpr 0x00
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\foo:
        \\ast ra
        \\ast ra
        \\ast rc
        \\jmpr 0x00
    , &.{
        error.DuplicateStore
    });
}

test "unlabeled instruction after @section" {
    try testLivenessErr(
        \\@section foo
        \\foo: cli
        \\     jmpr 0x00
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\cli
        \\jmpr 0x00
    , &.{
        error.UnreachableOpaque,
        error.NoteDefinedHere
    });

    try testLivenessErr(
        \\@section foo
        \\@region 24
        \\cli
        \\@end
    , &.{
        error.UnreachableOpaque,
        error.NoteDefinedHere,
        error.UncoordinatedPadding,
        error.NotePaddingHere,
        error.UndefinedControlFlow
    });

    try testLivenessErr(
        \\@section foo
        \\cli
        \\jmpr 0x00
        \\@barrier
        \\cli
        \\jmpr 0x00
    , &.{
        error.UnreachableOpaque,
        error.NoteDefinedHere,
        error.UnreachableOpaque,
        error.NoteDefinedHere
    });
}

test "undefined control flow" {
    try testLivenessErr(
        \\@section foo
        \\foo: cli
        \\     jmpr 0x00
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\foo: cli
    , &.{
        error.UndefinedControlFlow
    });

    try testLivenessErr(
        \\@section foo
        \\foo: cli
        \\     jmpr 0x00
        \\@barrier
        \\bar: ast ra
    , &.{
        error.UndefinedControlFlow
    });
}

test "unused private symbols" {
    try testLivenessErr(
        \\@section foo
        \\@define bar, 5
        \\foo: mst sf, @bar
        \\jmpr 0x00
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\@define bar, @roo
        \\@define roo, 5
        \\foo: mst sf, @bar
        \\jmpr 0x00
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\@define bar, 5
        \\foo: mst sf, 5
        \\jmpr 0x00
    , &.{
        error.UnusedPrivateSymbol
    });

    try testLivenessErr(
        \\@section foo
        \\@define bar, 5
        \\.foo: mst sf, 5
        \\jmpr 0x00
    , &.{
        error.UnusedPrivateSymbol,
        error.UnusedPrivateSymbol
    });
}

test "full fledge" {
    try testLivenessErr(
        \\@section foo
        \\@align 16
        \\main:         ast ra
        \\              ast rb
        \\              rst rb
        \\              jmpr 0x00
        \\@align 8
        \\@region 24
        \\foo:          u8 0x00
        \\              u16 0x0000
        \\@end
        \\@section bar
        \\bar:          jmpr 0x00
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\@align 16
        \\main:         ast ra
        \\              ast ra
        \\.foo:         rst rb
        \\@align 8
        \\@define aaaaaaaaaaaa, 0
        \\@region 24
        \\              cli
        \\              u8 0x00
        \\              u16 0x0000
        \\@end
        \\@section bar
        \\bar:          cli
        \\@section roo
        \\roo:          u8 0x00
    , &.{
        error.DuplicateStore,
        error.UncoordinatedPadding,
        error.NotePaddingHere,
        // fixme: the 'cli' after @align is invalid
        // error.UnreachableOpaque,
        // error.NoteDivertedHere,
        error.UncoordinatedData,
        error.NoteDefinedHere,
        error.UndefinedControlFlow,
        error.UnusedPrivateSymbol,
        error.UnusedPrivateSymbol
    });
}
