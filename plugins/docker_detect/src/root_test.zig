// root.zig 编译检查：napi 符号由 Node 运行时提供，独立测试二进制无法链接，
// 因此本模块只做语义分析（build.zig 中 generated_bin = null），不执行任何测试。
const root = @import("root.zig");

comptime {
    // pub 方法引用即强制语义分析（detect 函数体随之传递分析）
    _ = &root.detect;
}

test {
    _ = root;
}
