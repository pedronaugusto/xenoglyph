const std = @import("std");

/// What a project that depends on xenoglyph builds: the `xenoglyph` module
/// and its library. The tests, generator, checks and benchmarks are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("xenoglyph", .{ .root_source_file = b.path("src/xenoglyph.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    b.installArtifact(b.addLibrary(.{ .name = "xenoglyph", .root_module = module }));
}

/// xenoglyph's development: its tests, example, table generator, checks and
/// benchmarks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("xenoglyph", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("xenoglyph");
    const library = package.artifact("xenoglyph");
    const aegis_dependency = p.dependency("aegis", .{ .target = target, .optimize = optimize });

    // The generator runs on the build host, built optimized: it reads the
    // whole UCD on every check. It targets the host's baseline CPU, as the
    // tests do in CI, where a binary built on one runner runs on another.
    const host = b.resolveTargetQuery(.{ .cpu_model = .baseline });
    const generator = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = p.path("tools/generate.zig"),
            .target = host,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "classes", .module = b.createModule(.{ .root_source_file = p.path("src/classes.zig") }) },
                .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = host, .optimize = .safe }).module("aegis") },
            },
        }),
    });
    const write = b.addRunArtifact(generator);
    write.setCwd(p.path("."));
    write.addArgs(&.{ "ucd", "src/data" });
    write.has_side_effects = true;
    b.step("ucd", "Write src/data from the UCD files in ucd/").dependOn(&write.step);
    const compare = b.addRunArtifact(generator);
    compare.setCwd(p.path("."));
    compare.addArgs(&.{ "ucd", "src/data", "--check" });
    compare.has_side_effects = true;
    const check_tables = b.step("check-tables", "Fail unless src/data is what the generator writes from ucd/");
    check_tables.dependOn(&compare.step);

    // The Unicode test files, which only the tests read: a module in ucd/,
    // outside what the package ships.
    const ucd = b.createModule(.{ .root_source_file = p.path("ucd/ucd.zig") });
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{
        .name = "xenoglyph-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ucd", .module = ucd },
                .{ .name = "aegis", .module = aegis_dependency.module("aegis") },
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
            },
        }),
    });
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    const test_step = b.step("test", "Run the tests, the example and the table check");
    const unit_run = b.addRunArtifact(tests);
    test_step.dependOn(&unit_run.step);
    // The suite alone, every binary of it holding properties: what the
    // hardened profile fuzzes and runs under ThreadSanitizer.
    b.step("unit", "Run the xenoglyph suite alone").dependOn(&unit_run.step);
    test_step.dependOn(check_tables);
    check.dependOn(&tests.step);
    check.dependOn(&library.step);
    check.dependOn(&generator.step);

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "xenoglyph", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);

    // Every call builds for a target with no OS.
    const freestanding = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const object = b.addObject(.{
        .name = "xenoglyph-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = p.path("ci/freestanding.zig"),
            .target = freestanding,
            .optimize = .small,
            .imports = &.{.{ .name = "xenoglyph", .module = xenoglyphModule(b, freestanding, .small) }},
        }),
    });
    b.step("check-freestanding", "Build every public call for wasm32-freestanding").dependOn(&object.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);

    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        // The release tier runs the suite with safety on, fuzzes its
        // properties and runs it under ThreadSanitizer.
        .hardened = .{ .fuzz_step = "unit", .tsan_step = "unit" },
        .bench = .{
            .programs = &.{
                .{ .name = "segment", .source = "bench/segment.zig" },
                .{ .name = "width", .source = "bench/width.zig" },
                .{ .name = "transform", .source = "bench/transform.zig" },
                .{ .name = "bidi", .source = "bench/bidi.zig" },
                .{ .name = "encoding", .source = "bench/encoding.zig" },
                .{ .name = "collation", .source = "bench/collation.zig" },
            },
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on xenoglyph by path, with no packages to
    // fetch: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "xenoglyph", .program = p.path("ci/consumer.zig"), .packages = &.{aegis_dependency}, .modules = &.{"xenoglyph"} });
}

/// xenoglyph again, in the mode a benchmark builds in: an imported module
/// keeps its own mode, so a ReleaseFast benchmark over the Debug module
/// would time the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const xenoglyph = xenoglyphModule(b, target, optimize);
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "xenoglyph", .module = xenoglyph }}) catch @panic("OOM");
}

fn xenoglyphModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const p = b.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).builder;
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    return b.createModule(.{ .root_source_file = p.path("src/xenoglyph.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = aegis }} });
}
