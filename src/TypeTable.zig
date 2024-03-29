const std = @import("std");
const cy = @import("cycle");

allocator: std.mem.Allocator,
schemes: Schemes,

const Schemes = std.StringArrayHashMap(Objects);
const Objects = std.StringArrayHashMap(Types);
const Types = std.ArrayList(cy.def.Type);
const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return Self{
        .allocator = allocator,
        .schemes = Schemes.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var scheme_iter = self.schemes.iterator();
    while (scheme_iter.next()) |scheme| {
        var object_iter = scheme.value_ptr.iterator();
        while (object_iter.next()) |object| {
            for (object.value_ptr.items) |t| {
                deinitType(self.allocator, t);
            }
            object.value_ptr.deinit();
            self.allocator.free(object.key_ptr.*);
        }
        scheme.value_ptr.deinit();
        self.allocator.free(scheme.key_ptr.*);
    }
    self.schemes.deinit();
    self.* = undefined;
}

pub fn get(self: *const Self, id: cy.def.TypeId) !cy.def.Type {
    const schemes: []const Objects = self.schemes.values();
    if (id.scheme >= schemes.len) {
        return error.SchemeNotDefined;
    }

    const objects: []const Types = schemes[id.scheme].values();
    if (id.name >= objects.len) {
        return error.ObjectNotDefined;
    }

    const types: []const cy.def.Type = objects[id.name].items;
    if (id.version >= types.len) {
        return error.VersionNotDefined;
    }

    return types[id.version];
}

pub fn update(
    self: *Self,
    scheme_name: []const u8,
    object_name: []const u8,
    view: cy.chan.View(cy.def.Type),
) !cy.def.TypeId {
    const scheme_gop = try self.schemes.getOrPut(scheme_name);
    if (!scheme_gop.found_existing) {
        scheme_gop.key_ptr.* = try self.allocator.dupe(u8, scheme_name);
        scheme_gop.value_ptr.* = Objects.init(self.allocator);
    }
    const objects: *Objects = scheme_gop.value_ptr;

    const object_gop = try objects.getOrPut(object_name);
    if (!object_gop.found_existing) {
        object_gop.key_ptr.* = try self.allocator.dupe(u8, object_name);
        object_gop.value_ptr.* = Types.init(self.allocator);
    }
    const types: *Types = object_gop.value_ptr;

    return idOf(scheme_gop.index, object_gop.index, types.items, view) orelse {
        const t = try initType(self.allocator, view);
        try types.append(t);
        return cy.def.TypeId{
            .scheme = @intCast(scheme_gop.index),
            .name = @intCast(object_gop.index),
            .version = @intCast(types.items.len - 1),
        };
    };
}

fn idOf(scheme: usize, name: usize, types: []const cy.def.Type, view: cy.chan.View(cy.def.Type)) ?cy.def.TypeId {
    for (types, 0..) |t, i| {
        if (typeEql(t, view)) {
            return cy.def.TypeId{
                .scheme = @intCast(scheme),
                .name = @intCast(name),
                .version = @intCast(i),
            };
        }
    }
    return null;
}

