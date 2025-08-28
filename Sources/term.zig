
const std = @import("std");

const stdin = std.posix.STDIN_FILENO;
const flush = std.posix.system.TCSA.FLUSH;

pub fn enable_raw(io: anytype) !std.posix.termios {
    const original_termios = try std.posix.tcgetattr(stdin);
    var termios = original_termios;
    termios.lflag.ICANON = false; // disable canonical mode
    termios.lflag.ECHO = false; // disable echo
    termios.lflag.ISIG = false; // disable input signals
    try std.posix.tcsetattr(stdin, flush, termios);

    // https://zig.news/lhp/want-to-create-a-tui-application-the-basics-of-uncooked-terminal-io-17gm
    try io.writeAll("\x1B[s"); // save cursor
    try io.writeAll("\x1B[?25l"); // hide cursor
    try io.writeAll("\x1B[?47h"); // save screen
    try io.writeAll("\x1B[?1049h"); // enable alt screen

    return original_termios;
}

pub fn restore_termio(io: anytype, termio: std.posix.termios) !void {
    try std.posix.tcsetattr(stdin, flush, termio);
    try io.writeAll("\x1B[?1049l"); // disable alt screen
    try io.writeAll("\x1B[?47l"); // restore screen
    try io.writeAll("\x1B[?25h"); // show cursor
    try io.writeAll("\x1B[u"); // restore cursor
}

pub fn clear_termio(io: anytype) !void {
    try io.writeAll("\x1B[2J");
}

pub fn move_termio(io: anytype, col: usize, row: usize) !void {
    try io.print("\x1B[{};{}H", .{ row + 1, col + 1 });
}
