#include <iostream>
#include <vector>
#include <string>
#include <cstring>
#include <cstdio>
#include <chrono>
#include <iomanip>

// OpenCV Includes
#include <opencv2/opencv.hpp>
#include <opencv2/highgui.hpp>
#include <opencv2/videoio.hpp>
#include <opencv2/core/utils/logger.hpp>

// System Includes
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>

// --- Configuration ---
const std::string VIDEO_FILE = "test.avi";
std::string UDP_IP = "127.0.0.1";
const int VIDEO_PORT = 9999;
const int DATA_PORT = 9998;
const int TARGET_W = 1920;
const int TARGET_H = 1080;

// Set to TRUE to burn timestamp into video. 
// Set to FALSE for MAXIMUM PERFORMANCE (Zero-Copy Mode).
const bool DRAW_TEXT = true; 

// Set this artificially high to allow FFmpeg to process as fast as possible
const int MAX_FPS_CAP = 1000; 
const size_t MAX_RAM_FRAMES = 600;

int main(int argc,const char **argv) {
    if(argc>1 && argv[1]) UDP_IP = argv[2];
    // 0. Silence OpenCV logs
    cv::utils::logging::setLogLevel(cv::utils::logging::LOG_LEVEL_SILENT);

    // 1. Setup UDP Socket
    int sockfd;
    if ((sockfd = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
        perror("Socket creation failed");
        return -1;
    }

    struct sockaddr_in servaddr;
    memset(&servaddr, 0, sizeof(servaddr));
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons(DATA_PORT);
    servaddr.sin_addr.s_addr = inet_addr(UDP_IP.c_str());

    // 2. Pre-load Video to RAM
    std::cout << "Pre-loading video frames into RAM (Max " << MAX_RAM_FRAMES << ")..." << std::endl;
    cv::VideoCapture cap(VIDEO_FILE);
    if (!cap.isOpened()) {
        std::cerr << "Error: Input file '" << VIDEO_FILE << "' not found." << std::endl;
        return -1;
    }

    std::vector<cv::Mat> frame_cache;
    cv::Mat temp_frame, resized_frame;
    
    frame_cache.reserve(MAX_RAM_FRAMES);

    while (frame_cache.size() < MAX_RAM_FRAMES) {
        if (!cap.read(temp_frame)) break;
        
        if (temp_frame.cols != TARGET_W || temp_frame.rows != TARGET_H) {
            cv::resize(temp_frame, resized_frame, cv::Size(TARGET_W, TARGET_H));
            frame_cache.push_back(resized_frame.clone());
        } else {
            frame_cache.push_back(temp_frame.clone());
        }
    }
    cap.release();

    if (frame_cache.empty()) {
        std::cerr << "Error: No frames loaded." << std::endl;
        return -1;
    }
    std::cout << "Loaded " << frame_cache.size() << " frames into RAM." << std::endl;

    // 3. Setup FFmpeg Pipe
    // FIX: Added '-g 15' and '-forced-idr 1'
    // This forces a keyframe (fresh image) every 15 frames.
    // Without this, the receiver might wait seconds for the first image.
    char ffmpeg_cmd[2048];
    snprintf(ffmpeg_cmd, sizeof(ffmpeg_cmd),
        "ffmpeg -y -f rawvideo -vcodec rawvideo -pix_fmt bgr24 -s %dx%d -r %d -i - "
        "-c:v h264_nvenc -preset p1 -tune ull "
        "-rc constqp -qp 28 -pix_fmt yuv420p "
        "-g 15 -forced-idr 1 "
        "-f mpegts udp://%s:%d?pkt_size=1316",
        TARGET_W, TARGET_H, MAX_FPS_CAP, UDP_IP.c_str(), VIDEO_PORT
    );

    FILE* pipe = popen(ffmpeg_cmd, "w");
    if (!pipe) {
        std::cerr << "Error: Could not open pipe to FFmpeg." << std::endl;
        return -1;
    }

    // 4MB Pipe Buffer
    char pipe_buffer[4 * 1024 * 1024];
    setvbuf(pipe, pipe_buffer, _IOFBF, sizeof(pipe_buffer));

    std::cout << "Streaming Video -> udp://" << UDP_IP << ":" << VIDEO_PORT << " (NVIDIA NVENC + Keyframes)" << std::endl;
    std::cout << "Mode: " << (DRAW_TEXT ? "Text Overlay (Copy)" : "Zero-Copy (Max Speed)") << std::endl;

    long long frame_count = 0;
    size_t cache_idx = 0;
    size_t cache_size = frame_cache.size();
    
    cv::Mat working_frame;
    char ts_readable[64];
    char udp_msg[64];
    
    int fontFace = cv::FONT_HERSHEY_SIMPLEX;
    double fontScale = 2.5;
    int thickness = 5;
    int baseline = 0;

    // Center calculations
    cv::Size textSize = cv::getTextSize("00:00:00.000", fontFace, fontScale, thickness, &baseline);
    int text_x = (TARGET_W - textSize.width) / 2;
    int text_y = 100;
    
    size_t frame_data_size = TARGET_W * TARGET_H * 3;

    auto start_time = std::chrono::high_resolution_clock::now();

    while (true) {
        // --- TIMING ---
        auto now = std::chrono::system_clock::now();
        auto duration = now.time_since_epoch();
        double ts_unix = std::chrono::duration<double>(duration).count();

        // --- UDP DATA ---
        int msg_len = snprintf(udp_msg, sizeof(udp_msg), "%lld,%.3f", frame_count, ts_unix);
        sendto(sockfd, (const char *)udp_msg, msg_len, 
               MSG_CONFIRM, (const struct sockaddr *) &servaddr, sizeof(servaddr));

        // --- VIDEO PIPELINE ---
        uchar* data_ptr = nullptr;

        if (DRAW_TEXT) {
            // SLOW PATH: Copy memory, draw text
            frame_cache[cache_idx].copyTo(working_frame);
            
            std::time_t timer = std::chrono::system_clock::to_time_t(now);
            std::tm bt = *std::localtime(&timer);
            auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(duration) % 1000;
            snprintf(ts_readable, sizeof(ts_readable), "%02d:%02d:%02d.%03d", 
                     bt.tm_hour, bt.tm_min, bt.tm_sec, (int)millis.count());

            // Draw
            cv::putText(working_frame, ts_readable, cv::Point(text_x + 3, text_y + 3), fontFace, fontScale, cv::Scalar(0, 0, 0), thickness);
            cv::putText(working_frame, ts_readable, cv::Point(text_x, text_y), fontFace, fontScale, cv::Scalar(255, 255, 255), thickness);
            
            data_ptr = working_frame.data;
        } else {
            // FAST PATH: Zero-Copy
            data_ptr = frame_cache[cache_idx].data;
        }

        // --- PIPE WRITE ---
        size_t written = fwrite(data_ptr, 1, frame_data_size, pipe);
        if (written == 0) break;

        // Loop Logic
        cache_idx++;
        if (cache_idx >= cache_size) cache_idx = 0;
        frame_count++;

        // Status Update
        if (frame_count % 300 == 0) {
            auto current_time = std::chrono::high_resolution_clock::now();
            std::chrono::duration<double> elapsed = current_time - start_time;
            double actual_fps = frame_count / elapsed.count();
            std::cout << "\rSent: " << frame_count << " | Avg FPS: " << std::fixed << std::setprecision(1) << actual_fps << std::flush;
        }
    }

    pclose(pipe);
    close(sockfd);
    return 0;
}