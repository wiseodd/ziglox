const std = @import("std");
const flags = @import("flags.zig");
const Value = @import("value.zig").Value;
const String = @import("object.zig").String;

const TABLE_MAX_LOAD: f32 = 0.75;

pub const Entry = struct {
    key: ?*String,
    value: Value,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    count: usize,
    entries: []Entry,

    pub fn init(allocator: std.mem.Allocator) Table {
        return Table{
            .allocator = allocator,
            .count = 0,
            .entries = undefined,
        };
    }

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.entries);
        self.count = 0;
        self.entries = undefined;
    }

    pub fn get(self: *Table, key: *String) ?*Entry {
        if (self.count == 0) return null;

        const entry: *Entry = self.find(key);
        if (entry.key == null) return null;

        return entry.value;
    }

    pub fn upsert(self: *Table, key: *String, value: Value) bool {
        if (@as(f32, @floatFromInt(@as(u32, @truncate(self.count + 1)))) > @as(f32, @floatFromInt(@as(u32, @truncate(self.entries.len)))) * TABLE_MAX_LOAD) {
            self.adjust_capacity();
        }

        const entry: *Entry = self.find(key);
        const is_new: bool = (entry.key == null);

        if (is_new and entry.value.is_nil()) self.count += 1;

        entry.key = key;
        entry.value = value;

        return is_new;
    }

    pub fn find(self: *Table, key: *String) *Entry {
        var index: u32 = key.hash % @as(u32, @truncate(self.entries.len));
        var tombstone: ?*Entry = null;

        while (true) : (index = (index + 1) % @as(u32, @truncate(self.entries.len))) {
            const entry: *Entry = &self.entries[index];

            if (entry.key == null) {
                if (entry.value.is_nil()) {
                    return tombstone orelse entry;
                } else {
                    if (tombstone == null) tombstone = entry;
                }
            } else if (entry.key.? == key) {
                return entry;
            }
        }
    }

    pub fn find_key(self: *Table, chars: []const u8, hash: u32) ?*String {
        if (self.count == 0) return null;

        var index: u32 = hash % @as(u32, @truncate(self.entries.len));
        while (true) : (index = (index + 1) % @as(u32, @truncate(self.entries.len))) {
            const entry = &self.entries[index];

            if (entry.key) |key| {
                if (key.chars.len == chars.len and key.hash == hash and std.mem.eql(u8, key.chars, chars)) {
                    return entry.key;
                }
            } else {
                // Non tombstone
                if (entry.value.is_nil()) return null;
            }
        }
    }

    pub fn delete(self: *Table, key: *String) bool {
        if (self.count == 0) return false;

        const entry: *Entry = self.find(key);
        if (entry.key == null) return false;

        // Tombstoning
        entry.key = null;
        entry.value = Value.from_boolean(true);

        return true;
    }

    pub fn add_all(self: *Table, from: *Table) void {
        for (from.entries[0..from.entries.len]) |entry| {
            const key = entry.key orelse continue;
            self.upsert(key, entry.value);
        }
    }

    fn adjust_capacity(self: *Table) void {
        const new_cap = if (self.entries.len < 8) 8 else self.entries.len * 2;
        const entries: []Entry = self.allocator.alloc(Entry, new_cap) catch {
            std.process.exit(1);
        };

        for (entries) |*entry| {
            entry.key = null;
            entry.value = Value.from_nil();
        }

        self.count = 0;
        for (self.entries[0..self.entries.len]) |entry| {
            const key = entry.key orelse continue;
            var dest: *Entry = self.find(key);
            dest.key = entry.key;
            dest.value = entry.value;
            self.count += 1;
        }

        self.allocator.free(self.entries);

        self.entries = entries;
    }
};
