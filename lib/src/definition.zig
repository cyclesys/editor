const std = @import("std");
const define = @import("define.zig");

pub const CommandScheme = struct {
    name: []const u8,
    commands: []const Command,
    dependencies: []const ObjectScheme,

    pub const Command = struct {
        name: []const u8,
        field_type: CommandFieldType,

        const CommandFieldType = union(enum) {
            Ref: Ref,
            Array: Array,
            List: *const CommandFieldType,
            Struct: []const StructField,
            Union: []const UnionField,

            pub const StructField = struct {
                name: []const u8,
                field_type: CommandFieldType,
            };

            pub const UnionField = struct {
                name: []const u8,
                field_type: ?CommandFieldType,
            };

            pub const Array = struct {
                size: usize,
                element_type: *const CommandFieldType,
            };

            fn from(comptime Type: type) CommandFieldType {
                switch (@typeInfo(Type)) {
                    .Struct => |info| {
                        if (!@hasDecl(Type, "def_kind")) {
                            const result = comptime blk: {
                                var fields: [info.fields.len]StructField = undefined;
                                for (info.fields, 0..) |field, i| {
                                    fields[i] = .{
                                        .name = field.name,
                                        .field_type = CommandFieldType.from(field.type),
                                    };
                                }
                                break :blk CommandFieldType{
                                    .Struct = fields[0..],
                                };
                            };
                            return result;
                        }

                        switch (Type.def_kind) {
                            .array => {
                                const result = comptime blk: {
                                    const element_type = CommandFieldType.from(Type.element_type);
                                    break :blk CommandFieldType{
                                        .Array = Array{
                                            .size = Type.array_size,
                                            .element_type = &element_type,
                                        },
                                    };
                                };
                                return result;
                            },
                            .list => {
                                const result = comptime blk: {
                                    const element_type = CommandFieldType.from(Type.element_type);
                                    break :blk CommandFieldType{
                                        .List = &element_type,
                                    };
                                };
                                return result;
                            },
                            .ref => return CommandFieldType{
                                .Ref = Ref.from(Type),
                            },
                            else => @compileError("unexpected command field type"),
                        }
                    },
                    .Union => |info| {
                        const result = comptime blk: {
                            var fields: [info.fields.len]UnionField = undefined;
                            for (info.fields, 0..) |field, i| {
                                fields[i] = .{
                                    .name = field.name,
                                    .field_type = if (field.type == void) null else CommandFieldType.from(field.type),
                                };
                            }
                            break :blk CommandFieldType{
                                .Union = fields[0..],
                            };
                        };
                        return result;
                    },
                    else => @compileError("unexpected command field type"),
                }
            }
        };

        fn from(comptime Type: type) Command {
            return Command{
                .name = Type.type_name,
                .field_type = CommandFieldType.from(Type.field_type),
            };
        }
    };

    pub fn from(comptime SchemeFn: define.SchemeFn) CommandScheme {
        const Scheme = SchemeFn(define.This);
        if (Scheme.scheme_kind != .command) {
            @compileError("scheme is not a command scheme");
        }

        const result = comptime blk: {
            var commands: [Scheme.scheme_types.len]Command = undefined;
            for (Scheme.scheme_types, 0..) |Type, i| {
                commands[i] = Command.from(Type);
            }

            var dependency_types: []const type = &[_]type{};
            for (Scheme.scheme_types) |Type| {
                var deps: []const type = &[_]type{};
                for (ObjectScheme.types(Type.field_type)) |Dep| {
                    deps = ObjectScheme.mergeTypes(deps, &[_]type{Dep});
                    deps = ObjectScheme.mergeTypes(deps, ObjectScheme.dependencies(Dep));
                }
                dependency_types = ObjectScheme.mergeTypes(dependency_types, deps);
            }

            var dependencies: [dependency_types.len]ObjectScheme = undefined;
            for (dependency_types, 0..) |Dep, i| {
                dependencies[i] = ObjectScheme.from(Dep);
            }

            break :blk CommandScheme{
                .name = Scheme.scheme_name,
                .commands = commands[0..],
                .dependencies = ObjectScheme.mergeSchemes(dependencies[0..]),
            };
        };

        return result;
    }
};

