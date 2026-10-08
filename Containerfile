# Ubuntu 22.04 + ROS 2 Humble + Python 3.10 dev image for Unitree robots
# (G1/H1/Go2), usable as a distrobox or as a base image:
#   - Unitree ROS2 message packages (unitree_api, unitree_go, unitree_hg)
#   - Unitree Python SDK (unitree_sdk2py, cyclonedds 0.10.2)
#   - CPU-only torch, ultralytics (YOLO), mediapipe, OpenCV
#
# Built nightly by .github/workflows/build.yml.
FROM docker.io/library/ros:humble-ros-base-jammy

ARG UNITREE_SDK2_PYTHON_REF=master
ARG UNITREE_ROS2_REF=master

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        tmux \
        python3-pip \
        python3-colcon-common-extensions \
        ros-humble-rmw-cyclonedds-cpp \
        ros-humble-rosidl-generator-dds-idl \
        libyaml-cpp-dev \
        libgl1 libglib2.0-0 libsm6 libxrender1 libxext6 libgles2-mesa libegl1 \
        portaudio19-dev libsndfile1 ffmpeg \
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

# Unitree Python SDK first, so its cyclonedds==0.10.2 pin wins.
RUN git clone --depth 1 --branch "$UNITREE_SDK2_PYTHON_REF" \
        https://github.com/unitreerobotics/unitree_sdk2_python /opt/unitree_sdk2_python \
    && pip3 install --no-cache-dir -e /opt/unitree_sdk2_python

# CPU-only torch: keeps the image ~4 GB smaller than the default CUDA build.
RUN pip3 install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch torchvision

RUN pip3 install --no-cache-dir --timeout 600 \
        --extra-index-url https://download.pytorch.org/whl/cpu \
        mediapipe ultralytics

# ROS + Unitree environment for every login shell in the box.
COPY unitree-env.sh /etc/profile.d/unitree-env.sh

RUN bash -c "source /etc/profile.d/unitree-env.sh && python3.10 -c '\
import unitree_sdk2py, cyclonedds, rclpy, unitree_hg, cv2, mediapipe, ultralytics, torch; \
assert not torch.cuda.is_available() and \"+cpu\" in torch.__version__, torch.__version__; \
print(\"All imports OK, torch\", torch.__version__)'"
