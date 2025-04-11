
// Liveness
//
//  remove bullshit assembly
//  - empty sections
//  - unlabeled instruction after unconditional jump/@section
//  - two consecutive register store operations to same locations
//  - unlabeled data points?
//  - unused private defines/headers/labels?
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

pub fn init(qcu: *Qcu.File) !AsmLiveness {
    var self = AsmLiveness {
        .qcu = qcu,
        .allocator = qcu.allocator,
        .source = qcu.source,
        .symbols = qcu.symbols,
        .sections = qcu.sections,
        .errors = .empty };
    errdefer self.deinit();
    try self.liveness_root();
    return self;
}

pub fn init_freestanding(
    allocator: std.mem.Allocator,
    source: Source,
    sections: *const SectionMap,
    symbols: *const SymbolMap
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
}

const LivenessTrack = struct {
    token: Token,
    is_labeled: bool,
    instruction: AsmSemanticAir.Instruction,
    tag: AsmSemanticAir.Instruction.Tag
};

fn liveness_inner(self: *AsmLiveness, section: *const Section) !void {
    if (try self.pass_empty_section(section)) return;
    var previous_track: ?LivenessTrack = null;

    const tokens = section.content.items(.token);
    const is_labeleds = section.content.items(.is_labeled);
    const instructions = section.content.items(.instruction);

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
        } else {
            try self.pass_unreachable_section(section, &track);
        }
    }
}

fn pass_empty_section(self: *AsmLiveness, section: *const Section) !bool {
    if (section.content.len == 0) {
        try self.add_error(error.EmptySection, section.token);
        return true;
    }
    return false;
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
    if (!current.is_labeled and (previous.tag.is_jump() or previous.tag.is_confusing_size())) {
        try self.add_error(error.UnreachableOpaque, current.token);
        if (previous.tag.is_confusing_size())
            try self.add_error(error.NoteConfusingSize, previous.token) else
            try self.add_error(error.NoteDivertedHere, previous.token);
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

    return .{ ast, sema, try AsmLiveness.init_freestanding(std.testing.allocator, source, &sema.sections, &sema.symbols) };
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

    if (options.dump) {
        for (liveness.errors.items) |err|
            try err.write("test.s", input, stderr);
    }

    var liveness_errors = std.ArrayList(anyerror).init(std.testing.allocator);
    defer liveness_errors.deinit();
    for (liveness.errors.items) |err|
        try liveness_errors.append(err.id);
    if (!std.mem.eql(anyerror, errors, liveness_errors.items)) {
        for (liveness.errors.items) |err|
            try err.write("test.s", input, stderr);
        try std.testing.expectEqualSlices(anyerror, errors, liveness_errors.items);
    }
}

test "unused sections" {
    try testLivenessErr(
        \\@section foo
        \\foo: cli
        \\@barrier
        \\bar: cli
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\@barrier
        \\foo: cli
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
        \\ascii "hi mum!"
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
    , &.{}); // fixme: should generate empty section error

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

test "doubly write to same register" {
    try testLivenessErr(
        \\@section foo
        \\foo:
        \\ast ra
        \\ast rb
        \\ast rc
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\foo:
        \\ast ra
        \\ast ra
        \\ast rc
    , &.{
        error.DuplicateStore
    });
}

test "unlabeled instruction after @section" {
    try testLivenessErr(
        \\@section foo
        \\foo: cli
    , &.{});

    try testLivenessErr(
        \\@section foo
        \\cli
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
        error.NotePaddingHere
    });

    try testLivenessErr(
        \\@section foo
        \\@region 24
        \\foo: cli
        \\     u8 0x00
        \\@end
    , &.{}); // fixme: unlabeled executable after data, data spills after non-jump executable

    try testLivenessErr(
        \\@section foo
        \\cli
        \\@barrier
        \\cli
    , &.{
        error.UnreachableOpaque,
        error.NoteDefinedHere,
        error.UnreachableOpaque,
        error.NoteDefinedHere
    });
}
