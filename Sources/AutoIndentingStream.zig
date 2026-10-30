
//
// The MIT License (Expat)
//
// Copyright (c) Zig contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

const std = @import("std");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Automatically inserts indentation of written data by keeping
/// track of the current indentation level
///
/// We introduce a new indentation scope with pushIndent/popIndent whenever
/// we potentially want to introduce an indent after the next newline.
///
/// Indentation should only ever increment by one from one line to the next,
/// no matter how many new indentation scopes are introduced. This is done by
/// only realizing the indentation from the most recent scope. As an example:
///
///         while (foo) if (bar)
///             f(x);
///
/// The body of `while` introduces a new indentation scope and the body of
/// `if` also introduces a new indentation scope. When the newline is seen,
/// only the indentation scope of the `if` is realized, and the `while` is
/// not.
///
/// As comments are rendered during space rendering, we need to keep track
/// of the appropriate indentation level for them with pushSpace/popSpace.
/// This should be done whenever a scope that ends in a .semicolon or a
/// .comma is introduced.

const AutoIndentingStream = @This();

const Space = enum {
    /// Output the token lexeme only.
    none,
    /// Output the token lexeme followed by a single space.
    space,
    /// Output the token lexeme followed by a newline.
    newline,
    /// If the next token is a comma, render it as well. If not, insert one.
    /// In either case, a newline will be inserted afterwards.
    comma,
    /// Additionally consume the next token if it is a comma.
    /// In either case, a space will be inserted afterwards.
    comma_space,
    /// Additionally consume the next token if it is a semicolon.
    /// In either case, a newline will be inserted afterwards.
    semicolon,
    /// If the next token is not a multiline string literal, this acts as .space,
    /// otherwise this acts as .none.
    maybe_space,
    /// Additionally consume the next token if it is a comma.
    /// In either case, a space will be inserted afterwards
    /// if the following token is not a multiline string literal.
    comma_maybe_space,
    /// Skip rendering whitespace and comments. If this is used, the caller
    /// *must* handle whitespace and comments manually.
    skip,
};

const Error = error{
    /// Ran out of memory allocating call stack frames to complete rendering.
    OutOfMemory,
    /// Transitive failure from
    WriteFailed,
};

underlying_writer: *Writer,

/// Offset into the source at which formatting has been disabled with
/// a `zig fmt: off` comment.
///
/// If non-null, the AutoIndentingStream will not write any bytes
/// to the underlying writer. It will however continue to track the
/// indentation level.
disabled_offset: ?usize = null,

indent_count: usize = 0,
indent_delta: usize,
indent_stack: std.array_list.Managed(StackElem),
space_stack: std.array_list.Managed(SpaceElem),
space_mode: ?usize = null,
disable_indent_committing: usize = 0,
current_line_empty: bool = true,
/// the most recently applied indent
applied_indent: usize = 0,

pub const IndentType = enum {
    normal,
    after_equals,
    binop,
    field_access,
};
const StackElem = struct {
    indent_type: IndentType,
    realized: bool,
};
const SpaceElem = struct {
    space: Space,
    indent_count: usize,
};

pub fn init(gpa: Allocator, w: *Writer, starting_indent_delta: usize) AutoIndentingStream {
    return .{
        .underlying_writer = w,
        .indent_delta = starting_indent_delta,
        .indent_stack = .init(gpa),
        .space_stack = .init(gpa),
    };
}

pub fn deinit(self: *AutoIndentingStream) void {
    self.indent_stack.deinit();
    self.space_stack.deinit();
}

pub fn writeAll(ais: *AutoIndentingStream, bytes: []const u8) Error!void {
    if (bytes.len == 0) return;
    try ais.applyIndent();
    if (ais.disabled_offset == null) try ais.underlying_writer.writeAll(bytes);
    if (bytes[bytes.len - 1] == '\n') ais.resetLine();
}

/// Assumes that if the printed data ends with a newline, it is directly
/// contained in the format string.
pub fn print(ais: *AutoIndentingStream, comptime format: []const u8, args: anytype) Error!void {
    try ais.applyIndent();
    if (ais.disabled_offset == null) try ais.underlying_writer.print(format, args);
    if (format[format.len - 1] == '\n') ais.resetLine();
}

pub fn writeByte(ais: *AutoIndentingStream, byte: u8) Error!void {
    try ais.applyIndent();
    if (ais.disabled_offset == null) try ais.underlying_writer.writeByte(byte);
    assert(byte != '\n');
}

pub fn splatByteAll(ais: *AutoIndentingStream, byte: u8, n: usize) Error!void {
    assert(byte != '\n');
    try ais.applyIndent();
    if (ais.disabled_offset == null) try ais.underlying_writer.splatByteAll(byte, n);
}

// Change the indent delta without changing the final indentation level
pub fn setIndentDelta(ais: *AutoIndentingStream, new_indent_delta: usize) void {
    if (ais.indent_delta == new_indent_delta) {
        return;
    } else if (ais.indent_delta > new_indent_delta) {
        assert(ais.indent_delta % new_indent_delta == 0);
        ais.indent_count = ais.indent_count * (ais.indent_delta / new_indent_delta);
    } else {
        // assert that the current indentation (in spaces) in a multiple of the new delta
        assert((ais.indent_count * ais.indent_delta) % new_indent_delta == 0);
        ais.indent_count = ais.indent_count / (new_indent_delta / ais.indent_delta);
    }
    ais.indent_delta = new_indent_delta;
}

