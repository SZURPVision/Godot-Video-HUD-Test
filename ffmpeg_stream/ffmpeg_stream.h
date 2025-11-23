#ifndef FFMPEG_STREAM_H
#define FFMPEG_STREAM_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/classes/mutex.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/time.hpp> 
#include <atomic>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
}

namespace godot {

class FFmpegStream : public Node {
    GDCLASS(FFmpegStream, Node)

private:
    Ref<ImageTexture> texture;
    
    // FFmpeg context
    AVFormatContext *fmt_ctx = nullptr;
    AVCodecContext *codec_ctx = nullptr;
    AVFrame *frame = nullptr;
    AVFrame *rgb_frame = nullptr;
    AVPacket *packet = nullptr;
    SwsContext *sws_ctx = nullptr;
    int video_stream_idx = -1;

    // Threading
    Ref<Thread> decode_thread;
    Ref<Mutex> mutex;
    std::atomic<bool> quit_thread;
    std::atomic<bool> new_frame_available;
    
    // Frame Buffer
    PackedByteArray frame_data_buffer;
    int width = 0;
    int height = 0;
    
    // Latency Measurement
    double last_decoding_time = 0.0;

    void _thread_func();
    void cleanup_ffmpeg();

protected:
    static void _bind_methods();

public:
    FFmpegStream();
    ~FFmpegStream();

    void _ready() override;
    void _process(double delta) override;
    void _exit_tree() override;

    Ref<ImageTexture> get_video_texture() const;
    double get_decoding_latency() const;
    void start_stream(const String &url);
};

}

#endif