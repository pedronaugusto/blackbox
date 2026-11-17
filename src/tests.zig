//! Every test, from one root.

test {
    _ = @import("blackbox.zig");
    _ = @import("testing/logger_test.zig");
    _ = @import("testing/encode_test.zig");
}
