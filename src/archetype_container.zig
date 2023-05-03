const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Type = std.builtin.Type;
const testing = std.testing;

const ztracy = @import("ztracy");
const Color = @import("misc.zig").Color;

const OpaqueArchetype = @import("OpaqueArchetype.zig");

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityRef = entity_type.EntityRef;

const ecez_query = @import("query.zig");
const QueryBuilder = ecez_query.QueryBuilder;
const Query = ecez_query.Query;
const hashType = ecez_query.hashType;

const meta = @import("meta.zig");
const Testing = @import("Testing.zig");

const ecez_error = @import("error.zig");
const StorageError = ecez_error.StorageError;

pub fn FromComponents(comptime submitted_components: []const type) type {
    const ComponentInfo = struct {
        hash: u64,
        type: type,
        @"struct": Type.Struct,
    };
    const Sort = struct {
        hash: u64,
    };

    comptime var biggest_component_size: usize = 0;

    // get some inital type info from the submitted components, and verify that all are components
    const component_info: [submitted_components.len]ComponentInfo = blk: {
        comptime var info: [submitted_components.len]ComponentInfo = undefined;
        comptime var sort: [submitted_components.len]Sort = undefined;
        for (submitted_components, 0..) |Component, i| {
            const component_size = @sizeOf(Component);
            if (component_size > biggest_component_size) {
                biggest_component_size = component_size;
            }

            const type_info = @typeInfo(Component);
            if (type_info != .Struct) {
                @compileError("component " ++ @typeName(Component) ++ " is not of type struct");
            }
            info[i] = .{
                .hash = hashType(Component),
                .@"struct" = type_info.Struct,
                .type = Component,
            };
            sort[i] = .{ .hash = info[i].hash };
        }
        comptime ecez_query.sort(Sort, &sort);
        for (sort, 0..) |s, j| {
            for (info, 0..) |inf, k| {
                if (s.hash == inf.hash) {
                    std.mem.swap(ComponentInfo, &info[j], &info[k]);
                }
            }
        }

        break :blk info;
    };

    const Node = struct {
        const Self = @This();

        pub const Arch = struct {
            path_index: usize,
            archetype: OpaqueArchetype,
        };

        archetypes: []?Arch,
        children: []?Self,

        pub fn init(allocator: Allocator, count: usize) error{OutOfMemory}!Self {
            std.debug.assert(submitted_components.len >= count);

            var archetypes = try allocator.alloc(?Arch, count);
            errdefer allocator.free(archetypes);
            @memset(archetypes, null);

            var children = try allocator.alloc(?Self, count);
            errdefer children.free(children);
            @memset(children, null);

            return Self{
                .archetypes = archetypes,
                .children = children,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.children) |maybe_child| {
                var m_child: ?Self = maybe_child;
                if (m_child) |*child| {
                    child.deinit(allocator);
                }
            }
            allocator.free(self.children);

            for (self.archetypes) |*maybe_arche| {
                if (maybe_arche.*) |*arche| {
                    arche.archetype.deinit();
                }
            }
            allocator.free(self.archetypes);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            for (self.children) |maybe_child| {
                var m_child: ?Self = maybe_child;
                if (m_child) |*child| {
                    child.clearRetainingCapacity();
                }
            }

            for (self.archetypes) |*maybe_arche| {
                if (maybe_arche.*) |*arche| {
                    arche.archetype.clearRetainingCapacity();
                }
            }
        }

        // TODO: this function should be shorter. Should not be too hard to make more concise ...
        /// retrieve all archetype interfaces that are at the path destination and all children of the destination
        pub fn getArchetypesWithComponents(self: Self, include_path: ?[]u16, exclude_path: []u16, result: *ArrayList(*OpaqueArchetype), depth: usize) error{OutOfMemory}!void {
            const exclude_step: usize = exclude_blk: {
                var index: usize = 0;
                while (index < exclude_path.len) {
                    if (exclude_path[index] >= depth) {
                        break :exclude_blk exclude_path[index];
                    }
                    index += 1;
                }

                // if we do not have any exclude next then we need to make sure any step does always not equal exclude step
                break :exclude_blk std.math.maxInt(usize);
            };

            // if we have not found nodes with our requirements
            if (include_path) |some_include_path| {
                std.debug.assert(some_include_path.len > 0);

                if (some_include_path.len > 1) {
                    // if desired path contains a step that is not part of the next step
                    if (some_include_path[0] < depth) {
                        return;
                    }

                    child_loop: for (self.children, 0..) |maybe_child, i| {
                        const depth_normalized_i = i + depth;

                        // make sure we are not stepping in an excluded path
                        for (exclude_path) |loop_exclude_step| {
                            if ((loop_exclude_step == depth_normalized_i)) continue :child_loop;
                        }

                        if (maybe_child) |child| {
                            const next_exclude_path = if (depth_normalized_i > exclude_step) exclude_path[1..] else exclude_path;

                            // if the path index is the current loop index
                            const on_path = some_include_path[0] == depth_normalized_i;

                            const from: usize = if (on_path) 1 else 0;
                            try child.getArchetypesWithComponents(some_include_path[from..], next_exclude_path, result, depth + 1);
                        }
                    }
                } else {
                    const arche_index = some_include_path[0] - depth;
                    // store the initial archetype meeting our requirement
                    if (self.archetypes[arche_index]) |*arche| {
                        try result.append(&arche.archetype);
                    }

                    const next_depth = depth + 1;

                    // if any of the steps are less than the depth then it means we are in a
                    // branch that does not contain any matches
                    const skip_searching_siblings = blk: {
                        for (some_include_path) |step| {
                            if (step < next_depth) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };

                    if (skip_searching_siblings) {
                        child_loop: for (self.children, 0..) |maybe_child, i| {
                            if (maybe_child) |child| {
                                if (i == arche_index) {
                                    const depth_normalized_i = i + depth;

                                    // make sure we are not stepping in an excluded path
                                    for (exclude_path) |loop_exclude_step| {
                                        if ((loop_exclude_step == depth_normalized_i)) continue :child_loop;
                                    }

                                    const next_exclude_path = if (depth_normalized_i > exclude_step) exclude_path[1..] else exclude_path;

                                    // record all defined archetypes in the child as well since they also only have suitable archetypes
                                    try child.getArchetypesWithComponents(null, next_exclude_path, result, next_depth);
                                }
                            }
                        }
                    } else {
                        child_loop: for (self.children, 0..) |maybe_child, i| {
                            if (maybe_child) |child| {
                                const depth_normalized_i = i + depth;

                                // make sure we are not stepping in an excluded path
                                for (exclude_path) |loop_exclude_step| {
                                    if ((loop_exclude_step == depth_normalized_i)) continue :child_loop;
                                }

                                const next_exclude_path = if (depth_normalized_i > exclude_step) exclude_path[1..] else exclude_path;

                                if (i == arche_index) {
                                    // record all defined archetypes in the child as well since they also only have suitable archetypes
                                    try child.getArchetypesWithComponents(null, next_exclude_path, result, next_depth);
                                } else {
                                    // look for matching component in the other children
                                    try child.getArchetypesWithComponents(some_include_path, next_exclude_path, result, next_depth);
                                }
                            }
                        }
                    }
                }
            } else {
                // all archetypes except any exclude should be fitting our requirement
                sibling_loop: for (self.archetypes, 0..) |*maybe_arche, i| {
                    if (maybe_arche.*) |*arche| {
                        const depth_normalized_i = i + depth;

                        // make sure we are not stepping in an excluded path
                        for (exclude_path) |loop_exclude_step| {
                            if ((loop_exclude_step == depth_normalized_i)) continue :sibling_loop;
                        }

                        try result.append(&arche.archetype);
                    }
                }

                // record all defined archetypes in the children as well since they also only have suitable archetypes
                child_loop: for (self.children, 0..) |maybe_child, i| {
                    if (maybe_child) |child| {
                        const depth_normalized_i = i + depth;

                        // make sure we are not stepping in an excluded path
                        for (exclude_path) |loop_exclude_step| {
                            if ((loop_exclude_step == depth_normalized_i)) continue :child_loop;
                        }

                        const next_exclude_path = if (depth_normalized_i > exclude_step) exclude_path[1..] else exclude_path;

                        try child.getArchetypesWithComponents(null, next_exclude_path, result, depth + 1);
                    }
                }
            }
        }
    };

    return struct {
        const ArcheContainer = @This();

        const void_index = 0;

        // contains the indices to find a given archetype
        pub const ArchetypePath = struct {
            len: usize,
            indices: [submitted_components.len]u16,
        };
        allocator: Allocator,
        archetype_paths: ArrayList(ArchetypePath),
        entity_references: ArrayList(EntityRef),
        root_node: Node,

        component_hashes: [submitted_components.len]u64,
        component_sizes: [submitted_components.len]usize,

        empty_bytes: [0]u8,

        pub inline fn init(allocator: Allocator) error{OutOfMemory}!ArcheContainer {
            var archetype_paths = ArrayList(ArchetypePath).init(allocator);
            try archetype_paths.append(ArchetypePath{ .len = 0, .indices = undefined });
            errdefer archetype_paths.deinit();

            var root_node = try Node.init(allocator, submitted_components.len);
            errdefer root_node.deinit(allocator);

            comptime var component_hashes: [submitted_components.len]u64 = undefined;
            comptime var component_sizes: [submitted_components.len]usize = undefined;
            inline for (component_info, &component_hashes, &component_sizes) |info, *hash, *size| {
                hash.* = info.hash;
                size.* = @sizeOf(info.type);
            }

            var entity_references = try ArrayList(EntityRef).initCapacity(allocator, 32);

            // append a special "void" type does not need to be defined (index 0 indicate void)
            std.debug.assert(entity_references.items.len == void_index);
            entity_references.appendAssumeCapacity(undefined);

            return ArcheContainer{
                .allocator = allocator,
                .archetype_paths = archetype_paths,
                .entity_references = entity_references,
                .root_node = root_node,
                .component_hashes = component_hashes,
                .component_sizes = component_sizes,
                .empty_bytes = .{},
            };
        }

        pub inline fn deinit(self: *ArcheContainer) void {
            self.archetype_paths.deinit();
            self.entity_references.deinit();
            self.root_node.deinit(self.allocator);
        }

        pub inline fn clearRetainingCapacity(self: *ArcheContainer) void {
            const zone = ztracy.ZoneNC(@src(), "Container clear", Color.arche_container);
            defer zone.End();

            // paths are kept
            // self.archetype_paths.clearRetainingCapacity();
            // self.archetype_paths.appendAssumeCapacity(ArchetypePath{ .len = 0, .indices = undefined });

            self.entity_references.clearRetainingCapacity();
            self.entity_references.appendAssumeCapacity(undefined);

            self.root_node.clearRetainingCapacity();
        }

        pub const CreateEntityResult = struct {
            new_archetype_container: bool,
            entity: Entity,
        };
        /// create a new entity and supply it an initial state
        /// Parameters:
        ///     - inital_state: the initial components of the entity
        ///
        /// Returns: A bool indicating if a new archetype has been made, and the entity
        pub inline fn createEntity(self: *ArcheContainer, initial_state: anytype) error{OutOfMemory}!CreateEntityResult {
            const zone = ztracy.ZoneNC(@src(), "Container createEntity", Color.arche_container);
            defer zone.End();

            const ArchetypeStruct = @TypeOf(initial_state);
            const arche_struct_info = blk: {
                const info = @typeInfo(ArchetypeStruct);
                if (info != .Struct) {
                    @compileError("expected initial_state to be of type struct");
                }
                break :blk info.Struct;
            };

            // create new entity
            const entity = Entity{ .id = @intCast(u32, self.entity_references.items.len) };

            // if no initial_state
            if (arche_struct_info.fields.len == 0) {
                // register a void reference to able to locate empty entity
                try self.entity_references.append(void_index);
                return CreateEntityResult{
                    .new_archetype_container = false,
                    .entity = entity,
                };
            }

            // if some initial state, then we initialize the storage needed
            const new_archetype_created = try self.initializeEntityStorage(entity, .create_new_ref, initial_state);
            return CreateEntityResult{
                .new_archetype_container = new_archetype_created,
                .entity = entity,
            };
        }

        /// Assign the component value to an entity
        /// Errors:
        ///     - EntityMissing: if the entity does not exist
        ///     - OutOfMemory: if OOM
        /// Return:
        ///     True if a new archetype was created for this operation
        pub inline fn setComponent(self: *ArcheContainer, entity: Entity, component: anytype) error{ EntityMissing, OutOfMemory }!bool {
            const zone = ztracy.ZoneNC(@src(), "Container setComponent", Color.arche_container);
            defer zone.End();

            // get the archetype of the entity
            if (self.getArchetypeWithEntity(entity)) |arche| {
                // try to update component in current archetype
                if (arche.archetype.setComponent(entity, component)) |ok| {
                    // ok we don't need to do anymore
                    _ = ok;
                } else |err| {
                    switch (err) {
                        // component is not part of current archetype
                        error.ComponentMissing => {
                            const component_index = comptime componentIndex(@TypeOf(component));

                            const old_path = self.archetype_paths.items[arche.path_index];
                            var new_component_index: usize = 0;
                            const new_path = blk1: {
                                // the new path of the entity will be based on its current path
                                var path = ArchetypePath{
                                    .len = old_path.len + 1,
                                    .indices = undefined,
                                };
                                std.mem.copy(u16, &path.indices, old_path.indices[0..old_path.len]);

                                // loop old path and find the correct order to insert the new component
                                new_component_index = blk2: {
                                    for (path.indices[0..old_path.len], 0..) |step, depth| {
                                        const existing_component_index = step + depth;
                                        if (existing_component_index > component_index) {
                                            break :blk2 depth;
                                        }
                                    }
                                    // component is the last component
                                    break :blk2 old_path.len;
                                };

                                path.indices[new_component_index] = @intCast(u15, component_index - new_component_index);
                                for (old_path.indices[new_component_index..old_path.len], 0..) |step, i| {
                                    const index = new_component_index + i + 1;
                                    path.indices[index] = step - 1;
                                }

                                break :blk1 path;
                            };

                            var new_archetype_created: bool = undefined;
                            const new_arche: *Node.Arch = blk1: {
                                var arche_node = blk: {
                                    var current_node: *Node = &self.root_node;
                                    for (new_path.indices[0 .. new_path.len - 1]) |step| {
                                        if (current_node.children[step]) |*some| {
                                            current_node = some;
                                        } else {
                                            // create new node and set it as current node
                                            current_node.children[step] = try Node.init(
                                                self.allocator,
                                                current_node.children.len - 1,
                                            );
                                            current_node = &current_node.children[step].?;
                                        }
                                    }
                                    break :blk current_node;
                                };

                                const archetype_index = new_path.indices[new_path.len - 1];
                                if (arche_node.archetypes[archetype_index]) |*some| {
                                    new_archetype_created = false;
                                    break :blk1 some;
                                } else {
                                    var type_hashes: [submitted_components.len]u64 = undefined;
                                    var type_sizes: [submitted_components.len]usize = undefined;
                                    for (new_path.indices[0..new_path.len], 0..) |step, i| {
                                        type_hashes[i] = self.component_hashes[step + i];
                                        type_sizes[i] = self.component_sizes[step + i];
                                    }

                                    // register archetype path
                                    try self.archetype_paths.append(new_path);
                                    errdefer _ = self.archetype_paths.pop();

                                    // create new opaque archetype
                                    arche_node.archetypes[archetype_index] = Node.Arch{
                                        .path_index = self.archetype_paths.items.len - 1,
                                        .archetype = OpaqueArchetype.init(self.allocator, type_hashes[0..new_path.len], type_sizes[0..new_path.len]) catch {
                                            return error.OutOfMemory;
                                        },
                                    };

                                    new_archetype_created = true;
                                    break :blk1 &(arche_node.archetypes[archetype_index].?);
                                }
                            };

                            var data: [submitted_components.len][]u8 = undefined;
                            inline for (component_info, 0..) |_, i| {
                                var buf: [biggest_component_size]u8 = undefined;
                                data[i] = &buf;
                            }

                            // remove the entity and it's components from the old archetype
                            try arche.archetype.rawSwapRemoveEntity(entity, data[0..old_path.len]);

                            // insert the new component at it's correct location
                            var rhd = data[new_component_index..new_path.len];
                            std.mem.rotate([]u8, rhd, rhd.len - 1);
                            std.mem.copy(u8, data[new_component_index], std.mem.asBytes(&component));
                            // register the entity in the new archetype
                            try new_arche.archetype.rawRegisterEntity(entity, data[0..new_path.len]);

                            // update entity reference
                            self.entity_references.items[entity.id] = @intCast(EntityRef, new_arche.path_index);

                            return new_archetype_created;
                        },
                        // if this happen, then the container is in an invalid state
                        error.EntityMissing => {
                            unreachable;
                        },
                    }
                }
            } else {
                // workaround for https://github.com/ziglang/zig/issues/12963
                const T = std.meta.Tuple(&[_]type{@TypeOf(component)});
                var t: T = undefined;
                t[0] = component;

                // this entity has no previous storage, initialize some if needed
                return self.initializeEntityStorage(entity, .reassign_existing_ref, t);
            }
            return false;
        }

        /// Remove the Component type from an entity
        /// Errors:
        ///     - EntityMissing: if the entity does not exist
        ///     - OutOfMemory: if OOM
        /// Return:
        ///     True if a new archetype was created for this operation
        pub fn removeComponent(self: *ArcheContainer, entity: Entity, comptime Component: type) error{ EntityMissing, OutOfMemory }!bool {
            if (self.hasComponent(entity, Component) == false) {
                return false;
            }

            // we know that archetype exist because hasComponent can only return if it does
            const old_arche = self.getArchetypeWithEntity(entity).?;
            const old_path = self.archetype_paths.items[old_arche.path_index];

            var data: [submitted_components.len][]u8 = undefined;
            inline for (component_info, 0..) |_, i| {
                var buf: [biggest_component_size]u8 = undefined;
                data[i] = &buf;
            }
            // remove the entity and it's components from the old archetype
            try old_arche.archetype.rawSwapRemoveEntity(entity, data[0..old_path.len]);

            if (old_path.len <= 1) {
                // update entity reference
                self.entity_references.items[entity.id] = void_index;
                return false;
            }

            var remove_component_index: usize = undefined;
            const new_path = blk: {
                const component_hash = comptime hashType(Component);

                var path = ArchetypePath{
                    .len = 0,
                    .indices = undefined,
                };

                var removed_step: bool = false;
                for (old_path.indices[0..old_path.len], 0..) |step, i| {
                    const component_index = step + i;
                    if (self.component_hashes[component_index] != component_hash) {
                        path.indices[path.len] = if (removed_step) step + 1 else step;
                        path.len += 1;
                    } else {
                        remove_component_index = i;
                        removed_step = true;
                    }
                }

                break :blk path;
            };

            var arche_node = blk: {
                var current_node: Node = self.root_node;
                for (new_path.indices[0 .. new_path.len - 1]) |step| {
                    if (current_node.children[step]) |some| {
                        current_node = some;
                    } else {
                        // create new node and set it as current node
                        current_node.children[step] = try Node.init(
                            self.allocator,
                            current_node.children.len - 1,
                        );
                        current_node = current_node.children[step].?;
                    }
                }
                break :blk current_node;
            };

            var new_archetype_created: bool = undefined;
            var new_archetype: *Node.Arch = blk: {
                const archetype_index = new_path.indices[new_path.len - 1];
                if (arche_node.archetypes[archetype_index]) |*some| {
                    new_archetype_created = false;
                    break :blk some;
                } else {
                    var type_hashes: [submitted_components.len]u64 = undefined;
                    var type_sizes: [submitted_components.len]usize = undefined;
                    for (new_path.indices[0..new_path.len], 0..) |step, i| {
                        type_hashes[i] = self.component_hashes[step + i];
                        type_sizes[i] = self.component_sizes[step + i];
                    }

                    // register archetype path
                    try self.archetype_paths.append(new_path);

                    // create new opaque archetype
                    arche_node.archetypes[archetype_index] = Node.Arch{
                        .path_index = self.archetype_paths.items.len - 1,
                        .archetype = OpaqueArchetype.init(self.allocator, type_hashes[0..new_path.len], type_sizes[0..new_path.len]) catch {
                            return error.OutOfMemory;
                        },
                    };

                    new_archetype_created = true;
                    break :blk &arche_node.archetypes[archetype_index].?;
                }
            };

            var rhd = data[remove_component_index..old_path.len];
            std.mem.rotate([]u8, rhd, 1);

            // register the entity in the new archetype
            try new_archetype.archetype.rawRegisterEntity(entity, data[0..new_path.len]);

            // update entity reference
            self.entity_references.items[entity.id] = @intCast(EntityRef, new_archetype.path_index);

            return new_archetype_created;
        }

        pub inline fn getTypeHashes(self: ArcheContainer, entity: Entity) ?[]u64 {
            const ref = switch (self.entity_references.items[entity.id]) {
                void_index => return null, // void type
                else => |index| index,
            };
            const path = self.archetype_paths.items[ref];

            var hashes: [submitted_components.len]u64 = undefined;
            for (path.indices[0..path.len], 0..) |step, i| {
                hashes[i] = self.component_hashes[step + i];
            }

            // TODO: Returning stack memory ok for inline?
            return hashes[0..path.len];
        }

        pub inline fn hasComponent(self: ArcheContainer, entity: Entity, comptime Component: type) bool {
            // verify that component exist in storage
            _ = comptime componentIndex(Component);
            // get the archetype of the entity
            const node = self.getArchetypeWithEntity(entity) orelse return false;
            return node.archetype.hasComponent(Component);
        }

        /// Query archetypes containing all components listed in component_hashes
        /// caller own the returned memory
        pub fn getArchetypesWithComponents(
            self: ArcheContainer,
            allocator: Allocator,
            include_component_hashes: []const u64,
            exclude_component_hashes: []const u64,
        ) error{OutOfMemory}![]*OpaqueArchetype {
            var include_path: [submitted_components.len]u16 = undefined;
            for (include_component_hashes, 0..) |include_hash, i| {
                include_path[i] = blk: {
                    for (self.component_hashes[i..], 0..) |stored_hash, step| {
                        if (include_hash == stored_hash) {
                            break :blk @intCast(u15, step + i);
                        }
                    }
                    unreachable; // should be compile type guards before we reach this point ...
                };
            }

            var exclude_path: [submitted_components.len]u16 = undefined;
            for (exclude_component_hashes, 0..) |exclude_hash, i| {
                exclude_path[i] = blk: {
                    for (self.component_hashes[i..], 0..) |stored_hash, step| {
                        if (exclude_hash == stored_hash) {
                            break :blk @intCast(u15, step + i);
                        }
                    }
                    unreachable; // should be compile type guards before we reach this point ...
                };
            }

            var resulting_archetypes = ArrayList(*OpaqueArchetype).init(allocator);
            try self.root_node.getArchetypesWithComponents(
                include_path[0..include_component_hashes.len],
                exclude_path[0..exclude_component_hashes.len],
                &resulting_archetypes,
                0,
            );

            return resulting_archetypes.toOwnedSlice();
        }

        pub inline fn getComponent(self: ArcheContainer, entity: Entity, comptime Component: type) ecez_error.ArchetypeError!Component {
            const zone = ztracy.ZoneNC(@src(), "Container getComponent", Color.arche_container);
            defer zone.End();
            const node = self.getArchetypeWithEntity(entity) orelse return error.ComponentMissing;
            return node.archetype.getComponent(entity, Component);
        }

        const RefHandling = enum {
            create_new_ref,
            reassign_existing_ref,
        };
        /// This function can initialize the storage for
        inline fn initializeEntityStorage(self: *ArcheContainer, entity: Entity, entity_ref_handling: RefHandling, initial_state: anytype) error{OutOfMemory}!bool {
            const zone = ztracy.ZoneNC(@src(), "Container createEntity", Color.arche_container);
            defer zone.End();

            const ArchetypeStruct = @TypeOf(initial_state);
            const arche_struct_info = blk: {
                const info = @typeInfo(ArchetypeStruct);
                if (info != .Struct) {
                    @compileError("expected initial_state to be of type struct");
                }
                break :blk info.Struct;
            };
            if (arche_struct_info.fields.len == 0) {
                // no storage should be created if initial state is empty
                @compileError("called initializeEntityStorage with empty initial_state is illegal");
            }

            const TypeMap = struct {
                hash: u64,
                state_index: usize,
                component_index: u16,
            };

            const index_path = comptime blk1: {
                var path: [arche_struct_info.fields.len]TypeMap = undefined;
                var sort: [arche_struct_info.fields.len]Sort = undefined;
                inline for (arche_struct_info.fields, 0..) |field, i| {
                    // find index of field in outer component array
                    const component_index = blk2: {
                        inline for (component_info, 0..) |component, j| {
                            if (field.type == component.type) {
                                break :blk2 @intCast(u15, j);
                            }
                        }
                        @compileError(@typeName(field.type) ++ " is not a registered component type");
                    };

                    path[i] = TypeMap{
                        .hash = hashType(field.type),
                        .state_index = i,
                        .component_index = component_index,
                    };
                    sort[i] = .{ .hash = path[i].hash };
                }
                // sort based on hash
                ecez_query.sort(Sort, &sort);

                // sort path based on hash
                for (sort, 0..) |s, j| {
                    for (path, 0..) |p, k| {
                        if (s.hash == p.hash) {
                            std.mem.swap(TypeMap, &path[j], &path[k]);
                        }
                    }
                }
                break :blk1 path;
            };

            // TODO: errdefer deinit allocations!
            // get the node that will store the new entity
            var entity_node: *Node = blk: {
                var current_node = &self.root_node;
                for (index_path[0 .. index_path.len - 1], 0..) |path, depth| {
                    const index = path.component_index - depth;
                    // see if our new node exist
                    if (current_node.children[index]) |*child| {
                        // set target child node as current node
                        current_node = child;
                    } else {
                        // create new node and set it as current node
                        current_node.children[index] = try Node.init(
                            self.allocator,
                            current_node.children.len - 1,
                        );
                        current_node = &(current_node.children[index].?);
                    }
                }
                break :blk current_node;
            };

            // create a component byte data view
            const fields = @typeInfo(ArchetypeStruct).Struct.fields;
            var data: [arche_struct_info.fields.len][]const u8 = undefined;
            inline for (index_path, 0..) |path, i| {
                if (@sizeOf(fields[path.state_index].type) > 0) {
                    const field = &@field(initial_state, fields[path.state_index].name);
                    data[i] = std.mem.asBytes(field);
                } else {
                    data[i] = &self.empty_bytes;
                }
            }

            var new_archetype_created: bool = undefined;
            // get the index of the archetype in the node
            const archetype_index = index_path[index_path.len - 1].component_index - (index_path.len - 1);
            const path_index = blk1: {
                if (entity_node.archetypes[archetype_index]) |*arche| {
                    try arche.archetype.rawRegisterEntity(entity, &data);
                    new_archetype_created = false;
                    break :blk1 arche.path_index;
                } else {
                    // register archetype path
                    const arche_path_index = self.archetype_paths.items.len;
                    {
                        var archetype_path = ArchetypePath{
                            .len = index_path.len,
                            .indices = undefined,
                        };
                        for (index_path, 0..) |sub_path, i| {
                            archetype_path.indices[i] = sub_path.component_index - @intCast(u15, i);
                        }
                        try self.archetype_paths.append(archetype_path);
                    }
                    errdefer _ = self.archetype_paths.pop();

                    comptime var type_hashes: [index_path.len]u64 = undefined;
                    comptime var type_sizes: [index_path.len]usize = undefined;
                    inline for (index_path, 0..) |path, i| {
                        const Component = fields[path.state_index].type;
                        type_hashes[i] = comptime ecez_query.hashType(Component);
                        type_sizes[i] = @sizeOf(Component);
                    }

                    // create new opaque archetype
                    entity_node.archetypes[archetype_index] = Node.Arch{
                        .path_index = arche_path_index,
                        .archetype = OpaqueArchetype.init(self.allocator, &type_hashes, &type_sizes) catch {
                            return error.OutOfMemory;
                        },
                    };
                    // register entity in the new archetype
                    try entity_node.archetypes[archetype_index].?.archetype.rawRegisterEntity(entity, &data);

                    new_archetype_created = true;
                    break :blk1 arche_path_index;
                }
            };

            // register a reference to able to locate entity
            const new_ref = @intCast(EntityRef, path_index);
            if (entity_ref_handling == .create_new_ref) {
                try self.entity_references.append(new_ref);
            } else {
                self.entity_references.items[entity.id] = new_ref;
            }
            errdefer {
                if (entity_ref_handling == .create_new_ref) {
                    _ = self.entity_references.pop();
                }
            }

            return new_archetype_created;
        }

        inline fn getArchetypeWithEntity(self: ArcheContainer, entity: Entity) ?*Node.Arch {
            const ref = switch (self.entity_references.items[entity.id]) {
                void_index => return null, // void type
                else => |index| index,
            };
            const path = self.archetype_paths.items[ref];

            var entity_node = self.getNodeWithPath(path);

            // if entity is not spoofed, then this is always defined
            return &entity_node.archetypes[path.indices[path.len - 1]].?;
        }

        inline fn getNodeWithPath(self: ArcheContainer, path: ArchetypePath) Node {
            var current_node: Node = self.root_node;
            for (path.indices[0 .. path.len - 1]) |step| {
                // if node is null, then entity has been modified externally, or there is a
                // bug in ecez
                current_node = current_node.children[step].?;
            }
            return current_node;
        }

        inline fn componentIndex(comptime Component: type) comptime_int {
            inline for (component_info, 0..) |info, i| {
                if (Component == info.type) {
                    return i;
                }
            }
            @compileError("component type " ++ @typeName(Component) ++ " is not a registered component type");
        }
    };
}

const TestContainer = FromComponents(&Testing.AllComponentsArr);

test "ArcheContainer init + deinit is idempotent" {
    var container = try TestContainer.init(testing.allocator);
    container.deinit();
}

test "ArcheContainer createEntity & getComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.ABC{
        .a = Testing.Component.A{ .value = 1 },
        .b = Testing.Component.B{ .value = 2 },
        .c = Testing.Component.C{},
    };

    const create_result = try container.createEntity(initial_state);
    const entity = create_result.entity;

    try testing.expectEqual(initial_state.a, try container.getComponent(entity, Testing.Component.A));
    try testing.expectEqual(initial_state.b, try container.getComponent(entity, Testing.Component.B));
    try testing.expectEqual(initial_state.c, try container.getComponent(entity, Testing.Component.C));
}

