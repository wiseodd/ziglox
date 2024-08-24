const std = @import("std");

const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;

const Value = @import("value.zig").Value;
const print_value = @import("value.zig").print_value;

const debug = @import("debug.zig");
const flags = @import("flags.zig");

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

pub const VirtualMachine = struct {
    chunk: Chunk,
    ip: [*]u8,
    stack: std.ArrayList(Value),

    pub fn init(allocator: std.mem.Allocator) VirtualMachine {
        return VirtualMachine{
            .chunk = undefined,
            .ip = undefined,
            .stack = std.ArrayList(Value).init(allocator),
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.stack.deinit();
    }

    pub fn interpret(self: *VirtualMachine, chunk: Chunk) InterpretError!void {
        self.chunk = chunk;
        // Initialize self.ip with the pointers of the slice/array.
        self.ip = chunk.code.items.ptr;
        return self.run();
    }

    fn run(self: *VirtualMachine) InterpretError!void {
        // Note that self.read_byte() advances the pointer
        while (true) {
            if (flags.DEBUG_TRACE_EXECUTION) {
                std.debug.print("          ", .{});
                for (self.stack.items) |slot| {
                    std.debug.print("[ ", .{});
                    print_value(slot);
                    std.debug.print(" ]", .{});
                }
                std.debug.print("\n", .{});

                // @intFromPtr converts a pointer to its usize address.
                // Since arrays are contiguous, we can compute the distance from the
                // first element.
                const offset: usize = @intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr);
                _ = debug.disassemble_instruction(self.chunk, offset);
            }

            const instruction: OpCode = @enumFromInt(self.read_byte());

            switch (instruction) {
                OpCode.OpConstant => {
                    const constant: Value = self.read_constant();
                    self.stack.append(constant) catch |err| switch (err) {
                        std.mem.Allocator.Error.OutOfMemory => {
                            std.debug.print("Stack overflow!\n", .{});
                            return error.RuntimeError;
                        },
                    };
                    return;
                },
                OpCode.OpReturn => {
                    print_value(self.stack.pop());
                    std.debug.print("\n", .{});
                    return;
                },
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

    inline fn read_constant(self: *VirtualMachine) Value {
        return self.chunk.constants.items[self.read_byte()];
    }
};