fn typeEql(t: cy.def.Type, view: cy.chan.View(cy.def.Type)) bool {
    const tag = view.tag();
    if (t != tag) {
        return false;
    }

    return switch (t) {
        .Void, .Bool, .String, .Any => true,
        .Int => |left| blk: {
            const right = view.value(.Int);
            break :blk left.signedness == right.field(.signedness) and
                left.bits == right.field(.bits);
        },
        .Float => |left| blk: {
            const right = view.value(.Float);
            break :blk left.bits == right.field(.bits);
        },
        .Optional => |left| blk: {
            const right = view.value(.Optional);
            break :blk typeEql(left.child.*, right.field(.child));
        },
        .Array => |left| blk: {
            const right = view.value(.Array);
            break :blk left.len == right.field(.len) and
                typeEql(left.child.*, right.field(.child));
        },
        .List => |left| blk: {
            const right = view.value(.List);
            break :blk typeEql(left.child.*, right.field(.child));
        },
        .Map => |left| blk: {
            const right = view.value(.Map);
            break :blk typeEql(left.key.*, right.field(.key)) and
                typeEql(left.value.*, right.field(.value));
        },
        .Struct => |left| blk: {
            const right = view.value(.Struct);
            const right_fields = right.field(.fields);
            break :blk left.fields.len == right_fields.len() and
                // TODO: should struct equivalence be field-order independent?
                for (left.fields, 0..) |lf, i|
            {
                const rf = right_fields.elem(i);
                if (!std.mem.eql(u8, lf.name, rf.field(.name)) or
                    !typeEql(lf.type, rf.field(.type)))
                {
                    break false;
                }
            } else true;
        },
        .Tuple => |left| blk: {
            const right = view.value(.Tuple);
            const right_fields = right.field(.fields);
            break :blk left.fields.len == right_fields.len() and
                for (left.fields, 0..) |lf, i|
            {
                const rf = right_fields.elem(i);
                if (!typeEql(lf.type, rf.type)) {
                    break false;
                }
            } else true;
        },
        .Union => |left| blk: {
            const right = view.value(.Union);
            const right_fields = right.field(.fields);
            break :blk left.fields.len == right_fields.len() and
                // TODO: should union equivalence be field-order independent?
                for (left.fields, 0..) |lf, i|
            {
                const rf = right_fields.elem(i);
                if (!std.mem.eql(u8, lf.name, rf.field(.name)) or
                    !typeEql(lf.type, rf.field(.type)))
                {
                    break false;
                }
            } else true;
        },
        .Enum => |left| blk: {
            const right = view.value(.Enum);
            const right_fields = right.field(.fields);
            break :blk left.fields.len == right_fields.len() and
                for (left.fields, 0..) |lf, i|
            {
                const rf = right_fields.elem(i);
                if (!std.mem.eql(u8, lf.name, rf.field(.name))) {
                    break false;
                }
            } else true;
        },
        .Ref => |left| blk: {
            const right = view.value(.Ref);
            const rt = right.tag();
            break :blk left == rt and switch (left) {
                .Internal => |li| std.mem.eql(u8, li.name, right.value(.Internal).field(.name)),
                .External => |le| std.mem.eql(u8, le.scheme, right.value(.External).field(.scheme)) and
                    std.mem.eql(u8, le.name, right.value(.External).field(.name)),
            };
        },
    };
}

