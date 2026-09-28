const std = @import("std");
const tokota = @import("tokota");

comptime {
    tokota.exportModule(@This());
}

/// Say hello
pub fn sayHello(call: tokota.Call) ![]const u8 {
    _ = call;
    return "[INFO] Hello from Zig Node.js addon! v0.3.0";
}

/// Add two numbers
pub fn add(call: tokota.Call) ![]const u8 {
    const obj = try call.argsAs(.{tokota.Val});
    const params = obj[0].object(call.env);
    const a = try params.getT("a", f64);
    const b = try params.getT("b", f64);

    return std.fmt.allocPrint(std.heap.c_allocator, "[INFO] Output: {d}", .{a + b});
}
