import cv2
import socket
import time
import math
import struct
import concurrent.futures
from refresh_rate_getter import get_monitor_refresh_rate

# --- Configuration ---
UDP_IP = "127.0.0.1"
UDP_PORT = 9999
VIDEO_FILE = "test.avi" 
TARGET_FPS = get_monitor_refresh_rate()
JPEG_QUALITY = 50 
MAX_PAYLOAD = 60000 

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# IMPORTANT: Increase Send Buffer for high FPS
sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)

cap = cv2.VideoCapture(VIDEO_FILE)

# Worker function for Thread Pool
def process_and_send(frame, frame_id):
    try:
        # 1. Encode (Heavy CPU - Released GIL)
        _, buffer = cv2.imencode('.jpg', frame, [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY])
        data = buffer.tobytes()
        
        # 2. Packet Headers
        total_size = len(data)
        num_chunks = math.ceil(total_size / MAX_PAYLOAD)
        timestamp_ms = time.time() * 1000.0
        header_format = '=BBBd'
        
        # 3. Send Chunks
        for i in range(num_chunks):
            start = i * MAX_PAYLOAD
            end = min(start + MAX_PAYLOAD, total_size)
            chunk = data[start:end]
            header = struct.pack(header_format, frame_id, i, num_chunks, timestamp_ms)
            sock.sendto(header + chunk, (UDP_IP, UDP_PORT))
    except Exception as e:
        print(e)

# Create Thread Pool
executor = concurrent.futures.ThreadPoolExecutor(max_workers=3)
frame_counter = 0
interval = 1.0 / TARGET_FPS

print(f"Streaming @ {TARGET_FPS}Hz...")

try:
    while True:
        start_time = time.time()
        
        ret, frame = cap.read()
        if not ret:
            cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
            continue
        
        # Resize on Main Thread (Fast enough)
        frame = cv2.resize(frame, (1920, 1080))
        
        # Offload Encoding & Sending to Pool
        fid = frame_counter % 256
        executor.submit(process_and_send, frame.copy(), fid)
        
        frame_counter += 1
        
        # Precision Timing
        elapsed = time.time() - start_time
        sleep_time = interval - elapsed
        if sleep_time > 0:
            time.sleep(sleep_time)
            
        if frame_counter % 60 == 0:
            print(f"\rFPS: {1/(elapsed+0.001):.1f} (Threads: {executor._work_queue.qsize()})", end="")

except KeyboardInterrupt:
    executor.shutdown(wait=False)
    cap.release()
    sock.close()
    