pub const FunctionScheme = struct {
    name: []const u8,
    functions: []const Function,
    dependencies: []const ObjectScheme,

    pub const Function = struct {
        name: []const u8,
        versions: []const Version,

        pub const Version = struct {
            params: []const FieldType,
            return_type: FieldType,

            fn from(comptime Type: type) Version {
                const info = @typeInfo(Type).Fn;

                const result = comptime blk: {
                    var params: [info.params.len]FieldType = undefined;
                    for (info.params, 0..) |param, i| {
                        params[i] = FieldType.from(param.type.?).?;
                    }

                    const return_type = FieldType.from(info.return_type.?).?;

                    break :blk Version{
                        .params = params[0..],
                        .return_type = return_type,
                    };
                };

                return result;
            }
        };

        fn from(comptime Type: type) Function {
            const result = comptime blk: {
                var versions: [Type.type_versions.len]Version = undefined;
                for (Type.type_versions, 0..) |Ver, i| {
                    versions[i] = Version.from(Ver);
                }
                break :blk Function{
                    .name = Type.type_name,
                    .versions = versions[0..],
                };
            };
            return result;
        }
    };

    pub fn from(comptime SchemeFn: define.SchemeFn) FunctionScheme {
        const Scheme = SchemeFn(define.This);
        if (Scheme.scheme_kind != .function) {
            @compileError("scheme is not a function scheme");
        }

        const result = comptime blk: {
            var functions: [Scheme.scheme_types.len]Function = undefined;
            for (Scheme.scheme_types, 0..) |Type, i| {
                functions[i] = Function.from(Type);
            }

            var dependency_types: []const type = &[_]type{};
            for (Scheme.scheme_types) |Type| {
                for (Type.type_versions) |Ver| {
                    var deps: []const type = &[_]type{};
                    for (ObjectScheme.types(Ver)) |Dep| {
                        deps = ObjectScheme.mergeTypes(deps, &[_]type{Dep});
                        deps = ObjectScheme.mergeTypes(deps, ObjectScheme.dependencies(Dep));
                    }
                    dependency_types = ObjectScheme.mergeTypes(dependency_types, deps);
                }
            }

            var dependencies: [dependency_types.len]ObjectScheme = undefined;
            for (dependency_types, 0..) |Dep, i| {
                dependencies[i] = ObjectScheme.from(Dep);
            }

            break :blk FunctionScheme{
                .name = Scheme.scheme_name,
                .functions = functions[0..],
                .dependencies = ObjectScheme.mergeSchemes(dependencies[0..]),
            };
        };

        return result;
    }
};

pub const ObjectScheme = struct {
    name: []const u8,
    objects: []const Object,

    pub const Object = struct {
        name: []const u8,
        versions: []const FieldType,

        fn merge(comptime left: Object, comptime right: Object) Object {
            if (left.versions.len > right.versions.len) {
                return left;
            } else if (right.versions.len > left.versions.len) {
                return right;
            } else {
                @compileError("unexpected Object.merge state");
            }
        }

        fn eql(comptime left: Object, comptime right: Object) bool {
            const matching_len = if (left.versions.len > right.versions.len)
                right.versions.len
            else
                left.versions.len;

            for (0..matching_len) |i| {
                if (!FieldType.eql(left.versions[i], right.versions[i])) {
                    @compileError("encountered differing field types for object " ++ left.name ++
                        "at version " ++ &[_]u8{i + 1});
                }
            }

            return left.versions.len == right.versions.len;
        }

        fn from(comptime Type: type) Object {
            const result = comptime blk: {
                var versions: [Type.type_versions.len]FieldType = undefined;
                for (Type.type_versions, 0..) |Ver, i| {
                    versions[i] = FieldType.from(Ver).?;
                }
                break :blk Object{
                    .name = Type.type_name,
                    .versions = versions[0..],
                };
            };
            return result;
        }
    };

    fn types(comptime Type: type) []const type {
        comptime {
            switch (@typeInfo(Type)) {
                .Void, .Bool, .Int, .Float, .Enum => {
                    return &[_]type{};
                },
                .Optional => |info| {
                    return ObjectScheme.types(info.child);
                },
                .Struct => |info| {
                    if (@hasDecl(Type, "def_kind")) {
                        switch (Type.def_kind) {
                            .this, .string, .ignore => {
                                return &[_]type{};
                            },
                            .ref => {
                                return &[_]type{Type.type_scheme};
                            },
                            .array, .list => {
                                return ObjectScheme.types(Type.element_type);
                            },
                            .map => {
                                return ObjectScheme.mergeTypes(
                                    ObjectScheme.types(Type.key_type),
                                    ObjectScheme.types(Type.value_type),
                                );
                            },
                            else => @compileError("unexpected field type"),
                        }
                    } else {
                        var result: []const type = &[_]type{};
                        for (info.fields) |field| {
                            result = ObjectScheme.mergeTypes(result, ObjectScheme.types(field.type));
                        }
                        return result;
                    }
                },
                .Fn => |info| {
                    var result: []const type = &[_]type{};
                    for (info.params) |param| {
                        result = ObjectScheme.mergeTypes(result, ObjectScheme.types(param.type.?));
                    }
                    result = ObjectScheme.mergeTypes(result, ObjectScheme.types(info.return_type.?));
                    return result;
                },
                else => @compileError("unexpected field type"),
            }
        }
    }

    pub fn dependencies(comptime Scheme: type) []const type {
        comptime {
            var result: []const type = &[_]type{};
            for (Scheme.scheme_types) |Type| {
                for (Type.type_versions) |Ver| {
                    var deps: []const type = &[_]type{};
                    for (ObjectScheme.types(Ver)) |Dep| {
                        if (Dep == Scheme)
                            continue;

                        deps = ObjectScheme.mergeTypes(deps, &[_]type{Dep});
                        deps = ObjectScheme.mergeTypes(deps, ObjectScheme.dependencies(Dep));
                    }
                    result = ObjectScheme.mergeTypes(result, deps);
                }
            }
            return result;
        }
    }

    pub fn mergeTypes(comptime left: []const type, comptime right: []const type) []const type {
        comptime {
            var result = left;
            outer: for (right) |Right| {
                for (left) |Left| {
                    if (Left == Right)
                        continue :outer;
                }
                result = result ++ &[_]type{Right};
            }
            return result;
        }
    }

    pub fn mergeSchemes(comptime deps: []const ObjectScheme) []const ObjectScheme {
        const result = comptime blk: {
            var schemes: [deps.len]ObjectScheme = undefined;
            var len = 0;
            outer: for (deps) |new| {
                for (0..len) |i| {
                    if (std.mem.eql(u8, schemes[i].name, new.name)) {
                        schemes[i] = ObjectScheme.merge(schemes[i], new);
                        continue :outer;
                    }
                }

                schemes[len] = new;
                len += 1;
            }
            break :blk schemes[0..len];
        };
        return result;
    }

    fn merge(comptime left: ObjectScheme, comptime right: ObjectScheme) ObjectScheme {
        const result = comptime blk: {
            var objects: [left.objects.len + right.objects.len]Object = undefined;
            for (left.objects, 0..) |obj, i| {
                objects[i] = obj;
            }
            var len = left.objects.len;

            outer: for (right.objects) |right_obj| {
                for (left.objects, 0..) |left_obj, i| {
                    if (std.mem.eql(u8, left_obj.name, right_obj.name)) {
                        if (!Object.eql(left_obj, right_obj)) {
                            objects[i] = Object.merge(left_obj, right_obj);
                        }
                        continue :outer;
                    }
                }
                objects[len] = right_obj;
                len += 1;
            }
            break :blk ObjectScheme{
                .name = left.name,
                .objects = objects[0..len],
            };
        };
        return result;
    }

    pub fn from(comptime Scheme: type) ObjectScheme {
        if (Scheme.scheme_kind != .object) {
            @compileError("scheme is not an object scheme");
        }

        const result = comptime blk: {
            var objects: [Scheme.scheme_types.len]Object = undefined;
            for (Scheme.scheme_types, 0..) |Type, i| {
                objects[i] = Object.from(Type);
            }
            break :blk ObjectScheme{
                .name = Scheme.scheme_name,
                .objects = objects[0..],
            };
        };

        return result;
    }
};

