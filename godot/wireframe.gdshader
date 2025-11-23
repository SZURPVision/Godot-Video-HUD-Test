// Reference from https://godotshaders.com/shader/wireframe-shader-godot-4-0/
shader_type spatial;
// "cull_disabled" lets you see the wires on the back of the object. 
// "unshaded" ensures the cyan is bright and flat (ignoring lights).
render_mode cull_disabled, unshaded;

uniform vec4 albedo : source_color = vec4(0.0, 1.0, 1.0, 1.0); // Default Cyan
uniform float wire_width : hint_range(0.0, 40.0) = 1.0;
uniform float wire_smoothness : hint_range(0.0, 0.1) = 0.01;

varying vec3 barys;

void vertex() {
	int index = VERTEX_ID % 3;
	switch (index) {
		case 0:
			barys = vec3(1.0, 0.0, 0.0);
			break;
		case 1:
			barys = vec3(0.0, 1.0, 0.0);
			break;
		case 2:
			barys = vec3(0.0, 0.0, 1.0);
			break;
	}
}

void fragment() {
	// Calculate the derivative (rate of change) of the barycentric coords
	vec3 deltas = fwidth(barys);
	
	// Calculate the edge factor
	vec3 barys_s = smoothstep(deltas * wire_width - wire_smoothness, deltas * wire_width + wire_smoothness, barys);
	float wires = min(barys_s.x, min(barys_s.y, barys_s.z));

	// --- KEY CHANGES ---
	
	// 1. Set Color to Cyan
	ALBEDO = vec3(0.0, 1.0, 1.0); 
	
	// 2. Use 'wires' to control Alpha. 
	// 'wires' is 1.0 at the center of the face, and 0.0 at the edge.
	// We want 0.0 alpha at the center, and 1.0 alpha at the edge.
	ALPHA = ( 1.0 - wires ) * 0.5;
}