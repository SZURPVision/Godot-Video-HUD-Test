extends Node2D

# --- Configuration ---
const UDP_PORT = 9999
const HEADER_SIZE = 11 # 3 bytes (Info) + 8 bytes (Double Timestamp)

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

# Latency Labels
@onready var video_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/VideoLatency_HBoxContainer/VideoLatency_Value
@onready var udp_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/UDP_Latency_HBoxContainer/UDP_Latency_Value

# --- Networking ---
var udp: PacketPeerUDP
var thread: Thread
var mutex: Mutex
var exit_thread: bool = false
var texture_queue: Array = []
var frame_buffer: Dictionary = {}

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
		connection_status.text = "UDP绑定错误"
		connection_status.modulate = Color.RED
	else:
		connection_status.text = "等待连接..."
		connection_status.modulate = Color.YELLOW
	
	mutex = Mutex.new()
	thread = Thread.new()
	thread.start(_udp_thread_function)

	_setup_wireframe_visuals()

	# 2. Setup Video Log (FPS, UDP Latency, Video Proc Latency)
	log_file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if log_file:
		log_file.store_line("Timestamp,FPS,UDPLatency_MS,VideoProcLatency_MS,InputLatency_MS")
		print("Log: ", ProjectSettings.globalize_path(LOG_PATH))

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
	time_val.text = Time.get_time_string_from_system()
	fps_val.text = str(Engine.get_frames_per_second())
	
	mutex.lock()
	if not texture_queue.is_empty():
		var frame_data = texture_queue.pop_back() 
		texture_queue.clear() 
		
		video_rect.texture = frame_data["texture"]
		
		current_udp_latency = frame_data["udp_latency"]
		var render_time = Time.get_unix_time_from_system() * 1000.0
		current_video_latency = render_time - frame_data["arrival_time"]
		
		if udp_latency_val:
			udp_latency_val.text = "%.1f ms" % current_udp_latency
		video_latency_val.text = "%.1f ms" % current_video_latency
		
		connection_status.text = "已连接"
		connection_status.modulate = Color.GREEN
	mutex.unlock()

	input_latency_val.text = "%.2f ms" % current_input_latency
	var keys_text = ", ".join(active_keys.keys())
	if keys_text == "": keys_text = "None"
	pressed_val.text = keys_text

	if block_mesh:
		block_mesh.rotate_y(0.5 * delta)
		block_mesh.rotate_x(0.2 * delta)

	# Log Data
	log_timer += delta
	if log_timer >= 0.5:
		_log_data_to_files(keys_text)
		log_timer = 0.0

func _udp_thread_function() -> void:
	while not exit_thread:
		if udp.get_available_packet_count() > 0:
			var pkt = udp.get_packet()
			if pkt.size() <= HEADER_SIZE: continue
			
			var frame_id = pkt[0]
			var chunk_idx = pkt[1]
			var total_chunks = pkt[2]
			var timestamp_bytes = pkt.slice(3, 11)
			var sent_time = timestamp_bytes.decode_double(0)
			var payload = pkt.slice(11)
			var arrival_time = Time.get_unix_time_from_system() * 1000.0
			
			# --- CRITICAL SECTION START ---
			mutex.lock()
			
			# 1. Manage Frame Buffer (Same as before)
			var is_new_session = false
			if frame_buffer.has(frame_id):
				var old_ts = frame_buffer[frame_id]["sent_time"]
				if abs(sent_time - old_ts) > 0.1:
					is_new_session = true
			
			if not frame_buffer.has(frame_id) or is_new_session:
				frame_buffer[frame_id] = {
					"chunks": {}, 
					"count": 0, 
					"total": total_chunks, 
					"sent_time": sent_time,
					"arrival_time": arrival_time
				}
			
			var entry = frame_buffer[frame_id]
			if not entry["chunks"].has(chunk_idx):
				entry["chunks"][chunk_idx] = payload
				entry["count"] += 1
			
			# 2. Check for Completion
			var ready_frame_data = null # Store data to process outside lock
			var ready_frame_info = {}
			
			if entry["count"] >= entry["total"]:
				# Frame is complete! Extract data NOW while locked
				ready_frame_data = _assemble_frame_bytes(entry)
				ready_frame_info = {
					"sent_time": entry["sent_time"],
					"arrival_time": entry["arrival_time"]
				}
				frame_buffer.erase(frame_id) # Clean up immediately
			
			# Cleanup old frames
			if frame_buffer.size() > 5:
				frame_buffer.erase(frame_buffer.keys()[0])
				
			mutex.unlock() 
			# --- CRITICAL SECTION END ---
			
			# 3. Heavy Processing (OUTSIDE LOCK)
			if ready_frame_data:
				_process_and_queue_image(ready_frame_data, ready_frame_info)
				
		else:
			OS.delay_msec(1)
			