pub const FieldType = union(enum) {
    Void: void,
    Bool: void,
    Int: std.builtin.Type.Int,
    Float: std.builtin.Type.Float,
    Optional: *const FieldType,
    Ref: Ref,
    Array: Array,
    List: *const FieldType,
    Map: Map,
    String: void,
    Struct: []const StructField,
    Tuple: []const FieldType,
    Union: []const UnionField,
    Enum: []const EnumField,

    pub const Array = struct {
        len: usize,
        child: *const FieldType,
    };

    pub const Map = struct {
        key: *const FieldType,
        value: *const FieldType,
    };

    pub const StructField = struct {
        name: []const u8,
        type: FieldType,
    };

    pub const UnionField = struct {
        name: []const u8,
        type: FieldType,
    };

    pub const EnumField = struct {
        name: []const u8,
    };

    fn eql(l: ?FieldType, r: ?FieldType) bool {
        if (l == null) {
            return r == null;
        } else if (r == null) {
            return false;
        }

        const left = l.?;
        const right = r.?;

        switch (left) {
            .Void => {
                return right == .Void;
            },
            .Bool => {
                return right == .Bool;
            },
            .Int => {
                return right == .Int and
                    left.Int.signedness == right.Int.signedness and
                    left.Int.bits == right.Int.bits;
            },
            .Float => {
                return right == .Float and
                    left.Float.bits == right.Float.bits;
            },
            .Optional => {
                return right == .Optional and
                    FieldType.eql(left.Optional.*, right.Optional.*);
            },
            .Ref => {
                return right == .Ref and
                    Ref.eql(left.Ref, right.Ref);
            },
            .Array => {
                return right == .Array and
                    left.Array.len == right.Array.len and
                    FieldType.eql(left.Array.child.*, right.Array.child.*);
            },
            .List => {
                return right == .List and
                    FieldType.eql(left.List.*, right.List.*);
            },
            .Map => {
                return right == .Map and
                    FieldType.eql(left.Map.key.*, right.Map.key.*) and
                    FieldType.eql(left.Map.value.*, right.Map.value.*);
            },
            .String => {
                return right == .String;
            },
            .Struct => {
                if (right != .Struct or left.Struct.len != right.Struct.len) {
                    return false;
                }

                for (left.Struct, right.Struct) |left_field, right_field| {
                    if (!std.mem.eql(u8, left_field.name, right_field.name) or
                        !FieldType.eql(left_field.type, right_field.type))
                    {
                        return false;
                    }
                }

                return true;
            },
            .Tuple => {
                if (right != .Tuple or left.Tuple.len != right.Tuple.len) {
                    return false;
                }

                for (left.Tuple, right.Tuple) |left_type, right_type| {
                    if (!FieldType.eql(left_type, right_type)) {
                        return false;
                    }
                }

                return true;
            },
            .Union => {
                if (right != .Union or
                    left.Union.len != right.Union.len)
                {
                    return false;
                }

                for (left.Union, right.Union) |left_field, right_field| {
                    if (!std.mem.eql(u8, left_field.name, right_field.name) or
                        !FieldType.eql(left_field.type, right_field.type))
                    {
                        return false;
                    }
                }

                return true;
            },
            .Enum => {
                if (right != .Enum or
                    left.Enum.len != right.Enum.len)
                {
                    return false;
                }

                for (left.Enum, right.Enum) |left_field, right_field| {
                    if (!std.mem.eql(u8, left_field.name, right_field.name)) {
                        return false;
                    }
                }

                return true;
            },
        }
    }

    pub fn from(comptime Type: type) ?FieldType {
        switch (@typeInfo(Type)) {
            .Void => {
                return FieldType.Void;
            },
            .Bool => {
                return FieldType.Bool;
            },
            .Int => |info| {
                return FieldType{
                    .Int = info,
                };
            },
            .Float => |info| {
                return FieldType{
                    .Float = info,
                };
            },
            .Optional => |info| {
                const result = comptime blk: {
                    const child = FieldType.from(info.child).?;
                    break :blk FieldType{
                        .Optional = &child,
                    };
                };
                return result;
            },
            .Struct => |info| {
                if (@hasDecl(Type, "def_kind"))
                    switch (Type.def_kind) {
                        .this => {
                            return FieldType{
                                .Ref = Ref{
                                    .scheme_name = null,
                                    .type_name = Type.type_name,
                                },
                            };
                        },
                        .ref => {
                            return FieldType{
                                .Ref = Ref.from(Type),
                            };
                        },
                        .array => {
                            const result = comptime blk: {
                                const child = FieldType.from(Type.element_type).?;
                                break :blk FieldType{
                                    .Array = Array{
                                        .len = Type.array_size,
                                        .child = &child,
                                    },
                                };
                            };
                            return result;
                        },
                        .list => {
                            const result = comptime blk: {
                                const child = FieldType.from(Type.element_type).?;
                                break :blk FieldType{
                                    .List = &child,
                                };
                            };
                            return result;
                        },
                        .map => {
                            const result = comptime blk: {
                                const key = FieldType.from(Type.key_type).?;
                                const value = FieldType.from(Type.value_type).?;
                                break :blk FieldType{
                                    .Map = Map{
                                        .key = &key,
                                        .value = &value,
                                    },
                                };
                            };
                            return result;
                        },
                        .string => {
                            return FieldType.String;
                        },
                        .ignore => {
                            return null;
                        },
                        else => @compileError("unexpected def_kind"),
                    }
                else {
                    if (info.is_tuple) {
                        const result = comptime blk: {
                            var field_types: [info.fields.len]FieldType = undefined;
                            var len = 0;
                            for (info.fields) |field| {
                                if (FieldType.from(field.type)) |field_type| {
                                    field_types[len] = field_type;
                                    len += 1;
                                }
                            }
                            break :blk FieldType{
                                .Tuple = field_types[0..len],
                            };
                        };
                        return result;
                    } else {
                        const result = comptime blk: {
                            var fields: [info.fields.len]StructField = undefined;
                            var len = 0;
                            for (info.fields) |field| {
                                if (FieldType.from(field.type)) |field_type| {
                                    fields[len] = StructField{
                                        .name = field.name,
                                        .type = field_type,
                                    };
                                    len += 1;
                                }
                            }
                            break :blk FieldType{
                                .Struct = fields[0..len],
                            };
                        };
                        return result;
                    }
                }
            },
            .Union => |info| {
                const result = comptime blk: {
                    if (info.tag_type == null) {
                        @compileError("union field type must have tag type");
                    }

                    var fields: [info.fields.len]UnionField = undefined;
                    var len = 0;
                    for (info.fields) |field| {
                        if (FieldType.from(field.type)) |field_type| {
                            fields[len] = UnionField{
                                .name = field.name,
                                .type = field_type,
                            };
                            len += 1;
                        }
                    }
                    break :blk FieldType{
                        .Union = fields[0..len],
                    };
                };
                return result;
            },
            .Enum => |info| {
                const result = comptime blk: {
                    var fields: [info.fields.len]EnumField = undefined;
                    for (info.fields, 0..) |field, i| {
                        fields[i] = EnumField{
                            .name = field.name,
                        };
                    }

                    break :blk FieldType{
                        .Enum = &fields,
                    };
                };
                return result;
            },
            else => @compileError("unexpected field type"),
        }
    }
};

