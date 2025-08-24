
// Linker

const std = @import("std");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const Error = @import("Error.zig");
const Qcu = @import("Qcu.zig");
const Token = @import("Token.zig");

const Linker = @This();

allocator: std.mem.Allocator,
options: Qcu.Options,
link_list: SectionLinkList,
blocks: BlockList, 

const Section = struct {

    identifier: []const u8,
    file: *Qcu.File,
    inner: *AsmSemanticAir.Section,
    is_poked: bool
};

const Block = struct {

    content: void
};

const SectionLinkList = std.ArrayListUnmanaged(Section);
const BlockList = std.ArrayListUnmanaged(Block);

pub fn init(allocator: std.mem.Allocator, options: Qcu.Options) Linker {
    return .{
        .allocator = allocator,
        .options = options,
        .link_list = .empty,
        .blocks = .empty };
}

pub fn deinit(self: *Linker) void {
    self.link_list.deinit(self.allocator);
    self.blocks.deinit(self.allocator);
}

pub fn dump(self: *Linker, writer: anytype) !void {
    for (self.link_list.items) |section| {
        try writer.print("@section {s} (align {}, referenced {})\n", .{
            section.identifier,
            section.inner.alignment,
            section.is_poked });
    }
}

pub fn append(self: *Linker, file: *Qcu.File) !void {
    const sema = file.sema orelse unreachable;

    for (sema.sections.keys()) |section_name| {
        var section: ?*AsmSemanticAir.Section = sema.sections.get(section_name) orelse unreachable;

        while (section) |section_| {
            try self.link_list.append(self.allocator, .{
                .identifier = section_name,
                .file = file,
                .inner = section_,
                .is_poked = !section_.is_removable });
            section = section_.next;
        }
    }
}

const LinkError = error {
    DuplicateGlobalSection,
    MissingGlobalSection,
    DuplicateLinkingInfo,
    NoteDefinedHere,
    NoteNotLinked
};

fn add_error(self: *Linker, comptime err: LinkError, target: *Qcu.File, argument: anytype) !void {
    @branchHint(.cold);

    const message = switch (err) {
        error.DuplicateGlobalSection => "duplicate global section '{s}' (no stable memory layout)",
        error.MissingGlobalSection => "missing global section '{s}'",
        error.DuplicateLinkingInfo => "multiply defined linking info",
        error.NoteDefinedHere => "{s} defined here",
        error.NoteNotLinked => "symbol defined here not linked"
    };

    const is_note = switch (err) {
        error.NoteDefinedHere,
        error.NoteNotLinked => true,
        else => false
    };

    const token: ?Token = switch (err) {
        error.DuplicateGlobalSection => argument[1],
        error.MissingGlobalSection => null,
        error.NoteDefinedHere => argument[1],
        error.DuplicateLinkingInfo,
        error.NoteNotLinked => argument
    };
    const token_location = if (token) |token_|
        target.source.?.location_of(token_.location) else
        null;
    const token_slice = if (token) |token_|
        token_.location.slice(target.source.?.buffer) else
        null;
    const arguments = switch (err) {
        error.DuplicateGlobalSection => .{ argument[0] },
        error.MissingGlobalSection => .{ argument },
        error.DuplicateLinkingInfo => .{},
        error.NoteDefinedHere => .{ argument[0].fmt() },
        error.NoteNotLinked => .{ token_slice.? }
    };

    const format = try std.fmt.allocPrint(self.allocator, message, arguments);
    errdefer self.allocator.free(format);

    const err_data = Error {
        .id = err,
        .token = token,
        .is_note = is_note,
        .message = format,
        .location = token_location };
    try target.add_error(err_data);
}

pub fn tree_elimination(self: *Linker) !void {
    const root_section = try self.get_root_section() orelse return;
    try self.poke_section_tree(root_section);
    self.remove_unpoked_inplace();

    for (self.link_list.items) |referenced_section|
        std.debug.assert(referenced_section.is_poked);
}

fn get_root_section(self: *Linker) !?*Section {
    return try self.find_single_section(self.options.rootsection) orelse {
        try self.add_error(error.MissingGlobalSection, self.link_list.items[0].file, self.options.rootsection);
        return null;
    };
}

fn find_single_section(self: *Linker, name: []const u8) !?*Section {
    var result: ?*Section = null;

    for (self.link_list.items) |*section| {
        if (!std.mem.eql(u8, section.identifier, name))
            continue;
        if (result) |existing_result| {
            try self.add_error(error.DuplicateGlobalSection, section.file, .{ name, section.inner.token });
            try self.add_error(error.NoteDefinedHere, existing_result.file, .{ existing_result.inner.token.tag, existing_result.inner.token });
            continue;
        }

        result = section;
    }

    return result;
}

