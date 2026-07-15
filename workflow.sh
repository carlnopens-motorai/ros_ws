#!/usr/bin/env bash

# ==============================================================================
#  CONFIGURABLE VARIABLES (Adjust these to match your setup)
# ==============================================================================
ROS2_CONTAINER="ros_ws_devcontainer-ros-dev-1"       # Name/ID of your ROS2 devcontainer
KALIBR_CONTAINER="kind_banach"                       # Name/ID of your ROS1/Kalibr container

# Path to your crop script INSIDE the ROS2 container
ROS2_CROP_SCRIPT="/workspace/crop_bag.py"

# Container path configurations
# (Assumes your host's data directory is mounted to "/data" in both containers)
ROS2_DATA_DIR="/data"                   
KALIBR_DATA_DIR="/data"                 

# Host path configurations
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# --- SMART PATH AUTO-DETECTION ---
# Resolves whether the script is run from the root directory or inside the "data" folder
if [[ "$(basename "$SCRIPT_DIR")" == "data" ]]; then
    HOST_DATA_DIR="${SCRIPT_DIR}"
else
    if [ -d "${SCRIPT_DIR}/data" ]; then
        HOST_DATA_DIR="${SCRIPT_DIR}/data"
    else
        HOST_DATA_DIR="${SCRIPT_DIR}"
    fi
fi

RESULTS_DIR="${HOST_DATA_DIR}/results"
# ==============================================================================

# Terminal Colors for UX
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Active state tracking
ACTIVE_BAG_HOST=""        # Keeps track of the file we are currently working with on the Host
ACTIVE_BAG_TYPE=""        # 'mcap' (ROS2) or 'bag' (ROS1)

# Ensure directories exist
mkdir -p "${HOST_DATA_DIR}"
mkdir -p "${RESULTS_DIR}"

# --- HELPER FUNCTIONS ---

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# give docker access to the X server for GUI applications (use -e DISPLAY=$DISPLAY in docker run/exec)
xhost +local:docker

# Checks if a container is running, stopped, or missing using docker inspect
check_container() {
    local container_name=$1
    local state
    state=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "missing"
    elif [ "$state" == "true" ]; then
        echo "running"
    else
        echo "stopped"
    fi
}

# Verifies and starts containers if they are stopped
ensure_containers_running() {
    for container in "$ROS2_CONTAINER" "$KALIBR_CONTAINER"; do
        status=$(check_container "$container")
        if [ "$status" = "stopped" ]; then
            log_warn "Container '$container' is stopped. Attempting to start..."
            docker start "$container" >/dev/null
        elif [ "$status" = "missing" ]; then
            log_error "Container '$container' does not exist. Please check container name or run status."
            exit 1
        fi
    done
}