pub const Ref = struct {
    scheme_name: ?[]const u8,
    type_name: []const u8,

    fn eql(left: Ref, right: Ref) bool {
        if (left.scheme_name != null) {
            if (right.scheme_name == null or !std.mem.eql(u8, left.scheme_name.?, right.scheme_name.?)) {
                return false;
            }
        } else if (right.scheme_name != null) {
            return false;
        }

        return std.mem.eql(u8, left.type_name, right.type_name);
    }

    fn from(comptime Type: type) Ref {
        return Ref{
            .scheme_name = Type.type_scheme.scheme_name,
            .type_name = Type.type_def.type_name,
        };
    }
};

// NOTE: the tests don't use `testing.expectEqualDeep` due to `FieldType` being a recursive type,
// which causes a compilation error when zig tries to infer the error type. Instead they use
// hand-writter 'expect' functions, defined at the very bottom.

test "void field type" {
    try expectFieldTypeEql(FieldType.Void, FieldType.from(void));
}

test "bool field type" {
    try expectFieldTypeEql(FieldType.Bool, FieldType.from(bool));
}

test "int field type" {
    try expectFieldTypeEql(
        FieldType{
            .Int = .{
                .signedness = .signed,
                .bits = 8,
            },
        },
        FieldType.from(i8),
    );

    try expectFieldTypeEql(
        FieldType{
            .Int = .{
                .signedness = .unsigned,
                .bits = 8,
            },
        },
        FieldType.from(u8),
    );
}