fn initType(allocator: std.mem.Allocator, view: cy.chan.View(cy.def.Type)) std.mem.Allocator.Error!cy.def.Type {
    const tag = view.tag();
    return switch (tag) {
        .Void => .Void,
        .Bool => .Bool,
        .String => .String,
        .Any => .Any,
        .Int => blk: {
            const value = view.value(.Int);
            break :blk cy.def.Type{
                .Int = cy.def.Type.Int{
                    .signedness = value.field(.signedness),
                    .bits = value.field(.bits),
                },
            };
        },
        .Float => blk: {
            const value = view.value(.Float);
            break :blk cy.def.Type{
                .Float = cy.def.Type.Float{
                    .bits = value.field(.bits),
                },
            };
        },
        .Optional => blk: {
            const value = view.value(.Optional);
            break :blk cy.def.Type{
                .Optional = cy.def.Type.Optional{
                    .child = try allocType(allocator, value.field(.child)),
                },
            };
        },
        .Array => blk: {
            const value = view.value(.Array);
            break :blk cy.def.Type{
                .Array = cy.def.Type.Array{
                    .len = value.field(.len),
                    .child = try allocType(allocator, value.field(.child)),
                },
            };
        },
        .List => blk: {
            const value = view.value(.List);
            break :blk cy.def.Type{
                .List = cy.def.Type.List{
                    .child = try allocType(allocator, value.field(.child)),
                },
            };
        },
        .Map => blk: {
            const value = view.value(.Map);
            break :blk cy.def.Type{
                .Map = cy.def.Type.Map{
                    .key = try allocType(allocator, value.field(.key)),
                    .value = try allocType(allocator, value.field(.value)),
                },
            };
        },
        .Struct => blk: {
            const value = view.value(.Struct);
            const fields_view = value.field(.fields);
            const fields = try allocator.alloc(cy.def.Type.Struct.Field, fields_view.len());
            for (0..fields_view.len()) |i| {
                const field = fields_view.elem(i);
                fields[i] = cy.def.Type.Struct.Field{
                    .name = try allocator.dupe(u8, field.field(.name)),
                    .type = try initType(allocator, field.field(.type)),
                };
            }
            break :blk cy.def.Type{
                .Struct = cy.def.Type.Struct{
                    .fields = fields,
                },
            };
        },
        .Tuple => blk: {
            const value = view.value(.Tuple);
            const fields_view = value.field(.fields);
            const fields = try allocator.alloc(cy.def.Type.Tuple.Field, fields_view.len());
            for (0..fields_view.len()) |i| {
                fields[i] = cy.def.Type.Tuple.Field{
                    .type = try initType(allocator, fields_view.elem(i)),
                };
            }
            break :blk cy.def.Type{
                .Tuple = cy.def.Type.Tuple{
                    .fields = fields,
                },
            };
        },
        .Union => blk: {
            const value = view.value(.Union);
            const fields_view = value.field(.fields);
            const fields = try allocator.alloc(cy.def.Type.Union.Field, fields_view.len());
            for (0..fields_view.len()) |i| {
                const field = fields_view.elem(i);
                fields[i] = cy.def.Type.Union.Field{
                    .name = try allocator.dupe(u8, field.field(.name)),
                    .type = try initType(allocator, field.field(.type)),
                };
            }
            break :blk cy.def.Type{
                .Union = cy.def.Type.Union{
                    .fields = fields,
                },
            };
        },
        .Enum => blk: {
            const value = view.value(.Union);
            const fields_view = value.field(.fields);
            const fields = try allocator.alloc(cy.def.Type.Enum.Field, fields_view.len());
            for (0..fields_view.len()) |i| {
                const field = fields_view.elem(i);
                fields[i] = cy.def.Type.Enum.Field{
                    .name = try allocator.dupe(u8, field.field(.name)),
                };
            }
            break :blk cy.def.Type{
                .Enum = cy.def.Type.Enum{
                    .fields = fields,
                },
            };
        },
        .Ref => blk: {
            const value = view.value(.Ref);
            break :blk cy.def.Type{
                .Ref = switch (value.tag()) {
                    .Internal => cy.def.Type.Ref{
                        .Internal = cy.def.Type.Ref.Internal{
                            .name = try allocator.dupe(u8, value.value(.Internal).field(.name)),
                        },
                    },
                    .External => cy.def.Type.Ref{
                        .External = cy.def.Type.Ref.External{
                            .scheme = try allocator.dupe(u8, value.value(.External).field(.scheme)),
                            .name = try allocator.dupe(u8, value.value(.External).field(.name)),
                        },
                    },
                },
            };
        },
    };
}

fn allocType(allocator: std.mem.Allocator, view: cy.chan.View(cy.def.Type)) !*cy.def.Type {
    const child = try allocator.create(cy.def.Type);
    child.* = try initType(allocator, view);
    return child;
}

fn deinitType(allocator: std.mem.Allocator, t: cy.def.Type) void {
    switch (t) {
        // non-allocating
        .Void, .Bool, .String, .Int, .Float, .Any => {},
        .Optional => |info| {
            deinitType(allocator, info.child.*);
            allocator.destroy(info.child);
        },
        .Array => |info| {
            deinitType(allocator, info.child.*);
            allocator.destroy(info.child);
        },
        .List => |info| {
            deinitType(allocator, info.child.*);
            allocator.destroy(info.child);
        },
        .Map => |info| {
            deinitType(allocator, info.key.*);
            allocator.destroy(info.key);

            deinitType(allocator, info.value.*);
            allocator.destroy(info.value);
        },
        .Struct => |info| {
            for (info.fields) |f| {
                allocator.free(f.name);
                deinitType(allocator, f.type);
            }
            allocator.free(info.fields);
        },
        .Tuple => |info| {
            for (info.fields) |f| {
                deinitType(allocator, f.type);
            }
            allocator.free(info.fields);
        },
        .Union => |info| {
            for (info.fields) |f| {
                allocator.free(f.name);
                deinitType(allocator, f.type);
            }
            allocator.free(info.fields);
        },
        .Enum => |info| {
            for (info.fields) |f| {
                allocator.free(f.name);
            }
            allocator.free(info.fields);
        },
        .Ref => |info| {
            switch (info) {
                .Internal => |ref| {
                    allocator.free(ref.name);
                },
                .External => |ref| {
                    allocator.free(ref.scheme);
                    allocator.free(ref.name);
                },
            }
        },
    }
}

