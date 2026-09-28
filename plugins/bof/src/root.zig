const std = @import("std");
const tokota = @import("tokota");

comptime {
    tokota.exportModule(@This());
}

const c = @cImport({
    @cInclude("bof_launcher_api.h");
});

pub fn executeBof(call: tokota.Call) ![]const u8 {
    const allocator = std.heap.c_allocator;

    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);
    const bof_data = try (try params.get("bof_file")).buffer(call.env);
    const args_str = try (try params.get("args")).stringAlloc(call.env, allocator);
    defer allocator.free(args_str);

    var bof_handle: c.BofObjectHandle = undefined;
    const init_rc = c.bofObjectInitFromMemory(bof_data.data.ptr, @intCast(bof_data.data.len), &bof_handle);
    if (init_rc < 0) {
        return std.fmt.allocPrint(allocator, "[ERRO] failed to parse BOF object from memory (code: {d}, size: {d})", .{ init_rc, bof_data.data.len });
    }
    defer c.bofObjectRelease(bof_handle);

    var bof_args: ?*c.BofArgs = null;
    if (c.bofArgsInit(&bof_args) < 0) {
        return std.fmt.allocPrint(allocator, "[ERRO] bofArgsInit failed", .{});
    }
    defer c.bofArgsRelease(bof_args);

    c.bofArgsBegin(bof_args);
    _ = c.bofArgsAdd(bof_args, args_str.ptr, @intCast(args_str.len));
    c.bofArgsEnd(bof_args);

    var context: ?*c.BofContext = null;
    const run_rc = c.bofObjectRun(bof_handle, @constCast(c.bofArgsGetBuffer(bof_args)), c.bofArgsGetBufferSize(bof_args), &context);
    if (run_rc < 0) {
        return std.fmt.allocPrint(allocator, "[ERRO] bofObjectRun failed (code: {d})", .{run_rc});
    }
    defer c.bofContextRelease(context);

    const output = c.bofContextGetOutput(context, null);
    if (output) |out| {
        const len = std.mem.len(out);
        const result = try std.fmt.allocPrint(allocator, "[INFO] BOF output:\n{s}", .{out[0..len]});
        return result;
    }

    return "[INFO] BOF executed, no output";
}