# Helper to assemble bytes (Must be called inside lock or with local data)
func _assemble_frame_bytes(entry: Dictionary) -> PackedByteArray:
	var full_data = PackedByteArray()
	for i in range(entry["total"]):
		if entry["chunks"].has(i):
			full_data.append_array(entry["chunks"][i])
	return full_data

# Helper to decode and queue (called OUTSIDE lock)
func _process_and_queue_image(data: PackedByteArray, info: Dictionary):
	# Basic JPEG validation
	if data.size() < 2 or data[0] != 0xFF or data[1] != 0xD8:
		return

	var img = Image.new()
	# EXPENSIVE CPU OPERATION (Now safe to run in parallel)
	var err = img.load_jpg_from_buffer(data)
	
	if err == OK:
		# EXPENSIVE GPU OPERATION (Safe in Godot 4, but keep outside lock)
		var tex = ImageTexture.create_from_image(img)
		
		var udp_lat = info["arrival_time"] - info["sent_time"]
		
		# --- BRIEF LOCK TO PUSH TO QUEUE ---
		mutex.lock()
		texture_queue.append({
			"texture": tex, 
			"udp_latency": udp_lat, 
			"arrival_time": info["arrival_time"]
		})
		mutex.unlock()

func _decode_and_queue(fid: int):
	if not frame_buffer.has(fid): return

	var entry = frame_buffer[fid]
	var full_data = PackedByteArray()
	
	var is_valid = true
	for i in range(entry["total"]):
		if entry["chunks"].has(i):
			full_data.append_array(entry["chunks"][i])
		else:
			is_valid = false
			break
			
	if not is_valid:
		frame_buffer.erase(fid)
		return

	if full_data.size() < 2 or full_data[0] != 0xFF or full_data[1] != 0xD8:
		frame_buffer.erase(fid)
		return

	var img = Image.new()
	var err = img.load_jpg_from_buffer(full_data)
	
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		
		# Network Latency = Arrival - Sent
		var udp_lat = entry["arrival_time"] - entry["sent_time"]
		
		texture_queue.append({
			"texture": tex, 
			"udp_latency": udp_lat, 
			"arrival_time": entry["arrival_time"]
		})
	
	frame_buffer.erase(fid)

func _setup_wireframe_visuals():
	ar_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ar_viewport.transparent_bg = true
	
	if block_mesh:
		var m = ArrayMesh.new()
		var verts = PackedVector3Array([
			Vector3(-1,-1,-1), Vector3(1,-1,-1), Vector3(1,1,-1), Vector3(-1,1,-1),
			Vector3(-1,-1,1), Vector3(1,-1,1), Vector3(1,1,1), Vector3(-1,1,1)
		])
		var indices = PackedInt32Array([
			0,1, 1,2, 2,3, 3,0, 
			4,5, 5,6, 6,7, 7,4, 
			0,4, 1,5, 2,6, 3,7 
		])
		
		var arrays = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_INDEX] = indices
		
		m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		
		var mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color.CYAN
		mat.vertex_color_use_as_albedo = true
		
		block_mesh.mesh = m
		block_mesh.material_override = mat
		block_mesh.scale = Vector3(0.5, 0.5, 0.5)

func _toggle_mouse_capture(capture: bool):
	mouse_captured = capture
	if capture:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _log_data_to_files(keys_str: String):
	var timestamp = Time.get_unix_time_from_system()
	
	# 1. Log Video Stats
	if log_file:
		var line_video = "%s,%s,%.2f,%.2f,%.2f" % [
			timestamp,
			fps_val.text,
			current_udp_latency,
			current_video_latency,
			current_input_latency
		]
		log_file.store_line(line_video)

func _exit_tree() -> void:
	exit_thread = true
	if thread and thread.is_started(): thread.wait_to_finish()
	if udp: udp.close()
	if log_file: log_file.close()