const TestScheme1 = cy.def.Scheme("scheme1", .{
    cy.def.Object("ObjOne", .{
        struct {
            f1: void,
            f2: bool,
            f3: cy.def.String,
            f4: u32,
            f5: f32,
            f6: ?f32,
            f7: [12]u32,
        },
        enum {
            f1,
            f2,
        },
    }),
    cy.def.Object("ObjTwo", .{
        struct {
            cy.def.List(bool),
            cy.def.Map(cy.def.String, u32),
        },
        union(enum) {
            f1: cy.def.This("ObjOne"),
            f2: cy.def.This("ObjTwo"),
        },
    }),
});

const TestScheme2 = cy.def.Scheme("scheme2", .{
    cy.def.Object("ObjOne", .{
        bool,
        struct {
            f1: bool,
            f2: TestScheme1.ref("ObjTwo"),
        },
    }),
});

test {
    const allocator = std.testing.allocator;

    var table = Self.init(allocator);
    defer table.deinit();

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    try cy.chan.write(cy.def.ObjectScheme.from(TestScheme1), &out);

    {
        const view = cy.chan.read(cy.def.ObjectScheme, out.items);
        const scheme_name = view.field(.name);
        const scheme_objects = view.field(.objects);

        const obj_one = scheme_objects.elem(0);

        var index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(0));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 0,
            .name = 0,
            .version = 0,
        }, index);

        index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(1));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 0,
            .name = 0,
            .version = 1,
        }, index);

        index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(0));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 0,
            .name = 0,
            .version = 0,
        }, index);

        index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(1));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 0,
            .name = 0,
            .version = 1,
        }, index);

        const obj_two = scheme_objects.elem(1);

        index = try table.update(scheme_name, obj_two.field(.name), obj_two.field(.versions).elem(0));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 0,
            .name = 1,
            .version = 0,
        }, index);

        index = try table.update(scheme_name, obj_two.field(.name), obj_two.field(.versions).elem(1));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 0,
            .name = 1,
            .version = 1,
        }, index);

        index = try table.update(scheme_name, obj_two.field(.name), obj_two.field(.versions).elem(0));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 0,
            .name = 1,
            .version = 0,
        }, index);

        index = try table.update(scheme_name, obj_two.field(.name), obj_two.field(.versions).elem(1));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 0,
            .name = 1,
            .version = 1,
        }, index);
    }

    out.clearRetainingCapacity();
    try cy.chan.write(cy.def.ObjectScheme.from(TestScheme2), &out);

    {
        const view = cy.chan.read(cy.def.ObjectScheme, out.items);
        const scheme_name = view.field(.name);
        const scheme_objects = view.field(.objects);

        const obj_one = scheme_objects.elem(0);

        var index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(0));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 1,
            .name = 0,
            .version = 0,
        }, index);

        index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(1));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 1,
            .name = 0,
            .version = 1,
        }, index);

        index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(0));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 1,
            .name = 0,
            .version = 0,
        }, index);

        index = try table.update(scheme_name, obj_one.field(.name), obj_one.field(.versions).elem(1));
        try std.testing.expectEqualDeep(cy.def.TypeId{
            .scheme = 1,
            .name = 0,
            .version = 1,
        }, index);
    }
}
