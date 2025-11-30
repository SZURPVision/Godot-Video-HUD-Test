extends Node2D

# --- Configuration ---
const LOG_PATH = "user://log_file.csv"
const DATA_PORT = 9998 # Port for Side-channel Data
const PING_PORT = 9997 # Sender's Ping Listener Port

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

# System Info Labels
@onready var os_label: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/OS_Label
@onready var cpu_label: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/CPU_Label
@onready var gpu_label: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/GPU_Label

# Latency Labels
@onready var udp_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/UDP_Latency_HBoxContainer/UDP_Latency_Value
@onready var video_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/VideoLatency_HBoxContainer/VideoLatency_Value

# NEW: Specific Latency Labels from your Scene Update
@onready var decoding_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/Decoding_Latency_HBoxContainer/Decoding_Latency_Value
@onready var rendering_latency_val: Label = $HUD_Layer/HUD/InfoPanel/Info_VBoxContainer/Rendering_Latency_HBoxContainer/Rendering_Latency_Value

# --- FFmpeg GDExtension Reference ---
var ffmpeg_stream: FFmpegStream = null

# --- Data Socket ---
var data_udp: PacketPeerUDP
var latest_sender_ts: float = 0.0
var latest_sender_frame: int = 0
var known_sender_ip: String = ""

# --- RTT / Ping-Pong ---
# Moved to separate thread for precision
var latency_thread: Thread
var latency_mutex: Mutex
var latency_exit: bool = false
var shared_network_latency: float = 0.0
var current_network_latency: float = 0.0 # RTT / 2

# --- 3D Control ---
var camera_sensitivity: float = 0.2
var mouse_captured: bool = false
var complex_scene_mesh: MultiMeshInstance3D = null

# --- Data Logging ---
var log_file: FileAccess
var log_timer: float = 0.0
var current_decoding_latency: float = 0.0
var current_rendering_latency: float = 0.0
var current_total_local_latency: float = 0.0
var current_input_latency: float = 0.0
var active_keys: Dictionary = {}

func _ready() -> void:
	# 0. Set System Info in HUD
	os_label.text = "OS: " + OS.get_name() + " (" + OS.get_distribution_name() + ")"
	cpu_label.text = "CPU: " + OS.get_processor_name()
	gpu_label.text = "GPU: " + RenderingServer.get_video_adapter_name()

	# 1. Setup FFmpeg Stream
	if ClassDB.class_exists("FFmpegStream"):
		ffmpeg_stream = FFmpegStream.new()
		add_child(ffmpeg_stream)
		connection_status.text = "FFmpeg Active"
		connection_status.modulate = Color.GREEN
		
	else:
		connection_status.text = "GDExtension Missing!"
		connection_status.modulate = Color.RED

	# 2. Setup Side-Channel UDP (Port 9998)
	data_udp = PacketPeerUDP.new()
	if data_udp.bind(DATA_PORT) == OK:
		print("Listening for Data on Port ", DATA_PORT)
	else:
		print("Failed to bind Data Port ", DATA_PORT)

	# 3. Setup Latency Thread (replaces main-thread ping)
	latency_mutex = Mutex.new()
	latency_thread = Thread.new()
	latency_thread.start(_latency_loop)

	# 4. Setup Logging
	log_file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if log_file:
		# Log System Info for Benchmarking
		log_file.store_line("System Info: OS=%s | CPU=%s | GPU=%s" % [
			OS.get_name(),
			OS.get_processor_name(),
			RenderingServer.get_video_adapter_name()
		])
		# Added Rendering, Total Local, and Network Latency to logs
		log_file.store_line("Timestamp,FPS,DecodingLatency_MS,RenderingLatency_MS,TotalLocalLatency_MS,InputLatency_MS,NetworkLatency_MS,Sender_TS,Sender_Frame")

	_toggle_mouse_capture(true)

	udp_latency_val.text = "Wait..."
	
	_setup_complex_ar_scene()

