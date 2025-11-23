#ifndef GD_FFMPEG_REGISTER_TYPES_H
#define GD_FFMPEG_REGISTER_TYPES_H

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_ffmpeg_stream_module(ModuleInitializationLevel p_level);
void uninitialize_ffmpeg_stream_module(ModuleInitializationLevel p_level);

#endif // GD_FFMPEG_REGISTER_TYPES_H