test "ArcheContainer setComponent & getComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.AC{
        .a = Testing.Component.A{ .value = 1 },
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;

    const a = Testing.Component.A{ .value = 40 };
    _ = try container.setComponent(entity, a);
    try testing.expectEqual(a, try container.getComponent(entity, Testing.Component.A));

    const b = Testing.Component.B{ .value = 42 };
    _ = try container.setComponent(entity, b);
    try testing.expectEqual(b, try container.getComponent(entity, Testing.Component.B));
}

test "ArcheContainer getTypeHashes works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.AC{
        .a = Testing.Component.A{ .value = 1 },
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;

    try testing.expectEqualSlices(
        u64,
        &[_]u64{ ecez_query.hashType(Testing.Component.A), ecez_query.hashType(Testing.Component.C) },
        container.getTypeHashes(entity).?,
    );
}

test "ArcheContainer hasComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.AC{
        .a = Testing.Component.A{ .value = 1 },
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;

    try testing.expectEqual(true, container.hasComponent(entity, Testing.Component.A));
    try testing.expectEqual(false, container.hasComponent(entity, Testing.Component.B));
    try testing.expectEqual(true, container.hasComponent(entity, Testing.Component.C));
}

test "ArcheContainer getArchetypesWithComponents returns matching archetypes" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const a_hash = comptime hashType(Testing.Component.A);
    const b_hash = comptime hashType(Testing.Component.B);
    const c_hash = comptime hashType(Testing.Component.C);
    if (a_hash > b_hash) {
        @compileError("hash function give unexpected result");
    }
    if (b_hash > c_hash) {
        @compileError("hash function give unexpected result");
    }

    const initial_state = Testing.Archetype.C{
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{c_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{b_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }

    _ = try container.setComponent(entity, Testing.Component.A{});
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{c_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{b_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }

    _ = try container.setComponent(entity, Testing.Component.B{});
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{c_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 3), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{b_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }

    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ a_hash, c_hash },
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ a_hash, b_hash },
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ b_hash, c_hash },
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
}

test "ArcheContainer getArchetypesWithComponents can exclude archetypes" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const a_hash = comptime hashType(Testing.Component.A);
    const b_hash = comptime hashType(Testing.Component.B);
    const c_hash = comptime hashType(Testing.Component.C);
    if (a_hash > b_hash) {
        @compileError("hash function give unexpected result");
    }
    if (b_hash > c_hash) {
        @compileError("hash function give unexpected result");
    }

    // make sure the container have Archetype {A}, {B}, {C}, {AB}, {AC}, {ABC}
    _ = try container.createEntity(Testing.Archetype.A{});
    _ = try container.createEntity(Testing.Archetype.B{});
    _ = try container.createEntity(Testing.Archetype.C{});
    _ = try container.createEntity(Testing.Archetype.AB{});
    _ = try container.createEntity(Testing.Archetype.AC{});
    _ = try container.createEntity(Testing.Archetype.ABC{});

    // ask for A, excluding C
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[_]u64{c_hash},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }

    // ask for A, excluding B, C
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[_]u64{ b_hash, c_hash },
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }

    // ask for B, excluding A
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{b_hash},
            &[_]u64{a_hash},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }

    // ask for C, excluding B
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{c_hash},
            &[_]u64{b_hash},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }
}