func _setup_complex_ar_scene() -> void:
	# Create a MultiMeshInstance3D for optimized rendering of ~12,000 faces
	# 1000 Cubes * 12 faces = 12,000 faces
	var ar_world = $AR_Container/SubViewport/AR_World
	
	# Hide the original single block
	if block_mesh:
		block_mesh.visible = false
		
	complex_scene_mesh = MultiMeshInstance3D.new()
	var multimesh = MultiMesh.new()
	
	# Use a simple BoxMesh
	var mesh = BoxMesh.new()
	mesh.size = Vector3(0.5, 0.5, 0.5)
	
	# Try to reuse the wireframe material if possible, otherwise default
	if block_mesh and block_mesh.mesh and block_mesh.mesh.material:
		mesh.material = block_mesh.mesh.material
	else:
		# Fallback material
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0, 1, 1, 0.5) # Cyan transparent
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mesh.material = mat
		
	multimesh.mesh = mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = 1000
	
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	
	for i in range(multimesh.instance_count):
		var t = Transform3D()
		# Random position in a sphere of radius 5
		var pos = Vector3(rng.randf_range(-5, 5), rng.randf_range(-5, 5), rng.randf_range(-5, 5))
		t.origin = pos
		# Random rotation
		t = t.rotated(Vector3(1, 0, 0), rng.randf_range(0, TAU))
		t = t.rotated(Vector3(0, 1, 0), rng.randf_range(0, TAU))
		multimesh.set_instance_transform(i, t)
		
	complex_scene_mesh.multimesh = multimesh
	ar_world.add_child(complex_scene_mesh)
	print("Complex AR Scene Generated: 1000 Instances (~12k faces)")

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
	# --- Poll Data Socket (9998) ---
	while data_udp.get_available_packet_count() > 0:
		var pkt = data_udp.get_packet()
		var detected_ip = data_udp.get_packet_ip()
		
		# Capture Sender IP dynamically and share with thread
		latency_mutex.lock()
		if known_sender_ip == "":
			known_sender_ip = detected_ip
			print("Sender IP Detected: ", known_sender_ip)
		latency_mutex.unlock()
			
		var str_data = pkt.get_string_from_utf8()
		var parts = str_data.split(",")
		if parts.size() >= 2:
			latest_sender_frame = int(parts[0])
			latest_sender_ts = float(parts[1])

	# --- Read Threaded Latency ---
	latency_mutex.lock()
	current_network_latency = shared_network_latency
	latency_mutex.unlock()
	
	udp_latency_val.text = "%.2f ms" % current_network_latency

	# --- UI Updates ---
	time_val.text = Time.get_time_string_from_system()
	fps_val.text = str(Engine.get_frames_per_second())
	
	# --- Calculate Latencies ---
	
	# 1. Rendering Latency: Time taken by Godot's main process loop
	current_rendering_latency = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	rendering_latency_val.text = "%.2f ms" % current_rendering_latency
	
	# 2. Decoding Latency: From C++ Extension
	if ffmpeg_stream:
		var tex = ffmpeg_stream.get_video_texture()
		if tex:
			video_rect.texture = tex
			
		current_decoding_latency = ffmpeg_stream.get_decoding_latency()
		decoding_latency_val.text = "%.2f ms" % current_decoding_latency
	
	# 3. Total Local Latency (Approximate)
	current_total_local_latency = current_decoding_latency + current_rendering_latency
	video_latency_val.text = "%.2f ms" % current_total_local_latency

	# --- HUD & AR Logic ---
	input_latency_val.text = "%.2f ms" % current_input_latency
	var keys_text = ", ".join(active_keys.keys())
	if keys_text == "": keys_text = "None"
	pressed_val.text = keys_text

	if block_mesh:
		block_mesh.rotate_y(0.5 * delta)
		block_mesh.rotate_x(0.2 * delta)
		
	if complex_scene_mesh:
		complex_scene_mesh.rotate_y(0.1 * delta)
		complex_scene_mesh.rotate_x(0.05 * delta)

	# --- Logging ---
	log_timer += delta
	if log_timer >= 0.5:
		_log_data_to_files()
		log_timer = 0.0

func _toggle_mouse_capture(capture: bool):
	mouse_captured = capture
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if capture else Input.MOUSE_MODE_VISIBLE)

func _log_data_to_files():
	if log_file:
		var timestamp = Time.get_unix_time_from_system()
		# Log all metrics including Network Latency
		var line = "%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.3f,%d" % [
			timestamp,
			fps_val.text,
			current_decoding_latency,
			current_rendering_latency,
			current_total_local_latency,
			current_input_latency,
			current_network_latency,
			latest_sender_ts,
			latest_sender_frame
		]
		log_file.store_line(line)

func _exit_tree() -> void:
	if log_file: log_file.close()
	if data_udp: data_udp.close()
	
	# Stop Thread
	latency_mutex.lock()
	latency_exit = true
	latency_mutex.unlock()
	
	if latency_thread.is_started():
		latency_thread.wait_to_finish()
		
	if ffmpeg_stream:
		ffmpeg_stream.free()

func _latency_loop() -> void:
	var udp = PacketPeerUDP.new()
	udp.bind(0)
	var last_ping_sent = 0
	var ping_interval_us = 1000000 # 1 second
	
	print("Latency Thread Started")
	
	while true:
		# Check exit condition and get IP
		latency_mutex.lock()
		if latency_exit:
			latency_mutex.unlock()
			break
		var target_ip = known_sender_ip
		latency_mutex.unlock()
		
		if target_ip != "":
			var now = Time.get_ticks_usec()
			
			# Send PING
			if now - last_ping_sent >= ping_interval_us:
				udp.set_dest_address(target_ip, PING_PORT)
				udp.put_packet("PING".to_utf8_buffer())
				last_ping_sent = now
			
			# Poll for PONG
			while udp.get_available_packet_count() > 0:
				udp.get_packet() # Discard payload
				var recv_time = Time.get_ticks_usec()
				# RTT = recv_time - sent_time. sent_time is approximately last_ping_sent if we assume 1 outstanding ping.
				# However, if Pings are fast or delayed, matching them is better.
				# Given the 1s interval, we can assume the packet corresponds to the last sent ping.
				var rtt_us = recv_time - last_ping_sent
				
				latency_mutex.lock()
				shared_network_latency = (rtt_us / 2.0) / 1000.0 # ms
				latency_mutex.unlock()
		
		# Sleep to prevent CPU hogging (approx 1ms)
		OS.delay_msec(1)
	
	udp.close()
	print("Latency Thread Stopped")
