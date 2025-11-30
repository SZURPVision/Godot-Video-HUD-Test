#include <iostream>
#include <vector>
#include <string>
#include <cstring>
#include <cstdio>
#include <chrono>
#include <iomanip>
#include <thread> // For sleep_for
#include <atomic> // For thread safety

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
const int PING_PORT = 9997;
const int TARGET_W = 1280;
const int TARGET_H = 720;

// Set to TRUE to burn timestamp into video. 
const bool DRAW_TEXT = true; 

void ping_listener() {
    int sockfd;
    struct sockaddr_in servaddr, cliaddr;
    
    if ((sockfd = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
        perror("Ping socket creation failed");
        return;
    }
    
    memset(&servaddr, 0, sizeof(servaddr));
    memset(&cliaddr, 0, sizeof(cliaddr));
    
    servaddr.sin_family = AF_INET;
    servaddr.sin_addr.s_addr = INADDR_ANY;
    servaddr.sin_port = htons(PING_PORT);
    
    if (bind(sockfd, (const struct sockaddr *)&servaddr, sizeof(servaddr)) < 0) {
        perror("Ping bind failed");
        return;
    }
    
    std::cout << "RTT Service: Listening for Pings on port " << PING_PORT << std::endl;
    
    char buffer[1024];
    socklen_t len = sizeof(cliaddr);
    
    while (true) {
        int n = recvfrom(sockfd, (char *)buffer, 1024, MSG_WAITALL, (struct sockaddr *) &cliaddr, &len);
        if (n > 0) {
            // Echo back immediately (Ping-Pong)
            sendto(sockfd, (const char *)buffer, n, MSG_CONFIRM, (const struct sockaddr *) &cliaddr, len);
        }
    }
}

int main(int argc, const char **argv) {
    // Argument Parsing: ./sender [IP] [FPS]
    if (argc > 1) UDP_IP = argv[1];
    int target_fps = 60;
    if (argc > 2) target_fps = std::stoi(argv[2]);

    // Start Ping Listener Thread
    std::thread ping_thread(ping_listener);
    ping_thread.detach();

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

    // 2. Open Video Source
    cv::VideoCapture cap(VIDEO_FILE);
    if (!cap.isOpened()) {
        std::cerr << "Error: Input file '" << VIDEO_FILE << "' not found." << std::endl;
        return -1;
    }

    // 3. Setup FFmpeg Pipe
    char ffmpeg_cmd[2048];
    snprintf(ffmpeg_cmd, sizeof(ffmpeg_cmd),
        "ffmpeg -y -f rawvideo -vcodec rawvideo -pix_fmt bgr24 -s %dx%d -r %d -i - "
        "-c:v h264_nvenc -preset p1 -tune ull "
        "-rc constqp -qp 28 -pix_fmt yuv420p "
        "-g 15 -forced-idr 1 "
        "-f mpegts udp://%s:%d?pkt_size=1316",
        TARGET_W, TARGET_H, target_fps, UDP_IP.c_str(), VIDEO_PORT
    );

    FILE* pipe = popen(ffmpeg_cmd, "w");
    if (!pipe) {
        std::cerr << "Error: Could not open pipe to FFmpeg." << std::endl;
        return -1;
    }

    // 4MB Pipe Buffer
    char pipe_buffer[4 * 1024 * 1024];
    setvbuf(pipe, pipe_buffer, _IOFBF, sizeof(pipe_buffer));

    std::cout << "Streaming Video -> udp://" << UDP_IP << ":" << VIDEO_PORT 
              << " (FPS: " << target_fps << ")" << std::endl;

    long long frame_count = 0;
    
    cv::Mat raw_frame, resized_frame, working_frame;
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
    auto next_frame_time = start_time;
    std::chrono::microseconds frame_duration(1000000 / target_fps);

    while (true) {
        // --- Frame Reading ---
        if (!cap.read(raw_frame)) {
            // End of file, loop back
            cap.set(cv::CAP_PROP_POS_FRAMES, 0);
            continue;
        }

        // Resize if needed
        if (raw_frame.cols != TARGET_W || raw_frame.rows != TARGET_H) {
            cv::resize(raw_frame, resized_frame, cv::Size(TARGET_W, TARGET_H));
            working_frame = resized_frame; // Use resized
        } else {
            working_frame = raw_frame; // Use raw directly (careful with modification if not cloning)
        }

        // --- TIMING ---
        auto now = std::chrono::system_clock::now();
        auto duration = now.time_since_epoch();
        double ts_unix = std::chrono::duration<double>(duration).count();

        // --- UDP DATA ---
        int msg_len = snprintf(udp_msg, sizeof(udp_msg), "%lld,%.3f", frame_count, ts_unix);
        sendto(sockfd, (const char *)udp_msg, msg_len, 
               MSG_CONFIRM, (const struct sockaddr *) &servaddr, sizeof(servaddr));

        // --- DRAW TEXT ---
        if (DRAW_TEXT) {
            std::time_t timer = std::chrono::system_clock::to_time_t(now);
            std::tm bt = *std::localtime(&timer);
            auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(duration) % 1000;
            snprintf(ts_readable, sizeof(ts_readable), "%02d:%02d:%02d.%03d", 
                     bt.tm_hour, bt.tm_min, bt.tm_sec, (int)millis.count());

            // Draw
            cv::putText(working_frame, ts_readable, cv::Point(text_x + 3, text_y + 3), fontFace, fontScale, cv::Scalar(0, 0, 0), thickness);
            cv::putText(working_frame, ts_readable, cv::Point(text_x, text_y), fontFace, fontScale, cv::Scalar(255, 255, 255), thickness);
        }

        // --- PIPE WRITE ---
        size_t written = fwrite(working_frame.data, 1, frame_data_size, pipe);
        if (written == 0) break;

        frame_count++;

        // --- FPS Control ---
        next_frame_time += frame_duration;
        std::this_thread::sleep_until(next_frame_time);

        // Status Update
        if (frame_count % 300 == 0) {
             // Calculate actual FPS based on wall clock since start
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
