# Ubuntu 22.04 + ROS 2 Humble + Python 3.10 dev image for Unitree robots
# (G1/H1/Go2), usable as a distrobox or as a base image:
#   - Unitree ROS2 message packages (unitree_api, unitree_go, unitree_hg)
#   - Unitree Python SDK (unitree_sdk2py, cyclonedds 0.10.2)
#   - Nav2 and slam_toolbox
#   - unitree_mujoco simulator (C++ and Python) and the C++ unitree_sdk2 (/opt/unitree_robotics)
#
# Multi-arch: linux/amd64 and linux/arm64 (e.g. the robots' Jetson Orin, on a JetPack 5
# / Ubuntu 20.04 host with Docker). No Vulkan drivers or CUDA: nothing in the image uses the GPU.
#
# Built nightly by .github/workflows/build.yml.

# Shared by sim-build (C++ simulator) and the final stage (mujoco Python package).
ARG MUJOCO_VERSION=3.3.6

# ---------------------------------------------------------------------------
# unitree_mujoco simulator (C++), on the C++ unitree_sdk2 and a MuJoCo release
# ---------------------------------------------------------------------------
FROM docker.io/library/ubuntu:22.04 AS sim-build

ARG UNITREE_SDK2_REF=main
ARG UNITREE_MUJOCO_REF=main
ARG MUJOCO_VERSION

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git build-essential cmake \
        libyaml-cpp-dev libboost-program-options-dev libfmt-dev libglfw3-dev libeigen3-dev \
    && rm -rf /var/lib/apt/lists/*

# unitree_sdk2 goes to /opt/unitree_robotics, where unitree_mujoco and Unitree's
# C++ examples look for it; it brings its own CycloneDDS (libddsc/libddscxx).
RUN git clone --depth 1 --branch "$UNITREE_SDK2_REF" https://github.com/unitreerobotics/unitree_sdk2 /tmp/unitree_sdk2 \
    && cmake -S /tmp/unitree_sdk2 -B /tmp/unitree_sdk2/build -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_EXAMPLES=OFF -DCMAKE_INSTALL_PREFIX=/opt/unitree_robotics \
    && cmake --build /tmp/unitree_sdk2/build --target install \
    && cp /tmp/unitree_sdk2/LICENSE /opt/unitree_robotics/ \
    && rm -rf /tmp/unitree_sdk2

# The simulator finds config.yaml in the parent of its binary's directory and
# the robot models in ../unitree_robots, so the binary goes to simulate/bin with
# MuJoCo in simulate/lib. RPATH (not RUNPATH) so ROS's LD_LIBRARY_PATH can't
# swap in its own libddsc.
RUN git clone --depth 1 --branch "$UNITREE_MUJOCO_REF" https://github.com/unitreerobotics/unitree_mujoco /opt/unitree_mujoco \
    && curl -fsSL https://github.com/google-deepmind/mujoco/releases/download/$MUJOCO_VERSION/mujoco-$MUJOCO_VERSION-linux-$(uname -m).tar.gz \
        | tar -xz -C /opt \
    && cd /opt/unitree_mujoco/simulate \
    && sed -i 's/^domain_id:.*/domain_id: 0/' config.yaml && grep -qx 'domain_id: 0' config.yaml \
    && sed -i 's/^use_joystick:.*/use_joystick: 1/' config.yaml && grep -qx 'use_joystick: 1' config.yaml \
    && sed -i 's/^enable_elastic_band:.*/enable_elastic_band: 1/' config.yaml && grep -qx 'enable_elastic_band: 1' config.yaml \
    && sed -i 's/^DOMAIN_ID *=.*/DOMAIN_ID = 0/' ../simulate_python/config.py && grep -qx 'DOMAIN_ID = 0' ../simulate_python/config.py \
    && ln -s /opt/mujoco-$MUJOCO_VERSION mujoco \
    && cmake -S . -B /tmp/sim-build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--disable-new-dtags \
        -DCMAKE_BUILD_RPATH='$ORIGIN/../lib;/opt/unitree_robotics/lib' \
    && cmake --build /tmp/sim-build --target unitree_mujoco -j"$(nproc)" \
    && install -D -m 755 /tmp/sim-build/unitree_mujoco bin/unitree_mujoco \
    && cp -a mujoco/bin/mujoco_plugin bin/ \
    && mkdir lib && cp -a mujoco/lib/libmujoco.so* mujoco/THIRD_PARTY_NOTICES lib/ \
    && rm -rf mujoco /tmp/sim-build /opt/mujoco-$MUJOCO_VERSION /opt/unitree_mujoco/.git

