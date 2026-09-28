// root.zig 编译检查：napi 符号由 Node 运行时提供，独立测试二进制无法链接，
// 因此本模块只做语义分析（build.zig 中 generated_bin = null），不执行任何测试。
const root = @import("root.zig");

comptime {
    // pub 方法引用即强制语义分析（runSub 经由方法体传递分析）；
    // 私有 decl 不可跨文件引用，无需单独列出。
    _ = &root.scan;
    _ = &root.mcp;
    _ = &root.a2a;
    _ = &root.llm;
}

test {
    _ = root;
}
