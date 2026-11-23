
const std = @import("std");

const stdin = std.posix.STDIN_FILENO;
const flush = std.posix.system.TCSA.FLUSH;

pub fn enableRaw(writer: *std.Io.Writer) !std.posix.termios {
    const original_termios = try std.posix.tcgetattr(stdin);

    var termios = original_termios;
    termios.lflag.ICANON = false; // disable canonical mode
    termios.lflag.ECHO = false; // disable echo
    termios.lflag.ISIG = false; // disable input signals
    try std.posix.tcsetattr(stdin, flush, termios);

    try writer.writeAll("\x1B[s"); // save cursor
    try writer.writeAll("\x1B[?25l"); // hide cursor
    try writer.writeAll("\x1B[?47h"); // save screen
    try writer.writeAll("\x1B[?1049h"); // enable alt screen
    try writer.flush();

    return original_termios;
}

pub fn restore(writer: *std.Io.Writer, termio: std.posix.termios) !void {
    try std.posix.tcsetattr(stdin, flush, termio);
    try writer.writeAll("\x1B[?1049l"); // disable alt screen
    try writer.writeAll("\x1B[?47l"); // restore screen
    try writer.writeAll("\x1B[?25h"); // show cursor
    try writer.writeAll("\x1B[u"); // restore cursor
    try writer.flush();
}

pub fn clear(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[2J");
}

pub fn move(writer: *std.Io.Writer, col: usize, row: usize) !void {
    try writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
}