test "float field type" {
    try expectFieldTypeEql(FieldType{ .Float = .{ .bits = 16 } }, FieldType.from(f16));
}

test "optional field type" {
    try expectFieldTypeEql(
        FieldType{
            .Optional = &FieldType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 8,
                },
            },
        },
        FieldType.from(?u8),
    );
}

test "ref field type" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{
            u8,
        }),
    });
    try expectFieldTypeEql(
        FieldType{
            .Ref = Ref{
                .scheme_name = "objs",
                .type_name = "Obj",
            },
        },
        FieldType.from(Objs("Obj")),
    );
}

test "array field type" {
    try expectFieldTypeEql(
        FieldType{
            .Array = .{
                .len = 32,
                .child = &FieldType{
                    .Bool = undefined,
                },
            },
        },
        FieldType.from(define.Array(32, bool)),
    );
}

test "list field type" {
    try expectFieldTypeEql(
        FieldType{
            .List = &FieldType{
                .Bool = undefined,
            },
        },
        FieldType.from(define.List(bool)),
    );
}

test "map field type" {
    try expectFieldTypeEql(
        FieldType{
            .Map = .{
                .key = &FieldType{ .Bool = undefined },
                .value = &FieldType{ .Bool = undefined },
            },
        },
        FieldType.from(define.Map(bool, bool)),
    );
}

test "string field type" {
    try expectFieldTypeEql(
        FieldType{
            .String = undefined,
        },
        FieldType.from(define.String),
    );
}

test "struct field type" {
    const expected = .{
        FieldType.StructField{
            .name = "one",
            .type = FieldType.Bool,
        },
        FieldType.StructField{
            .name = "two",
            .type = FieldType.String,
        },
    };
    try expectFieldTypeEql(
        FieldType{
            .Struct = &expected,
        },
        FieldType.from(struct {
            one: bool,
            two: define.String,
        }),
    );
}

test "tuple field type" {
    const expected = .{
        FieldType.Bool,
        FieldType.String,
    };

    try expectFieldTypeEql(
        FieldType{
            .Tuple = &expected,
        },
        FieldType.from(struct {
            bool,
            define.String,
        }),
    );
}

test "union field type" {
    const expected_fields = .{
        FieldType.UnionField{
            .name = "One",
            .type = FieldType.Bool,
        },
        FieldType.UnionField{
            .name = "Two",
            .type = FieldType.String,
        },
    };

    try expectFieldTypeEql(
        FieldType{
            .Union = &expected_fields,
        },
        FieldType.from(union(enum) {
            One: bool,
            Two: define.String,
        }),
    );
}

test "enum field type" {
    try expectFieldTypeEql(
        FieldType{
            .Enum = &.{
                FieldType.EnumField{
                    .name = "One",
                },
                FieldType.EnumField{
                    .name = "Two",
                },
            },
        },
        FieldType.from(enum {
            One,
            Two,
        }),
    );
}

test "object" {
    const Obj = define.Object("Obj", .{
        bool,
        define.String,
    });

    try expectObjectEql(
        .{
            .name = "Obj",
            .versions = &.{
                FieldType.Bool,
                FieldType.String,
            },
        },
        ObjectScheme.Object.from(Obj),
    );
}

test "object scheme" {
    const Objs = define.Scheme("scheme/objs", .{
        define.Object("One", .{
            bool,
        }),
    });

    try expectObjectSchemeEql(
        ObjectScheme{
            .name = "scheme/objs",
            .objects = &.{
                ObjectScheme.Object{
                    .name = "One",
                    .versions = &.{
                        FieldType.Bool,
                    },
                },
            },
        },
        ObjectScheme.from(Objs(define.This)),
    );
}

