#!/usr/bin/env python3
import os
import re
import subprocess
import sys

def find_metadata_file(bag_path):
    """Locates the metadata.yaml file associated with the input path."""
    bag_path = os.path.abspath(bag_path)
    if not os.path.exists(bag_path):
        print(f"❌ Error: Path '{bag_path}' does not exist.")
        return None

    if os.path.isdir(bag_path):
        metadata_file = os.path.join(bag_path, 'metadata.yaml')
        if os.path.exists(metadata_file):
            return metadata_file
    elif os.path.isfile(bag_path):
        if os.path.basename(bag_path) == 'metadata.yaml':
            return bag_path
        # If they pointed directly to a db3 or mcap file inside the folder
        parent_dir = os.path.dirname(bag_path)
        metadata_file = os.path.join(parent_dir, 'metadata.yaml')
        if os.path.exists(metadata_file):
            return metadata_file

    print(f"❌ Error: Could not find 'metadata.yaml' inside '{bag_path}'")
    return None

def parse_metadata(metadata_path):
    """Parses starting time and duration from metadata.yaml using fallback text parsing."""
    duration_ns = None
    starting_time_ns = None

    try:
        with open(metadata_path, 'r') as f:
            content = f.read()

        lines = content.splitlines()
        for i, line in enumerate(lines):
            # Parse duration block
            if 'duration:' in line:
                if i + 1 < len(lines) and 'nanoseconds:' in lines[i+1]:
                    match = re.search(r'nanoseconds:\s*(\d+)', lines[i+1])
                    if match:
                        duration_ns = int(match.group(1))
            # Parse starting_time block
            if 'starting_time:' in line:
                if i + 1 < len(lines) and 'nanoseconds_since_epoch:' in lines[i+1]:
                    match = re.search(r'nanoseconds_since_epoch:\s*(\d+)', lines[i+1])
                    if match:
                        starting_time_ns = int(match.group(1))
    except Exception as e:
        print(f"❌ Error reading metadata: {e}")
        return None, None

    return starting_time_ns, duration_ns

def main():
    print("==================================================")
    print("         ROS 2 Bag Cropping Tool (Offline)        ")
    print("==================================================")

    # 1. Ask for input bag folder
    while True:
        input_bag = input("📁 Enter input ROS 2 bag path: ").strip()
        if not input_bag:
            continue
        
        metadata_file = find_metadata_file(input_bag)
        if metadata_file:
            input_bag_abs = os.path.abspath(input_bag)
            if os.path.isfile(input_bag_abs):
                input_bag_abs = os.path.dirname(input_bag_abs)
            break
        print("Please enter a valid path.\n")

    # 2. Extract starting time and duration
    start_ns, duration_ns = parse_metadata(metadata_file)
    if not start_ns or not duration_ns:
        print("❌ Failed to parse required timing information from metadata.yaml.")
        sys.exit(1)

    duration_sec = duration_ns / 1e9
    print(f"\n✅ Bag Loaded Successfully!")
    print(f"⏱️  Total Duration: {duration_sec:.3f} seconds")
    print(f"📅 Start Epoch: {start_ns} ns\n")

    # 3. Ask for start offset
    while True:
        try:
            start_input = input("✂️  Enter crop START time in seconds (default: 0.0): ").strip()
            if not start_input:
                crop_start_sec = 0.0
            else:
                crop_start_sec = float(start_input)

            if crop_start_sec < 0 or crop_start_sec > duration_sec:
                print(f"❌ Start time must be between 0.0 and {duration_sec:.3f} seconds.")
                continue
            break
        except ValueError:
            print("❌ Invalid number. Please enter a float or integer.")

    # 4. Ask for end offset
    while True:
        try:
            end_input = input(f"✂️  Enter crop END time in seconds (default: {duration_sec:.3f}): ").strip()
            if not end_input:
                crop_end_sec = duration_sec
            else:
                crop_end_sec = float(end_input)

            if crop_end_sec <= crop_start_sec or crop_end_sec > duration_sec:
                print(f"❌ End time must be greater than start ({crop_start_sec:.3f}) and less than {duration_sec:.3f} seconds.")
                continue
            break
        except ValueError:
            print("❌ Invalid number. Please enter a float or integer.")

    # 5. Ask for output bag folder name
    default_output = os.path.basename(input_bag_abs.rstrip('/')) + "_cropped"
    output_bag = input(f"💾 Enter output bag name/path (default: '{default_output}'): ").strip()
    if not output_bag:
        output_bag = default_output

    output_bag_abs = os.path.abspath(output_bag)

    # 6. Calculate absolute nanosecond values
    crop_start_ns = start_ns + int(crop_start_sec * 1e9)
    crop_end_ns = start_ns + int(crop_end_sec * 1e9)

    # 7. Generate YAML config on the fly
    config_filename = "crop_config_temp.yaml"
    yaml_content = f"""output_bags:
  - uri: {output_bag_abs}
    all_topics: true
    start_time_ns: {crop_start_ns}
    end_time_ns: {crop_end_ns}
"""

    try:
        with open(config_filename, "w") as f:
            f.write(yaml_content)
        print(f"\n📝 Generated temporary config file: {config_filename}")
        
        # 8. Run ROS 2 converter
        cmd = ["ros2", "bag", "convert", "-i", input_bag_abs, "-o", config_filename]
        print(f"🚀 Running converter command: {' '.join(cmd)}\n")
        
        result = subprocess.run(cmd)
        if result.returncode == 0:
            print(f"\n🎉 Success! Cropped bag created at: {output_bag_abs}")
        else:
            print(f"\n❌ Error: 'ros2 bag convert' execution failed with exit code {result.returncode}.")

    except Exception as e:
        print(f"\n❌ An unexpected system error occurred: {e}")
    finally:
        # 9. Clean up
        if os.path.exists(config_filename):
            os.remove(config_filename)
            print(f"🧹 Cleaned up temporary config file: {config_filename}")

if __name__ == "__main__":
    main()