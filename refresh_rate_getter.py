import platform
import subprocess
import re
def get_monitor_refresh_rate():
    """
    Detects the refresh rate of the primary monitor.
    Returns: int (e.g., 60, 144, 165)
    Defaults to 60 if detection fails.
    """
    current_os = platform.system()
    
    try:
        if current_os == "Windows":
            # Use WMIC to get the current refresh rate
            cmd = "wmic PATH Win32_VideoController get CurrentRefreshRate"
            output = subprocess.check_output(cmd, shell=True).decode()
            # Parse the number (e.g., "165")
            rates = [int(s) for s in output.split() if s.isdigit()]
            if rates:
                return max(rates) # Return the highest if multiple (e.g. multi-monitor)
                
        elif current_os == "Linux":
            # Use xrandr to find the active mode (marked with *)
            cmd = "xrandr"
            output = subprocess.check_output(cmd, shell=True).decode()
            # Regex to find the rate with an asterisk (e.g., "165.00*")
            match = re.search(r'\s(\d+\.\d+)\*', output)
            if match:
                return round(float(match.group(1)))
                
        elif current_os == "Darwin": # macOS
            # macOS usually handles composition well, but purely for info:
            cmd = "system_profiler SPDisplaysDataType"
            output = subprocess.check_output(cmd, shell=True).decode()
            # Look for "Resolution: xxxx x xxxx @ xx Hz"
            match = re.search(r'@ (\d+) Hz', output)
            if match:
                return int(match.group(1))

    except Exception as e:
        print(f"Warning: Could not detect refresh rate ({e}). Defaulting to 60Hz.")
    
    return 60 # Safe default