fn poke_section_tree(self: *Linker, section: *Section) !void {
    if (section.is_poked)
        return;
    section.is_poked = true;

    loop: for (section.inner.content.items(.instruction)) |instruction| {
        switch (instruction) {
            .ld_padding => {},

            inline else => |operands| {
                if (@typeInfo(@TypeOf(operands)) != .@"struct") continue :loop;
                @setEvalBranchQuota(9999);

                oper: inline for (operands) |operand| {
                    if (!@hasField(@TypeOf(operand), "result") or !@hasField(@TypeOf(operand.result), "linktime_label"))
                        continue :oper;
                    if (operand.result.linktime_label) |linktime_label| {
                        // semantic analysis verifies that the imported reference exists
                        const foreign_reference = linktime_label.sema.references.get(linktime_label.name) orelse unreachable;
                        const linker_section = self.find_linker_section(foreign_reference.section) orelse unreachable;
                        try self.poke_section_tree(linker_section);
                    }
                }
            }
        }
    }
}

fn find_linker_section(self: *Linker, sema_section: *AsmSemanticAir.Section) ?*Section {
    for (self.link_list.items) |*section| {
        if (section.inner == sema_section)
            return section;
    }

    return null;
}

fn remove_unpoked_inplace(self: *Linker) void {
    var index: usize = 0;

    while (index < self.link_list.items.len) {
        if (!self.link_list.items[index].is_poked) {
            _ = self.link_list.swapRemove(index);
            // new element possibly at this index, so no increment
        } else {
            index += 1;
        }
    }
}

pub fn generate(self: *Linker) !void {
    for (try self.find_single_linkinfo() orelse return) |link_node| {
        std.debug.print("{s} ({s}) = {}\n", .{ link_node.key, link_node.subject orelse "?", link_node.value });
    }
}

fn find_single_linkinfo(self: *Linker) !?[]const AsmSemanticAir.LinkInfo {
    var result: ?*const AsmSemanticAir = null;

    for (self.link_list.items) |section| {
        const sema = &section.file.sema.?;

        if (result == sema or sema.link_info.items.len == 0)
            continue;
        if (result) |existing_result| {
            const first_info_token = sema.link_info.items[0].token;
            const existing_info_token = existing_result.link_info.items[0].token;
            try self.add_error(error.DuplicateLinkingInfo, section.file, first_info_token);
            try self.add_error(error.NoteDefinedHere, existing_result.qcu.?, .{ existing_info_token.tag, existing_info_token });
            continue;
        }

        result = sema;
    }

    return if (result) |result_|
        result_.link_info.items else
        null;
}

// Tests

const options_ = @import("options");

const stderr = std.io
    .getStdErr()
    .writer();

fn testLinkerQueue(files: []const []const u8) !*Qcu {
    return try Qcu.init(
        std.testing.allocator,
        std.fs.cwd(),
        files,
        .{ .noliveness = true });
}

fn testQueue(qcu: *Qcu, errors: []const anyerror) !void {
    while (qcu.work_queue.removeOrNull()) |job| {
        job.execute() catch |err| {
            if (errors.len == 0) {
                std.debug.print("failed on job {s} with {}\n", .{ @tagName(std.meta.activeTag(job)), err });
                for (qcu.errors.items) |the_err|
                    try the_err.write(stderr);
                return err;
            }

            var qcu_errors = std.ArrayList(anyerror).init(std.testing.allocator);
            defer qcu_errors.deinit();
            for (qcu.errors.items) |the_err|
                try qcu_errors.append(the_err.err.id);
            if (!std.mem.eql(anyerror, errors, qcu_errors.items)) {
                for (qcu.errors.items) |the_err|
                    try the_err.write(stderr);
                try std.testing.expectEqualSlices(anyerror, errors, qcu_errors.items);
            }
            return;
        };
    }
}

test "root section duplicate" {
    var qcu = try testLinkerQueue(&.{ "Tests/bad_root.1.s" });
    defer qcu.deinit();

    try testQueue(qcu, &.{
        error.DuplicateGlobalSection,
        error.NoteDefinedHere });
}

test "root section missing" {
    var qcu = try testLinkerQueue(&.{ "Tests/sample.s" });
    defer qcu.deinit();

    try testQueue(qcu, &.{ error.MissingGlobalSection });
}

test "full fledge" {
    const files = &[_][]const u8 { "Tests/root.s", "Tests/sample.s" };
    const qcu = try Qcu.init(std.testing.allocator, std.fs.cwd(), files, .{});
    defer qcu.deinit();

    try testQueue(qcu, &.{});

    if (options_.dump)
        try qcu.linker.dump(stderr);
}
