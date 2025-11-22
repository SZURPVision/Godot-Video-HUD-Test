import cv2
import socket
import time
import math
import struct

# --- Configuration ---
UDP_IP = "127.0.0.1"
UDP_PORT = 9999
VIDEO_FILE = "test.avi"
TARGET_WIDTH = 1920
TARGET_HEIGHT = 1080
JPEG_QUALITY = 50

# Packet Logic
# Header: [Frame ID (1B)] [Chunk ID (1B)] [Total Chunks (1B)] [Timestamp Double (8B)]
# Use '=' to force standard size (11 bytes) with NO PADDING.
HEADER_FORMAT = '=BBBd' 
MAX_PAYLOAD = 60000 

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
cap = cv2.VideoCapture(VIDEO_FILE)

if not cap.isOpened():
    print(f"Error: Could not open {VIDEO_FILE}")
    exit()

# Playback control
fps = 165
delay = 1.0 / fps
frame_counter = 0

print(f"Streaming @{fps}Hz 1080p to {UDP_IP}:{UDP_PORT}")
print("Press Ctrl+C to stop.")

try:
    while True:
        start_time = time.time()
        
        ret, frame = cap.read()
        if not ret:
            cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
            continue

        # 1. Resize
        frame = cv2.resize(frame, (TARGET_WIDTH, TARGET_HEIGHT))

        # 2. Compress
        _, buffer = cv2.imencode('.jpg', frame, [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY])
        data = buffer.tobytes()
        
        # 3. Fragment
        total_size = len(data)
        num_chunks = math.ceil(total_size / MAX_PAYLOAD)
        frame_id = frame_counter % 256
        
        # High-precision timestamp (Unix Epoch in milliseconds)
        timestamp_ms = time.time() * 1000.0
        
        for i in range(num_chunks):
            start = i * MAX_PAYLOAD
            end = min(start + MAX_PAYLOAD, total_size)
            chunk_data = data[start:end]
            
            # Pack Header: '=' ensures no padding bytes are added
            header = struct.pack(HEADER_FORMAT, frame_id, i, num_chunks, timestamp_ms)
            
            sock.sendto(header + chunk_data, (UDP_IP, UDP_PORT))

        frame_counter += 1
        
        # Precise Loop Timing
        process_time = time.time() - start_time
        sleep_time = max(0, delay - process_time)
        time.sleep(sleep_time)

except KeyboardInterrupt:
    cap.release()
    sock.close()