# ---------------------------------------------------------------------------
# Final image
# ---------------------------------------------------------------------------
FROM docker.io/library/ros:humble-ros-base-jammy AS runtime

ARG UNITREE_SDK2_PYTHON_REF=master
ARG UNITREE_ROS2_REF=master
ARG MUJOCO_VERSION
# Set by BuildKit/buildah from --platform.
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        tmux \
        vim-tiny \
        python3-pip python3-dev \
        python3-colcon-common-extensions \
        ros-humble-rmw-cyclonedds-cpp \
        ros-humble-rosidl-generator-dds-idl \
        ros-humble-navigation2 \
        ros-humble-nav2-bringup \
        ros-humble-slam-toolbox \
        libyaml-cpp-dev \
        libgl1 libglib2.0-0 libsm6 libxrender1 libxext6 libgles2-mesa libegl1 \
        portaudio19-dev libsndfile1 ffmpeg \
        libglfw3 libyaml-cpp0.7 libboost-program-options1.74.0 libeigen3-dev \
    && rm -rf /var/lib/apt/lists/*

# Unitree ROS2 message packages (unitree_api, unitree_go, unitree_hg).
# Built before any pip install: colcon needs setuptools<80, and the pip step
# below would otherwise upgrade it first.
RUN git clone --depth 1 --branch "$UNITREE_ROS2_REF" \
        https://github.com/unitreerobotics/unitree_ros2 /opt/unitree_ros2 \
    && bash -c "source /opt/ros/humble/setup.bash \
        && cd /opt/unitree_ros2/cyclonedds_ws \
        && colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release" \
    && rm -rf /opt/unitree_ros2/cyclonedds_ws/build /opt/unitree_ros2/cyclonedds_ws/log

# cyclonedds 0.10.2 has no aarch64 wheel, so on arm64 pip builds it from source against
# the C library of the same release (as unitree_sdk2_python's README does on Jetsons).
# ROS's own libddsc stays first on LD_LIBRARY_PATH in sourced shells; same soname and ABI.
ARG CYCLONEDDS_REF=0.10.2
RUN if [ "$TARGETARCH" = arm64 ]; then \
        git clone --depth 1 --branch "$CYCLONEDDS_REF" https://github.com/eclipse-cyclonedds/cyclonedds /tmp/cyclonedds \
        && cmake -S /tmp/cyclonedds -B /tmp/cyclonedds/build -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX=/opt/cyclonedds \
        && cmake --build /tmp/cyclonedds/build --target install -j"$(nproc)" \
        && echo /opt/cyclonedds/lib > /etc/ld.so.conf.d/cyclonedds.conf && ldconfig \
        && rm -rf /tmp/cyclonedds; \
    fi

# Unitree Python SDK first, so its cyclonedds==0.10.2 pin wins.
RUN git clone --depth 1 --branch "$UNITREE_SDK2_PYTHON_REF" \
        https://github.com/unitreerobotics/unitree_sdk2_python /opt/unitree_sdk2_python \
    && CYCLONEDDS_HOME=/opt/cyclonedds pip3 install --no-cache-dir -e /opt/unitree_sdk2_python

# mujoco (same release as the C++ simulator) and pygame (gamepad) are for
# /opt/unitree_mujoco/simulate_python and MuJoCo scripting from Python.
RUN pip3 install --no-cache-dir --timeout 600 \
        "mujoco==$MUJOCO_VERSION" pygame

COPY --from=sim-build /opt/unitree_robotics /opt/unitree_robotics
COPY --from=sim-build /opt/unitree_mujoco /opt/unitree_mujoco
RUN ldconfig \
    && ln -s /opt/unitree_mujoco/simulate/bin/unitree_mujoco /usr/local/bin/unitree_mujoco

# ROS + Unitree environment for every login shell in the box.
COPY unitree-env.sh /etc/profile.d/unitree-env.sh

RUN bash -c "source /etc/profile.d/unitree-env.sh && python3.10 -c '\
import unitree_sdk2py, cyclonedds, rclpy, unitree_hg, mujoco, pygame; \
print(\"All imports OK\")'" \
    && unitree_mujoco --help
