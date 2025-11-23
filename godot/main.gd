extends Node2D

# --- Configuration ---
const UDP_PORT = 9999
const HEADER_SIZE = 11 # [ID, Chunk, Total, Time(8B)]

# --- Log Files ---
const LOG_PATH = "user://log_file.csv"

# --- Node References ---
@onready var video_rect: TextureRect = $LiveTextureRect
@onready var ar_container: SubViewportContainer = $AR_Container
@onready var ar_viewport: SubViewport = $AR_Container/SubViewport

# 3D References
@onready var ar_camera: Camera3D = $AR_Container/SubViewport/AR_World/Camera3D
@onready var block_mesh: MeshInstance3D = $AR_Container/SubViewport/AR_World/Block

# HUD References
@onready var fps_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/FPS_HBoxContainer/FPS_Value
@onready var time_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/Time_HBoxContainer/Time_Value
@onready var input_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/InputLatency_HBoxContainer/InputLatency_Value
@onready var pressed_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/Pressed_HBoxContainer/Pressed_Value
@onready var connection_status: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/ConnectionStatus
@onready var video_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/VideoLatency_HBoxContainer/VideoLatency_Value
@onready var udp_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/UDP_Latency_HBoxContainer/UDP_Latency_Value

# --- Networking ---
var udp: PacketPeerUDP
var thread: Thread
var mutex: Mutex
var exit_thread: bool = false
var frame_buffer: Dictionary = {}
var ready_image_queue: Array = [] # Stores decoded Images (CPU data)

# --- 3D Control ---
var camera_sensitivity: float = 0.2
var mouse_captured: bool = false

# --- Data Logging ---
var log_file: FileAccess
var log_timer: float = 0.0
var current_video_latency: float = 0.0
var current_udp_latency: float = 0.0
var current_input_latency: float = 0.0
var active_keys: Dictionary = {}

func _ready() -> void:
	# 1. Setup UDP
	udp = PacketPeerUDP.new()
	if udp.bind(UDP_PORT) != OK:
		connection_status.text = "UDP Bind Error"
		connection_status.modulate = Color.RED
	else:
		connection_status.text = "Waiting..."
		connection_status.modulate = Color.YELLOW
	
	# Increase Buffer if possible (helps with 165Hz bursts)
	# udp.set_dest_address("127.0.0.1", 9999) 
	
	mutex = Mutex.new()
	thread = Thread.new()
	thread.start(_udp_thread_function)

	# 2. Setup Logging
	log_file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if log_file:
		log_file.store_line("Timestamp,FPS,UDPLatency_MS,VideoProcLatency_MS,InputLatency_MS")
		print("Log path: ", ProjectSettings.globalize_path(LOG_PATH))

	_toggle_mouse_capture(true)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle_mouse_capture(not mouse_captured)

	if mouse_captured and event is InputEventMouseMotion:
		if ar_camera:
			ar_camera.rotate_y(deg_to_rad(-event.relative.x * camera_sensitivity))
			var new_x = ar_camera.rotation.x - deg_to_rad(event.relative.y * camera_sensitivity)
			ar_camera.rotation.x = clamp(new_x, deg_to_rad(-90), deg_to_rad(90))

	if event is InputEventKey:
		var key_name = OS.get_keycode_string(event.keycode)
		if event.pressed:
			active_keys[key_name] = true
		else:
			active_keys.erase(key_name)
	
	current_input_latency = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0

func _process(delta: float) -> void:
	# --- UI Updates ---
	time_val.text = Time.get_time_string_from_system()
	fps_val.text = str(Engine.get_frames_per_second())
	
	# --- Texture Update (Main Thread) ---
	mutex.lock()
	if not ready_image_queue.is_empty():
		# Get the MOST RECENT frame (skips lags)
		var frame_data = ready_image_queue.pop_back()
		ready_image_queue.clear() 
		mutex.unlock()
		
		# High Performance Update
		if video_rect.texture:
			video_rect.texture.update(frame_data["image"])
		else:
			video_rect.texture = ImageTexture.create_from_image(frame_data["image"])
		
		# Update Stats
		current_udp_latency = frame_data["udp_latency"]
		var render_time = Time.get_unix_time_from_system() * 1000.0
		current_video_latency = render_time - frame_data["arrival_time"]
		
		udp_latency_val.text = "%.1f ms" % current_udp_latency
		video_latency_val.text = "%.1f ms" % current_video_latency
		
		connection_status.text = "Connected"
		connection_status.modulate = Color.GREEN
	else:
		mutex.unlock()

	input_latency_val.text = "%.2f ms" % current_input_latency
	var keys_text = ", ".join(active_keys.keys())
	if keys_text == "": keys_text = "None"
	pressed_val.text = keys_text

	if block_mesh:
		block_mesh.rotate_y(0.5 * delta)
		block_mesh.rotate_x(0.2 * delta)

	# --- Logging ---
	log_timer += delta
	if log_timer >= 0.5:
		_log_data_to_files()
		log_timer = 0.0

