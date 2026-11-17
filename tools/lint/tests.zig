//! The custom zlinter rules' tests, one root for `zig build test-lint-rules`.

test {
    std.testing.refAllDecls(@import("callbacks_last.zig"));
    std.testing.refAllDecls(@import("comment_sentences.zig"));
    std.testing.refAllDecls(@import("div_intent.zig"));
    std.testing.refAllDecls(@import("fn_length.zig"));
    std.testing.refAllDecls(@import("line_length.zig"));
    std.testing.refAllDecls(@import("loop_bound.zig"));
    std.testing.refAllDecls(@import("no_compound_assert.zig"));
    std.testing.refAllDecls(@import("no_twin_int_params.zig"));
    std.testing.refAllDecls(@import("qualifier_last.zig"));
    std.testing.refAllDecls(@import("recursion_bound.zig"));
}

const std = @import("std");
