const std = @import("std");

const chk = @import("chunk.zig");
const val = @import("value.zig");
const dbg = @import("debug.zig");
const flg = @import("flags.zig");

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

pub const VirtualMachine = struct {
    chunk: chk.Chunk,
    ip: [*]u8,

    pub fn init() VirtualMachine {
        return VirtualMachine{
            .chunk = undefined,
            .ip = undefined,
        };
    }

    // pub fn deinit(self: *VirtualMachine) !void {}

    pub fn interpret(self: *VirtualMachine, chunk: chk.Chunk) InterpretError!void {
        self.chunk = chunk;
        // Initialize self.ip with the pointers of the slice/array.
        self.ip = chunk.code.items.ptr;
        return self.run();
    }

    fn run(self: *VirtualMachine) InterpretError!void {
        // Note that self.read_byte() advances the pointer
        while (true) {
            if (flg.DEBUG_TRACE_EXECUTION) {
                // @intFromPtr converts a pointer to its usize address.
                // Since arrays are contiguous, we can compute the distance from the
                // first element.
                const offset: usize = @intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr);
                _ = dbg.disassemble_instruction(self.chunk, offset);
            }

            const instruction: chk.OpCode = @enumFromInt(self.read_byte());

            switch (instruction) {
                chk.OpCode.OpConstant => {
                    const constant: val.Value = self.read_constant();
                    val.print_value(constant);
                    std.debug.print("\n", .{});
                    return;
                },
                chk.OpCode.OpReturn => return,
            }
        }
    }

    // Inline function to emulate C macro
    inline fn read_byte(self: *VirtualMachine) u8 {
        // self.ip is a many-item pointer.
        // The first element points to start of the slice.
        const value: u8 = self.ip[0];
        // Pointer arithmetic below. We advance self.ip to the pointer of the next
        // element in the slice.
        self.ip += 1;
        return value;
    }

    inline fn read_constant(self: *VirtualMachine) val.Value {
        return self.chunk.constants.items[self.read_byte()];
    }
};