test "object scheme dependencies" {
    const Dep1 = define.Scheme("scheme/dep1", .{
        define.Object("Obj", .{
            bool,
        }),
    });

    const Dep2 = define.Scheme("scheme/dep2", .{
        define.Object("Obj", .{
            struct {
                obj1: Dep1("Obj"),
            },
        }),
    });

    const Objs = define.Scheme("scheme/objs", .{
        define.Object("One", .{
            struct {
                obj1: Dep1("Obj"),
                obj2: Dep2("Obj"),
            },
        }),
    });

    const expected: []const ObjectScheme = &.{
        ObjectScheme{
            .name = "scheme/dep1",
            .objects = &.{
                ObjectScheme.Object{
                    .name = "Obj",
                    .versions = &.{
                        FieldType.Bool,
                    },
                },
            },
        },
        ObjectScheme{
            .name = "scheme/dep2",
            .objects = &.{
                ObjectScheme.Object{
                    .name = "Obj",
                    .versions = &.{
                        FieldType{
                            .Struct = &.{
                                FieldType.StructField{
                                    .name = "obj1",
                                    .type = FieldType{
                                        .Ref = Ref{
                                            .scheme_name = "scheme/dep1",
                                            .type_name = "Obj",
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    };

    const deps = ObjectScheme.dependencies(Objs(define.This));
    inline for (deps, 0..) |dep, i| {
        const actual = ObjectScheme.from(dep);
        try expectObjectSchemeEql(expected[i], actual);
    }
}

test "object scheme merge" {
    const DepOld = define.Scheme("scheme/dep", .{
        define.Object("One", .{
            bool,
        }),
    });

    const DepNew = define.Scheme("scheme/dep", .{
        define.Object("One", .{
            bool,
            define.String,
        }),
        define.Object("Two", .{
            define.String,
        }),
    });

    const Dep2 = define.Scheme("scheme/dep2", .{
        define.Object("Obj", .{
            DepOld("One"),
        }),
    });

    const Objs = define.Scheme("scheme/objs", .{
        define.Object("Obj", .{
            struct {
                one: DepNew("One"),
                two: DepNew("Two"),
                obj: Dep2("Obj"),
            },
        }),
    });

    const expected: []const ObjectScheme = &.{
        ObjectScheme{
            .name = "scheme/dep",
            .objects = &.{
                ObjectScheme.Object{
                    .name = "One",
                    .versions = &.{
                        FieldType.Bool,
                        FieldType.String,
                    },
                },
                ObjectScheme.Object{
                    .name = "Two",
                    .versions = &.{
                        FieldType
                            .String,
                    },
                },
            },
        },
        ObjectScheme{
            .name = "scheme/dep2",
            .objects = &.{
                ObjectScheme.Object{
                    .name = "Obj",
                    .versions = &.{
                        FieldType{
                            .Ref = Ref{
                                .scheme_name = "scheme/dep",
                                .type_name = "One",
                            },
                        },
                    },
                },
            },
        },
    };

    const actual = comptime blk: {
        var schemes: []const ObjectScheme = &[_]ObjectScheme{};
        for (ObjectScheme.dependencies(Objs(define.This))) |dep| {
            schemes = schemes ++ &[_]ObjectScheme{ObjectScheme.from(dep)};
        }
        break :blk ObjectScheme.mergeSchemes(schemes);
    };

    inline for (expected, actual) |exp, act| {
        try expectObjectSchemeEql(exp, act);
    }
}

test "function version" {
    try expectFunctionVersionEql(
        .{
            .params = &.{
                FieldType.Bool,
            },
            .return_type = FieldType.Bool,
        },
        FunctionScheme.Function.Version.from(fn (bool) bool),
    );
}

test "function" {
    const Fn = define.Function("Fn", .{
        fn (bool) define.String,
    });

    try expectFunctionEql(
        .{
            .name = "Fn",
            .versions = &.{
                .{
                    .params = &.{
                        FieldType.Bool,
                    },
                    .return_type = FieldType.String,
                },
            },
        },
        FunctionScheme.Function.from(Fn),
    );
}

test "function scheme" {
    const Dep1Old = define.Scheme("dep1", .{
        define.Object("Obj", .{
            bool,
        }),
    });

    const Dep1New = define.Scheme("dep1", .{
        define.Object("Obj", .{
            bool,
            define.String,
        }),
    });

    const Dep2 = define.Scheme("dep2", .{
        define.Object("Obj", .{
            Dep1Old("Obj"),
        }),
    });

    const Dep3 = define.Scheme("dep3", .{
        define.Object("Obj", .{
            struct {
                obj1: Dep1New("Obj"),
                obj2: Dep2("Obj"),
            },
        }),
    });

    const Fns = define.Scheme("Fns", .{
        define.Function("Fn", .{
            fn (Dep2("Obj")) Dep3("Obj"),
        }),
    });

    try expectFunctionSchemeEql(
        .{
            .name = "Fns",
            .functions = &.{
                .{
                    .name = "Fn",
                    .versions = &.{
                        .{
                            .params = &.{
                                .{
                                    .Ref = .{
                                        .scheme_name = "dep2",
                                        .type_name = "Obj",
                                    },
                                },
                            },
                            .return_type = .{
                                .Ref = .{
                                    .scheme_name = "dep3",
                                    .type_name = "Obj",
                                },
                            },
                        },
                    },
                },
            },
            .dependencies = &.{
                .{
                    .name = "dep2",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                FieldType{
                                    .Ref = .{
                                        .scheme_name = "dep1",
                                        .type_name = "Obj",
                                    },
                                },
                            },
                        },
                    },
                },
                .{
                    .name = "dep1",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                FieldType.Bool,
                                FieldType.String,
                            },
                        },
                    },
                },
                .{
                    .name = "dep3",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                FieldType{
                                    .Struct = &.{
                                        .{
                                            .name = "obj1",
                                            .type = FieldType{
                                                .Ref = .{
                                                    .scheme_name = "dep1",
                                                    .type_name = "Obj",
                                                },
                                            },
                                        },
                                        .{
                                            .name = "obj2",
                                            .type = FieldType{
                                                .Ref = .{
                                                    .scheme_name = "dep2",
                                                    .type_name = "Obj",
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
        FunctionScheme.from(Fns),
    );
}

test "ref command field type" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{u8}),
    });
    try expectCommandFieldTypeEql(
        .{
            .Ref = Ref{
                .scheme_name = "objs",
                .type_name = "Obj",
            },
        },
        CommandScheme.Command.CommandFieldType.from(Objs("Obj")),
    );
}

test "array command field type" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{u8}),
    });

    try expectCommandFieldTypeEql(
        .{
            .Array = .{
                .size = 32,
                .element_type = &.{
                    .Ref = .{
                        .scheme_name = "objs",
                        .type_name = "Obj",
                    },
                },
            },
        },
        CommandScheme.Command.CommandFieldType.from(define.Array(32, Objs("Obj"))),
    );
}

test "list command field type" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{u8}),
    });

    try expectCommandFieldTypeEql(
        .{
            .List = &.{
                .Ref = .{
                    .scheme_name = "objs",
                    .type_name = "Obj",
                },
            },
        },
        CommandScheme.Command.CommandFieldType.from(define.List(Objs("Obj"))),
    );
}