# Interactive file selector
select_file() {
    local extension=$1
    local prompt_msg=$2
    
    if [ ! -d "$HOST_DATA_DIR" ]; then
        log_error "Host data directory does not exist: $HOST_DATA_DIR"
        return 1
    fi

    cd "$HOST_DATA_DIR" || { log_error "Failed to access host data directory: $HOST_DATA_DIR"; return 1; }
    
    # Cleaned find command to search up to 3 levels deep for mcap/bag files
    IFS=$'\n' files=($(find . -maxdepth 3 -type f -name "*${extension}" | sed 's|^\./||'))
    
    if [ ${#files[@]} -eq 0 ]; then
        log_warn "No files ending with '${extension}' found in: $(pwd)"
        log_info "Here are the files currently present in this directory:"
        echo "--------------------------------------------------------"
        ls -F | head -n 15
        echo "--------------------------------------------------------"
        cd "$SCRIPT_DIR"
        return 1
    fi

    echo -e "${YELLOW}${prompt_msg}${NC}"
    select opt in "${files[@]}" "Cancel/Manual Input"; do
        if [ "$opt" = "Cancel/Manual Input" ]; then
            cd "$SCRIPT_DIR"
            return 1
        elif [ -n "$opt" ]; then
            ACTIVE_BAG_HOST="${HOST_DATA_DIR}/${opt}"
            cd "$SCRIPT_DIR"
            return 0
        else
            echo "Invalid selection. Please try again."
        fi
    done
}

# Display Status Header
show_status() {
    clear
    echo "================================================================="
    echo "                 ROS WORKFLOW ORCHESTRATOR                      "
    echo "================================================================="
    echo -e "ROS2 Container   : $(check_container $ROS2_CONTAINER)"
    echo -e "Kalibr Container : $(check_container $KALIBR_CONTAINER)"
    if [ -n "$ACTIVE_BAG_HOST" ]; then
        echo -e "Active Bag File  : ${GREEN}$(basename "$ACTIVE_BAG_HOST")${NC} (${ACTIVE_BAG_TYPE^^})"
    else
        echo -e "Active Bag File  : ${RED}None selected yet${NC}"
    fi
    echo -e "Host Search Path : ${CYAN}${HOST_DATA_DIR}${NC}"
    echo "================================================================="
    echo ""
}

# --- WORKFLOW STEPS ---

# Step 1: Select/Play Bag
step_play_bag() {
    show_status
    log_info "Step 1: Inspect Bag in RViz"
    
    if [ -z "$ACTIVE_BAG_HOST" ] || [ "$ACTIVE_BAG_TYPE" != "mcap" ]; then
        select_file ".mcap" "Select a ROS2 MCAP bag to play:"
        if [ $? -ne 0 ]; then
            log_warn "No MCAP file selected. Skipping play."
            read -p "Press Enter to continue..."
            return
        fi
        ACTIVE_BAG_TYPE="mcap"
    else
        read -p "Use currently active file '$(basename "$ACTIVE_BAG_HOST")'? [Y/n]: " choice
        case "$choice" in 
            [nN][oO]|[nN]) 
                select_file ".mcap" "Select a different ROS2 MCAP bag:"
                if [ $? -ne 0 ]; then return; fi
                ;;
        esac
    fi

    # --- SMART TOP-LEVEL FOLDER RESOLUTION ---
    local bag_folder_host="$ACTIVE_BAG_HOST"
    if [ -f "$ACTIVE_BAG_HOST" ]; then
        local parent_dir=$(dirname "$ACTIVE_BAG_HOST")
        if [ -f "${parent_dir}/metadata.yaml" ]; then
            bag_folder_host="$parent_dir"
        fi
    fi

    local relative_path=$(realpath --relative-to="$HOST_DATA_DIR" "$bag_folder_host")
    local container_bag_path="${ROS2_DATA_DIR}/${relative_path}"

    log_info "Launching RViz2 inside $ROS2_CONTAINER..."
    local rviz_log="${RESULTS_DIR}/rviz2_launch.log"
    local container_rviz_log="/data/results/rviz2_launch.log"

    docker exec \
        -e DISPLAY="$DISPLAY" \
        -e QT_X11_NO_MITSHM=1 \
        -e LIBGL_ALWAYS_SOFTWARE=1 \
        -d "$ROS2_CONTAINER" bash -c "
            source /ros_entrypoint.sh 2>/dev/null || source /opt/ros/humble/setup.bash 2>/dev/null || source /opt/ros/rolling/setup.bash 2>/dev/null || source /opt/ros/jazzy/setup.bash 2>/dev/null || true
            rviz2 -d workspace/config.rviz > '$container_rviz_log' 2>&1
        "
    
    sleep 2

    log_info "Playing bag from folder inside $ROS2_CONTAINER..."
    log_warn "Press [Ctrl + C] in this terminal window to stop playback (which also closes RViz)."
    echo "--------------------------------------------------------"
    
    docker exec -it "$ROS2_CONTAINER" bash -c "
        source /ros_entrypoint.sh
        ros2 bag play '$container_bag_path'
    "
    local exit_code=$?

    log_info "Closing RViz2..."
    docker exec "$ROS2_CONTAINER" pkill -f rviz2 2>/dev/null || true
    echo "--------------------------------------------------------"
    if [ $exit_code -ne 0 ]; then
        log_error "Playback failed. Check if the path '$container_bag_path' is accessible in the container."
    else
        log_success "Playback finished."
    fi
    read -p "Press Enter to continue..."
}

# Step 2: Crop Bag (With Smart Folder Handovers)
step_crop_bag() {
    show_status
    log_info "Step 2: Crop MCAP Bag"

    if [ -z "$ACTIVE_BAG_HOST" ] || [ "$ACTIVE_BAG_TYPE" != "mcap" ]; then
        log_warn "You don't have an active ROS2 MCAP bag selected."
        select_file ".mcap" "Select an MCAP bag to crop:"
        if [ $? -ne 0 ]; then return; fi
        ACTIVE_BAG_TYPE="mcap"
    fi

    # --- SMART TOP-LEVEL FOLDER RESOLUTION ---
    local bag_folder_host="$ACTIVE_BAG_HOST"
    if [ -f "$ACTIVE_BAG_HOST" ]; then
        local parent_dir=$(dirname "$ACTIVE_BAG_HOST")
        if [ -f "${parent_dir}/metadata.yaml" ]; then
            bag_folder_host="$parent_dir"
        fi
    fi

    local relative_path=$(realpath --relative-to="$HOST_DATA_DIR" "$bag_folder_host")
    local container_bag_path="${ROS2_DATA_DIR}/${relative_path}"
    
    local tracker_file="${HOST_DATA_DIR}/.last_crop_out"
    rm -f "$tracker_file"

    log_info "Running cropping script inside ROS2 container..."
    log_info "Please respond directly to the Python script prompts below:"
    echo "--------------------------------------------------------"
    
    docker exec -it -w /data \
        -e DEFAULT_INPUT_BAG="$container_bag_path" \
        "$ROS2_CONTAINER" bash -c "
            source /ros_entrypoint.sh
            python3 '$ROS2_CROP_SCRIPT'
        "

    local run_status=$?
    echo "--------------------------------------------------------"
    echo ""

    if [ $run_status -eq 0 ] && [ -f "$tracker_file" ]; then
        local raw_output_path=$(cat "$tracker_file" | tr -d '\r\n')
        local relative_output="${raw_output_path#"$ROS2_DATA_DIR/"}"
        
        # Set the newly cropped bag folder as our active bag!
        ACTIVE_BAG_HOST="${HOST_DATA_DIR}/${relative_output}"
        ACTIVE_BAG_TYPE="mcap"
        
        rm -f "$tracker_file"
        log_success "Successfully cropped! New active bag folder is: $(basename "$ACTIVE_BAG_HOST")"
    else
        log_error "Cropping failed or was cancelled."
        rm -f "$tracker_file"
    fi
    read -p "Press Enter to continue..."
}

# Step 3: Convert to ROS1 .bag
step_convert_bag() {
    show_status
    log_info "Step 3: Convert ROS2 MCAP to ROS1 .bag"

    if [ -z "$ACTIVE_BAG_HOST" ] || [ "$ACTIVE_BAG_TYPE" != "mcap" ]; then
        log_warn "You don't have an active ROS2 MCAP bag selected to convert."
        select_file ".mcap" "Select an MCAP bag to convert:"
        if [ $? -ne 0 ]; then return; fi
        ACTIVE_BAG_TYPE="mcap"
    fi

    # --- SMART TOP-LEVEL FOLDER RESOLUTION ---
    local bag_folder_host="$ACTIVE_BAG_HOST"
    if [ -f "$ACTIVE_BAG_HOST" ]; then
        local parent_dir=$(dirname "$ACTIVE_BAG_HOST")
        if [ -f "${parent_dir}/metadata.yaml" ]; then
            bag_folder_host="$parent_dir"
        fi
    fi

    local relative_path=$(realpath --relative-to="$HOST_DATA_DIR" "$bag_folder_host")
    local container_input_path="${ROS2_DATA_DIR}/${relative_path}"
    
    # Use the folder name as the base name for the output ROS1 bag
    local base_name=$(basename "$bag_folder_host" .mcap)
    local ros1_bag_name="${base_name}.bag"
    local container_output_path="${ROS2_DATA_DIR}/${ros1_bag_name}"

    log_info "Converting MCAP folder to ROS1 .bag..."
    
    docker exec -it "$ROS2_CONTAINER" bash -c "
        source /workspace/.venv/bin/activate 2>/dev/null || true
        rosbags-convert --src '$container_input_path' --dst '$container_output_path'
    "

    if [ $? -eq 0 ]; then
        ACTIVE_BAG_HOST="${HOST_DATA_DIR}/${ros1_bag_name}"
        ACTIVE_BAG_TYPE="bag"
        log_success "Conversion successful! New active ROS1 bag is: $(basename "$ACTIVE_BAG_HOST")"
    else
        log_error "Conversion failed."
    fi
    read -p "Press Enter to continue..."
}

# Step 4: Run Kalibr
step_run_kalibr() {
    show_status
    log_info "Step 4: Run Kalibr Calibration"

    if [ -z "$ACTIVE_BAG_HOST" ] || [ "$ACTIVE_BAG_TYPE" != "bag" ]; then
        log_warn "You need a ROS1 .bag file to run Kalibr."
        select_file ".bag" "Select a ROS1 .bag file:"
        if [ $? -ne 0 ]; then return; fi
        ACTIVE_BAG_TYPE="bag"
    fi

    local relative_path=$(realpath --relative-to="$HOST_DATA_DIR" "$ACTIVE_BAG_HOST")
    local container_bag_path="${KALIBR_DATA_DIR}/${relative_path}"

    # Prep execution environment in Kalibr container
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local run_dir="/tmp/kalibr_run_${timestamp}"
    docker exec "$KALIBR_CONTAINER" mkdir -p "$run_dir"

    log_info "Running Kalibr... Output will be live-streamed and saved to logs."
    
    # Define Log file path on host
    local log_file="${RESULTS_DIR}/kalibr_run_${timestamp}.log"

    # We execute inside a shell wrapper to source ROS and Catkin paths so "rosrun" can be found
    docker exec -w "$run_dir" -t "$KALIBR_CONTAINER" bash -c "
        source /opt/ros/noetic/setup.bash 2>/dev/null || source /opt/ros/melodic/setup.bash 2>/dev/null || true
        source /catkin_ws/devel/setup.bash 2>/dev/null || true
        rosrun kalibr kalibr_calibrate_imu_camera \
            --bag '$container_bag_path' \
            --cam /data/camchain_mod.yaml \
            --imu /data/imu_inf_noise.yaml \
            --target /data/target.yaml \
            --no-time-calibration \
            --timeoffset-padding 0.1 \
            --max-iter 30
    " 2>&1 | tee "$log_file"

    # Check if run succeeded and copy output files to host results
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "Kalibr calibration executed successfully."
        log_info "Copying results out of container to ${RESULTS_DIR}..."
        
        # Copy everything created in the temp run directory to the host's results directory
        docker cp "${KALIBR_CONTAINER}:${run_dir}/." "${RESULTS_DIR}/"
        
        # Clean up container temp run dir
        docker exec "$KALIBR_CONTAINER" rm -rf "$run_dir"
        log_success "Results successfully saved to: ${RESULTS_DIR}"
    else
        log_error "Kalibr calibration run failed. Check the log file: ${log_file}"
    fi
    read -p "Press Enter to continue..."
}


# --- MAIN INTERACTIVE LOOP ---

# Initialize container states
ensure_containers_running

while true; do
    show_status
    echo "Please choose a step to execute:"
    echo "1) Step 1: Select & Play ROS2 Bag (RViz verification)"
    echo "2) Step 2: Crop MCAP Bag"
    echo "3) Step 3: Convert MCAP Bag to ROS1 .bag"
    echo "4) Step 4: Run Kalibr Calibration"
    echo "5) Select / Change Active Bag File manually"
    echo "6) Exit"
    echo "----------------------------------------------------------------="
    read -p "Selection [1-6]: " choice
    
    case $choice in
        1) step_play_bag ;;
        2) step_crop_bag ;;
        3) step_convert_bag ;;
        4) step_run_kalibr ;;
        5) 
            echo "What file type would you like to select?"
            echo "1) ROS2 MCAP (.mcap)"
            echo "2) ROS1 Bag (.bag)"
            read -p "[1-2]: " type_choice
            if [ "$type_choice" -eq 1 ]; then
                select_file ".mcap" "Select MCAP file:" && ACTIVE_BAG_TYPE="mcap"
            elif [ "$type_choice" -eq 2 ]; then
                select_file ".bag" "Select ROS1 Bag file:" && ACTIVE_BAG_TYPE="bag"
            fi
            ;;
        6) 
            log_info "Exiting workflow orchestrator. Goodbye!"
            exit 0 
            ;;
        *) 
            log_warn "Invalid option. Press enter to try again..."
            read
            ;;
    esac
done