pub fn insertNewline(ais: *AutoIndentingStream) Error!void {
    if (ais.disabled_offset == null) try ais.underlying_writer.writeByte('\n');
    ais.resetLine();
}

/// Insert a newline unless the current line is blank
pub fn maybeInsertNewline(ais: *AutoIndentingStream) Error!void {
    if (!ais.current_line_empty)
        try ais.insertNewline();
}

/// Checks to see if the most recent indentation exceeds the currently pushed indents
pub fn isLineOverIndented(ais: *AutoIndentingStream) bool {
    if (ais.current_line_empty) return false;
    return ais.applied_indent > ais.currentIndent();
}

fn resetLine(ais: *AutoIndentingStream) void {
    ais.current_line_empty = true;

    if (ais.disable_indent_committing > 0) return;

    if (ais.indent_stack.items.len > 0) {
        // By default, we realize the most recent indentation scope.
        var to_realize = ais.indent_stack.items.len - 1;

        if (ais.indent_stack.items.len >= 2 and
            ais.indent_stack.items[to_realize - 1].indent_type == .after_equals and
            ais.indent_stack.items[to_realize - 1].realized and
            ais.indent_stack.items[to_realize].indent_type == .binop)
        {
            // If we are in a .binop scope and our direct parent is .after_equals, don't indent.
            // This ensures correct indentation in the below example:
            //
            //        const foo =
            //            (x >= 'a' and x <= 'z') or         //<-- we are here
            //            (x >= 'A' and x <= 'Z');
            //
            return;
        }

        if (ais.indent_stack.items[to_realize].indent_type == .field_access) {
            // Only realize the top-most field_access in a chain.
            while (to_realize > 0 and ais.indent_stack.items[to_realize - 1].indent_type == .field_access)
                to_realize -= 1;
        }

        if (ais.indent_stack.items[to_realize].realized) return;
        ais.indent_stack.items[to_realize].realized = true;
        ais.indent_count += 1;
    }
}

/// Disables indentation level changes during the next newlines until re-enabled.
pub fn disableIndentCommitting(ais: *AutoIndentingStream) void {
    ais.disable_indent_committing += 1;
}

pub fn enableIndentCommitting(ais: *AutoIndentingStream) void {
    assert(ais.disable_indent_committing > 0);
    ais.disable_indent_committing -= 1;
}

pub fn pushSpace(ais: *AutoIndentingStream, space: Space) !void {
    try ais.space_stack.append(.{ .space = space, .indent_count = ais.indent_count });
}

pub fn popSpace(ais: *AutoIndentingStream) void {
    _ = ais.space_stack.pop();
}

/// Sets current indentation level to be the same as that of the last pushSpace.
pub fn enableSpaceMode(ais: *AutoIndentingStream, space: Space) void {
    if (ais.space_stack.items.len == 0) return;
    const curr = ais.space_stack.last().?;
    if (curr.space != space) return;
    ais.space_mode = curr.indent_count;
}

pub fn disableSpaceMode(ais: *AutoIndentingStream) void {
    ais.space_mode = null;
}

pub fn lastSpaceModeIndent(ais: *AutoIndentingStream) usize {
    if (ais.space_stack.items.len == 0) return 0;
    return ais.space_stack.last().?.indent_count * ais.indent_delta;
}

/// Push default indentation
/// Doesn't actually write any indentation.
/// Just primes the stream to be able to write the correct indentation if it needs to.
pub fn pushIndent(ais: *AutoIndentingStream, indent_type: IndentType) !void {
    try ais.indent_stack.append(.{ .indent_type = indent_type, .realized = false });
}

/// Forces an indentation level to be realized.
pub fn forcePushIndent(ais: *AutoIndentingStream, indent_type: IndentType) !void {
    try ais.indent_stack.append(.{ .indent_type = indent_type, .realized = true });
    ais.indent_count += 1;
}

pub fn popIndent(ais: *AutoIndentingStream) void {
    if (ais.indent_stack.pop().?.realized) {
        ais.indent_count -= 1;
    }
}

/// Forces the last pushed indent to be realized
pub fn forceLastIndent(ais: *AutoIndentingStream) void {
    const top = &ais.indent_stack.items[ais.indent_stack.items.len - 1];
    if (!top.realized) {
        top.realized = true;
        ais.indent_count += 1;
    }
}

pub fn indentStackEmpty(ais: *AutoIndentingStream) bool {
    return ais.indent_stack.items.len == 0;
}

/// Writes ' ' bytes if the current line is empty
fn applyIndent(ais: *AutoIndentingStream) Error!void {
    const current_indent = ais.currentIndent();
    if (ais.current_line_empty) {
        if (current_indent > 0 and ais.disabled_offset == null) {
            try ais.underlying_writer.splatByteAll(' ', current_indent);
        }
        ais.applied_indent = current_indent;
    }
    ais.current_line_empty = false;
}

fn currentIndent(ais: *AutoIndentingStream) usize {
    const indent_count = ais.space_mode orelse ais.indent_count;
    return indent_count * ais.indent_delta;
}