test "struct command field type" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{u8}),
    });

    try expectCommandFieldTypeEql(
        .{
            .Struct = &.{
                .{
                    .name = "one",
                    .field_type = .{
                        .Ref = .{
                            .scheme_name = "objs",
                            .type_name = "Obj",
                        },
                    },
                },
            },
        },
        CommandScheme.Command.CommandFieldType.from(struct {
            one: Objs("Obj"),
        }),
    );
}

test "union command field type" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{u8}),
    });

    try expectCommandFieldTypeEql(
        .{
            .Union = &.{
                .{
                    .name = "One",
                    .field_type = .{
                        .Ref = .{
                            .scheme_name = "objs",
                            .type_name = "Obj",
                        },
                    },
                },
                .{
                    .name = "Two",
                    .field_type = null,
                },
            },
        },
        CommandScheme.Command.CommandFieldType.from(union(enum) {
            One: Objs("Obj"),
            Two,
        }),
    );
}

test "command" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{
            bool,
        }),
    });
    const Cmd = define.Command("Cmd", struct {
        obj: Objs("Obj"),
    });

    try expectCommandEql(
        .{
            .name = "Cmd",
            .field_type = .{
                .Struct = &.{
                    .{
                        .name = "obj",
                        .field_type = .{
                            .Ref = .{
                                .scheme_name = "objs",
                                .type_name = "Obj",
                            },
                        },
                    },
                },
            },
        },
        CommandScheme.Command.from(Cmd),
    );
}

