FROM osrf/ros:kilted-desktop

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Update packages and install PlotJuggler, ROS integrations, and UI runtime utilities
RUN apt-get update && apt-get install -y \
    ros-kilted-plotjuggler-ros \
    dbus-x11 \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Setup non-root user (safely renames existing standard Ubuntu UID 1000 to avoid conflicts)
ARG USERNAME=rosuser
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN if id -u $USER_UID >/dev/null 2>&1; then \
        existing_user=$(id -un $USER_UID); \
        usermod -l $USERNAME $existing_user; \
        groupmod -n $USERNAME $(id -gn $USER_UID); \
        usermod -d /home/$USERNAME -m $USERNAME; \
    else \
        groupadd --gid $USER_GID $USERNAME && \
        useradd --uid $USER_UID --gid $USER_GID -m $USERNAME; \
    fi \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Automatically source ROS 2 setup and enable shell auto-completion for development
RUN echo "source /opt/ros/kilted/setup.bash" >> /home/$USERNAME/.bashrc \
    && echo "source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash" >> /home/$USERNAME/.bashrc

USER $USERNAME