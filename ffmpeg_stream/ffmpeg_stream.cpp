#include "ffmpeg_stream.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/time.hpp> // Required for latency measurement

using namespace godot;

void FFmpegStream::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_video_texture"), &FFmpegStream::get_video_texture);
    ClassDB::bind_method(D_METHOD("start_stream", "url"), &FFmpegStream::start_stream);
    ClassDB::bind_method(D_METHOD("get_decoding_latency"), &FFmpegStream::get_decoding_latency);
}

FFmpegStream::FFmpegStream() {
    quit_thread = false;
    new_frame_available = false;
    last_decoding_time = 0.0;
    
    // Instantiate Mutex (Prevents "binding callbacks" crash)
    mutex.instantiate(); 
    
    // Initialize network for FFmpeg
    avformat_network_init();
}

FFmpegStream::~FFmpegStream() {
    _exit_tree();
}

void FFmpegStream::_ready() {
    // Automatically start listening on localhost
    start_stream("udp://127.0.0.1:9999");
}

void FFmpegStream::start_stream(const String &url) {
    if (decode_thread.is_null()) {
        decode_thread.instantiate();
    }
    
    if (decode_thread->is_started()) return;
    decode_thread->start(callable_mp(this, &FFmpegStream::_thread_func));
}

void FFmpegStream::_exit_tree() {
    quit_thread = true;
    if (decode_thread.is_valid() && decode_thread->is_started()) {
        decode_thread->wait_to_finish();
    }
    cleanup_ffmpeg();
}

void FFmpegStream::cleanup_ffmpeg() {
    if (frame) av_frame_free(&frame);
    if (rgb_frame) av_frame_free(&rgb_frame);
    if (packet) av_packet_free(&packet);
    if (codec_ctx) avcodec_free_context(&codec_ctx);
    if (fmt_ctx) avformat_close_input(&fmt_ctx);
    if (sws_ctx) sws_freeContext(sws_ctx);
}

double FFmpegStream::get_decoding_latency() const {
    return last_decoding_time;
}

void FFmpegStream::_thread_func() {
    // 1. Open Input
    AVDictionary *opts = nullptr;
    // Increased buffer for 1080p stream stability
    av_dict_set(&opts, "buffer_size", "2048000", 0);
    av_dict_set(&opts, "fifo_size", "500000", 0); 
    
    if (avformat_open_input(&fmt_ctx, "udp://127.0.0.1:9999", nullptr, &opts) < 0) {
        UtilityFunctions::print("Failed to open UDP stream");
        return;
    }

    if (avformat_find_stream_info(fmt_ctx, nullptr) < 0) {
        UtilityFunctions::print("Failed to find stream info");
        return;
    }

    // 2. Find Video Stream & Decoder
    video_stream_idx = -1;
    for (unsigned int i = 0; i < fmt_ctx->nb_streams; i++) {
        if (fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            video_stream_idx = i;
            break;
        }
    }

    if (video_stream_idx == -1) return;

    AVCodecParameters *codecpar = fmt_ctx->streams[video_stream_idx]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);

    codec_ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(codec_ctx, codecpar);
    codec_ctx->thread_count = 0; 
    
    if (avcodec_open2(codec_ctx, codec, nullptr) < 0) {
        UtilityFunctions::print("Failed to open codec");
        return;
    }

    // 3. Alloc structures
    frame = av_frame_alloc();
    rgb_frame = av_frame_alloc();
    packet = av_packet_alloc();

    // 4. Decode Loop
    while (!quit_thread) {
        if (av_read_frame(fmt_ctx, packet) >= 0) {
            if (packet->stream_index == video_stream_idx) {
                
                // --- LATENCY MEASUREMENT START ---
                uint64_t start_time = Time::get_singleton()->get_ticks_usec();

                if (avcodec_send_packet(codec_ctx, packet) == 0) {
                    while (avcodec_receive_frame(codec_ctx, frame) == 0) {
                        
                        if (!sws_ctx) {
                            width = frame->width;
                            height = frame->height;
                            sws_ctx = sws_getContext(width, height, codec_ctx->pix_fmt,
                                                   width, height, AV_PIX_FMT_RGB24,
                                                   SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
                            
                            av_image_alloc(rgb_frame->data, rgb_frame->linesize, 
                                         width, height, AV_PIX_FMT_RGB24, 1);
                        }

                        sws_scale(sws_ctx, (const uint8_t *const *)frame->data, frame->linesize,
                                  0, height, rgb_frame->data, rgb_frame->linesize);

                        // --- LATENCY MEASUREMENT END ---
                        uint64_t end_time = Time::get_singleton()->get_ticks_usec();
                        last_decoding_time = (double)(end_time - start_time) / 1000.0;

                        // Thread-safe update
                        mutex->lock();
                        int size = width * height * 3;
                        if (frame_data_buffer.size() != size) frame_data_buffer.resize(size);
                        memcpy(frame_data_buffer.ptrw(), rgb_frame->data[0], size);
                        new_frame_available = true;
                        mutex->unlock();
                    }
                }
            }
            av_packet_unref(packet);
        } else {
            // Wait slightly if no packet (prevents CPU spin)
            OS::get_singleton()->delay_usec(1000);
        }
    }
}

void FFmpegStream::_process(double delta) {
    if (new_frame_available) {
        mutex->lock();
        PackedByteArray data_copy = frame_data_buffer;
        new_frame_available = false;
        mutex->unlock();

        if (data_copy.size() > 0) {
            Ref<Image> img = Image::create_from_data(width, height, false, Image::FORMAT_RGB8, data_copy);
            
            if (texture.is_null()) {
                texture = ImageTexture::create_from_image(img);
            } else {
                texture->update(img);
            }
        }
    }
}

Ref<ImageTexture> FFmpegStream::get_video_texture() const {
    return texture;
}