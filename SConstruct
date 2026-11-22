import os

# Load godot-cpp build environment (same pattern as Asteroid Miner and Aevoria Simulator)
env = SConscript("godot-cpp/SConstruct")

# core/ is the pure C++17 farm simulation: no Godot types, so it is also built and
# tested on its own with CMake (see CMakeLists.txt and tests/). src/ holds the
# GDExtension classes that expose it, and the procedural graphics, to Godot.
env.Append(CPPPATH=["src", "core"])

sources = Glob("src/*.cpp") + Glob("core/*.cpp")

# Output directory inside the actual Godot project. Resolved relative to this
# SConstruct file's own directory (Dir("#")) rather than the caller's cwd, so
# it lands in the same place no matter where `scons` is invoked from.
output_dir = os.path.join(Dir("#").abspath, "godot", "bin")
if not os.path.exists(output_dir):
    os.makedirs(output_dir)

library = env.SharedLibrary(
    target=os.path.join(output_dir, f"libmarsfarm{env['suffix']}{env['SHLIBSUFFIX']}"),
    source=sources,
)

Default(library)
