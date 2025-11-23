#!/usr/bin/env python3
import os
import sys

env = SConscript("godot-cpp/SConstruct")

# --- FFmpeg Linking Configuration ---
# We use pkg-config to automatically find include paths and libs
env.ParseConfig('pkg-config --cflags --libs libavcodec libavformat libavutil libswscale')

# Capture the compilation DB target
compilation_db = env.CompilationDatabase("compile_commands.json")

# Basic optimizations for speed
if env["target"] == "template_release":
    env.Append(CCFLAGS=["-O3", "-ffast-math"])

# Sources
sources = [
    "ffmpeg_stream/ffmpeg_stream.cpp",
    "ffmpeg_stream/register_types.cpp"
]

# Build the shared library
library = env.SharedLibrary(
    "godot/bin/libgdffmpegstream{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

# --- CRITICAL FIX: Add compilation_db to default build targets ---
Default(library, compilation_db)