const std = @import("std");

const chk = @import("chunk.zig");
const val = @import("value.zig");

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

pub const VirtualMachine = struct {
    chunk: chk.Chunk,
    ip: usize,

    pub fn init() VirtualMachine {
        return VirtualMachine{
            .chunk = undefined,
            .ip = undefined,
        };
    }

    // pub fn deinit(self: *VirtualMachine) !void {}

    pub fn interpret(self: *VirtualMachine, chunk: chk.Chunk) InterpretError!void {
        self.chunk = chunk;
        self.ip = 0;
        return self.run();
    }

    fn run(self: *VirtualMachine) InterpretError!void {
        while (true) {
            const instruction: chk.OpCode = @enumFromInt(self.read_byte());

            switch (instruction) {
                chk.OpCode.OpConstant => {
                    const constant: val.Value = self.chunk.constants.items[self.read_byte()];
                    val.print_value(constant);
                    std.debug.print("\n", .{});
                    return;
                },
                chk.OpCode.OpReturn => return,
            }
        }
    }

    fn read_byte(self: *VirtualMachine) u8 {
        const value: u8 = self.chunk.code.items[self.ip];
        self.ip += 1;
        return value;
    }
};