func _udp_thread_function() -> void:
	while not exit_thread:
		# 1. BURST READ: Drain the entire socket buffer
		var packet_count = udp.get_available_packet_count()
		if packet_count == 0:
			OS.delay_usec(100) # Sleep 0.1ms
			continue
			
		for i in range(packet_count):
			var pkt = udp.get_packet()
			if pkt.size() <= HEADER_SIZE: continue
			
			var frame_id = pkt[0]
			var chunk_idx = pkt[1]
			var total_chunks = pkt[2]
			var sent_time = pkt.slice(3, 11).decode_double(0)
			var payload = pkt.slice(11)
			var arrival_time = Time.get_unix_time_from_system() * 1000.0
			
			mutex.lock()
			
			# --- Frame Assembly Logic ---
			var is_new_session = false
			if frame_buffer.has(frame_id):
				if abs(sent_time - frame_buffer[frame_id]["sent_time"]) > 0.1:
					is_new_session = true
			
			if not frame_buffer.has(frame_id) or is_new_session:
				frame_buffer[frame_id] = {
					"chunks": {}, "count": 0, "total": total_chunks, 
					"sent_time": sent_time, "arrival_time": arrival_time
				}
			
			var entry = frame_buffer[frame_id]
			if not entry["chunks"].has(chunk_idx):
				entry["chunks"][chunk_idx] = payload
				entry["count"] += 1
			
			# --- Check Completion ---
			if entry["count"] >= entry["total"]:
				var final_data = _assemble_frame_bytes(entry)
				var info = {
					"sent_time": entry["sent_time"], 
					"arrival_time": entry["arrival_time"]
				}
				frame_buffer.erase(frame_id)
				mutex.unlock() 
				
				# 2. FIX: PASS MUTEX & QUEUE AS ARGUMENTS
				# This prevents "null value" errors if the Node dies
				WorkerThreadPool.add_task(
					_decode_task.bind(final_data, info, mutex, ready_image_queue)
				)
			else:
				mutex.unlock()
		
		# Cleanup Logic (Safe cleanup of old frames)
		mutex.lock()
		if frame_buffer.size() > 5:
			frame_buffer.erase(frame_buffer.keys()[0])
		mutex.unlock()

# --- Static-like Task (Runs on background thread) ---
func _decode_task(data: PackedByteArray, info: Dictionary, mutex_ref: Mutex, queue_ref: Array):
	if data.size() < 2: return
	
	var img = Image.new()
	var err = img.load_jpg_from_buffer(data)
	
	if err == OK:
		# Use the PASSED references, never "self"
		mutex_ref.lock()
		queue_ref.append({
			"image": img, 
			"udp_latency": info["arrival_time"] - info["sent_time"],
			"arrival_time": info["arrival_time"]
		})
		mutex_ref.unlock()

func _assemble_frame_bytes(entry: Dictionary) -> PackedByteArray:
	var full_data = PackedByteArray()
	for i in range(entry["total"]):
		if entry["chunks"].has(i):
			full_data.append_array(entry["chunks"][i])
	return full_data

func _toggle_mouse_capture(capture: bool):
	mouse_captured = capture
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if capture else Input.MOUSE_MODE_VISIBLE)

func _log_data_to_files():
	if log_file:
		var timestamp = Time.get_unix_time_from_system()
		var line = "%s,%s,%.2f,%.2f,%.2f" % [
			timestamp,
			fps_val.text,
			current_udp_latency,
			current_video_latency,
			current_input_latency
		]
		log_file.store_line(line)

func _exit_tree() -> void:
	exit_thread = true
	if thread and thread.is_started(): thread.wait_to_finish()
	if udp: udp.close()
	if log_file: log_file.close()