test "command scheme" {
    const Dep1Old = define.Scheme("dep1", .{
        define.Object("Obj", .{
            bool,
        }),
    });

    const Dep1New = define.Scheme("dep1", .{
        define.Object("Obj", .{
            bool,
            define.String,
        }),
    });

    const Dep2 = define.Scheme("dep2", .{
        define.Object("Obj", .{
            Dep1Old("Obj"),
        }),
    });

    const Dep3 = define.Scheme("dep3", .{
        define.Object("Obj", .{
            struct {
                obj1: Dep1New("Obj"),
                obj2: Dep2("Obj"),
            },
        }),
    });

    const Cmds = define.Scheme("cmds", .{
        define.Command("Cmd", struct {
            obj2: Dep2("Obj"),
            obj3: Dep3("Obj"),
        }),
    });

    try expectCommandSchemeEql(
        .{
            .name = "cmds",
            .commands = &.{
                .{
                    .name = "Cmd",
                    .field_type = .{
                        .Struct = &.{
                            .{
                                .name = "obj2",
                                .field_type = .{
                                    .Ref = .{
                                        .scheme_name = "dep2",
                                        .type_name = "Obj",
                                    },
                                },
                            },
                            .{
                                .name = "obj3",
                                .field_type = .{
                                    .Ref = .{
                                        .scheme_name = "dep3",
                                        .type_name = "Obj",
                                    },
                                },
                            },
                        },
                    },
                },
            },
            .dependencies = &.{
                .{
                    .name = "dep2",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                FieldType{
                                    .Ref = .{
                                        .scheme_name = "dep1",
                                        .type_name = "Obj",
                                    },
                                },
                            },
                        },
                    },
                },
                .{
                    .name = "dep1",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                FieldType.Bool,
                                FieldType.String,
                            },
                        },
                    },
                },
                .{
                    .name = "dep3",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                FieldType{
                                    .Struct = &.{
                                        .{
                                            .name = "obj1",
                                            .type = FieldType{
                                                .Ref = .{
                                                    .scheme_name = "dep1",
                                                    .type_name = "Obj",
                                                },
                                            },
                                        },
                                        .{
                                            .name = "obj2",
                                            .type = FieldType{
                                                .Ref = .{
                                                    .scheme_name = "dep2",
                                                    .type_name = "Obj",
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
        CommandScheme.from(Cmds),
    );
}

fn expectCommandSchemeEql(expected: CommandScheme, actual: CommandScheme) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or
        expected.commands.len != actual.commands.len or
        expected.dependencies.len != actual.dependencies.len)
    {
        return error.TestExpectedEqual;
    }

    for (expected.commands, actual.commands) |exp, act| {
        try expectCommandEql(exp, act);
    }

    for (expected.dependencies, actual.dependencies) |exp, act| {
        try expectObjectSchemeEql(exp, act);
    }
}

fn expectCommandEql(expected: CommandScheme.Command, actual: CommandScheme.Command) !void {
    if (!std.mem.eql(u8, expected.name, actual.name)) {
        return error.TestExpectedEqual;
    }

    try expectCommandFieldTypeEql(expected.field_type, actual.field_type);
}

fn expectCommandFieldTypeEql(expected_opt: ?CommandScheme.Command.CommandFieldType, actual_opt: ?CommandScheme.Command.CommandFieldType) !void {
    if (expected_opt == null) {
        if (actual_opt != null) {
            return error.TestExpectedEqual;
        }
        return;
    } else if (actual_opt == null) {
        return error.TestExpectedEqual;
    }

    const expected = expected_opt.?;
    const actual = actual_opt.?;

    switch (expected) {
        .Struct => {
            if (actual != .Struct or expected.Struct.len != actual.Struct.len) {
                return error.TestExpectedEqual;
            }

            for (expected.Struct, actual.Struct) |exp, act| {
                if (!std.mem.eql(u8, exp.name, act.name)) {
                    return error.TestExpectedEqual;
                }

                try expectCommandFieldTypeEql(exp.field_type, act.field_type);
            }
        },
        .Union => {
            if (actual != .Union or expected.Union.len != actual.Union.len) {
                return error.TestExpectedEqual;
            }

            for (expected.Union, actual.Union) |exp, act| {
                if (!std.mem.eql(u8, exp.name, act.name)) {
                    return error.TestExpectedEqual;
                }

                try expectCommandFieldTypeEql(exp.field_type, act.field_type);
            }
        },
        .Array => {
            if (actual != .Array or expected.Array.size != actual.Array.size) {
                return error.TestExpectedEqual;
            }

            try expectCommandFieldTypeEql(expected.Array.element_type.*, actual.Array.element_type.*);
        },
        .List => {
            if (actual != .List) {
                return error.TestExpectedEqual;
            }

            try expectCommandFieldTypeEql(expected.List.*, actual.List.*);
        },
        .Ref => {
            if (actual != .Ref or !Ref.eql(expected.Ref, actual.Ref)) {
                return error.TestExpectedEqual;
            }
        },
    }
}

fn expectFunctionSchemeEql(expected: FunctionScheme, actual: FunctionScheme) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or
        expected.functions.len != actual.functions.len or
        expected.dependencies.len != actual.dependencies.len)
    {
        return error.TestExpectedEqual;
    }

    for (expected.functions, actual.functions) |exp, act| {
        try expectFunctionEql(exp, act);
    }

    for (expected.dependencies, actual.dependencies) |exp, act| {
        try expectObjectSchemeEql(exp, act);
    }
}

fn expectFunctionEql(expected: FunctionScheme.Function, actual: FunctionScheme.Function) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or
        expected.versions.len != actual.versions.len)
    {
        return error.TestExpectedEqual;
    }

    for (expected.versions, actual.versions) |exp, act| {
        try expectFunctionVersionEql(exp, act);
    }
}

fn expectFunctionVersionEql(expected: FunctionScheme.Function.Version, actual: FunctionScheme.Function.Version) !void {
    if (expected.params.len != actual.params.len) {
        return error.TestExpectedEqual;
    }

    for (expected.params, actual.params) |exp, act| {
        try expectFieldTypeEql(exp, act);
    }

    try expectFieldTypeEql(expected.return_type, actual.return_type);
}

fn expectObjectSchemeEql(expected: ObjectScheme, actual: ObjectScheme) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or expected.objects.len != actual.objects.len) {
        return error.TestExpectedEqual;
    }

    for (expected.objects, actual.objects) |exp, act| {
        try expectObjectEql(exp, act);
    }
}

fn expectObjectEql(expected: ObjectScheme.Object, actual: ObjectScheme.Object) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or expected.versions.len != actual.versions.len) {
        return error.TestExpectedEqual;
    }

    for (expected.versions, actual.versions) |exp, act| {
        if (!FieldType.eql(exp, act)) {
            return error.TestExpectedEqual;
        }
    }
}

fn expectFieldTypeEql(expected: ?FieldType, actual: ?FieldType) !void {
    // uses the `FieldType.eql` implementation since it does everything, including chasing pointers.
    if (!FieldType.eql(expected, actual)) {
        return error.TestExpectedEqual;
    }
}