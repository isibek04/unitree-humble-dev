# Ubuntu 22.04 + ROS 2 Humble + Python 3.10 dev image for Unitree robots
# (G1/H1/Go2), usable as a distrobox or as a base image:
#   - Unitree ROS2 message packages (unitree_api, unitree_go, unitree_hg)
#   - Unitree Python SDK (unitree_sdk2py, cyclonedds 0.10.2)
#   - Inference only (no torch): ncnn (Vulkan), onnxruntime, mediapipe, OpenCV
#
# Vulkan drivers come from a Mesa built from source (stage "mesa-build"), because
# Ubuntu 22.04's Mesa 23.2 is too old for e.g. NVK on Maxwell GPUs: RADV (AMD),
# ANV/HASVK (Intel), NVK (NVIDIA, open source) and lavapipe (CPU fallback).
#
# Built nightly by .github/workflows/build.yml.

# ---------------------------------------------------------------------------
# Mesa, Vulkan drivers only (no OpenGL), installed into /staging
# ---------------------------------------------------------------------------
FROM docker.io/library/ubuntu:22.04 AS mesa-build

ARG MESA_VERSION=26.2.4
ARG LLVM_VERSION=19

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg xz-utils git pkg-config bison flex \
        build-essential python3-pip python3-dev \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] https://apt.llvm.org/jammy/ llvm-toolchain-jammy-$LLVM_VERSION main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        llvm-$LLVM_VERSION-dev clang-$LLVM_VERSION libclang-$LLVM_VERSION-dev libclang-cpp$LLVM_VERSION-dev \
        libclc-$LLVM_VERSION-dev cmake ninja-build \
        libdrm-dev libexpat1-dev libzstd-dev zlib1g-dev libelf-dev \
        libx11-dev libxext-dev libxfixes-dev libxrandr-dev libxshmfence-dev libx11-xcb-dev \
        libxcb-dri3-dev libxcb-present-dev libxcb-sync-dev libxcb-randr0-dev \
        libxcb-shm0-dev libxcb-xfixes0-dev libxcb-glx0-dev libxcb-dri2-0-dev \
        libwayland-dev wayland-protocols \
    && rm -rf /var/lib/apt/lists/*

# Mesa's CLC step needs SPIRV-Tools >= 2024.1 and a SPIRV-LLVM-Translator matching
# the LLVM version; jammy has neither, so build them (static, build-time only).
ARG SPIRV_REF=main
RUN git clone --depth 1 --branch "$SPIRV_REF" https://github.com/KhronosGroup/SPIRV-Headers /opt/spirv-headers \
    && git clone --depth 1 --branch "$SPIRV_REF" https://github.com/KhronosGroup/SPIRV-Tools /opt/spirv-tools \
    && git clone --depth 1 --branch "llvm_release_${LLVM_VERSION}0" https://github.com/KhronosGroup/SPIRV-LLVM-Translator /opt/spirv-llvm-translator \
    && cmake -S /opt/spirv-tools -B /opt/spirv-tools/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DSPIRV-Headers_SOURCE_DIR=/opt/spirv-headers -DSPIRV_SKIP_TESTS=ON -DSPIRV_WERROR=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /opt/spirv-tools/build --target install \
    && cmake -S /opt/spirv-llvm-translator -B /opt/spirv-llvm-translator/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_DIR=/usr/lib/llvm-$LLVM_VERSION/lib/cmake/llvm \
        -DLLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR=/opt/spirv-headers \
        -DLLVM_SPIRV_INCLUDE_TESTS=OFF -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /opt/spirv-llvm-translator/build --target install \
    && rm -rf /opt/spirv-tools /opt/spirv-headers /opt/spirv-llvm-translator

# Mesa also wants glslang >= 12.2 (jammy has 11.x).
RUN git clone --depth 1 https://github.com/KhronosGroup/glslang /opt/glslang \
    && cd /opt/glslang && python3 update_glslang_sources.py \
    && cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DENABLE_GLSLANG_BINARIES=ON -DBUILD_TESTING=OFF \
    && cmake --build build --target install \
    && rm -rf /opt/glslang

# Mesa needs meson >= 1.4, rustc >= 1.85 and bindgen >= 0.71.1 for NVK; jammy ships none of them.
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig \
    LIBCLANG_PATH=/usr/lib/llvm-$LLVM_VERSION/lib \
    PATH=/usr/lib/llvm-$LLVM_VERSION/bin:/root/.cargo/bin:$PATH
RUN pip3 install --no-cache-dir meson ninja mako pyyaml packaging \
    && curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal \
    && cargo install --locked bindgen-cli cbindgen

RUN curl -fsSL https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz | tar -xJ -C /opt \
    && cd /opt/mesa-$MESA_VERSION \
    && meson setup build --prefix=/usr/local --buildtype=release \
        -Dvulkan-drivers=amd,intel,intel_hasvk,nouveau,swrast \
        -Dvulkan-layers=device-select \
        -Dgallium-drivers= -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
        -Degl=disabled -Dgbm=disabled -Dglx=disabled -Dllvm=enabled -Dshared-llvm=disabled \
        -Dplatforms=x11,wayland -Dallow-fallback-for=libdrm -Dlmsensors=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
    && meson install -C build --destdir /staging

# ---------------------------------------------------------------------------
# Final image
# ---------------------------------------------------------------------------
FROM docker.io/library/ros:humble-ros-base-jammy AS runtime

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
        libvulkan1 vulkan-tools \
        libdrm2 libdrm-amdgpu1 libdrm-intel1 libdrm-nouveau2 libxcb-dri3-0 libxcb-present0 \
        libxcb-sync1 libxcb-randr0 libxcb-xfixes0 libxshmfence1 libx11-xcb1 libwayland-client0 libzstd1 libelf1 \
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

# Inference only, no torch: ncnn runs on Vulkan, onnxruntime on CPU.
# Train and export models elsewhere (e.g. `yolo export format=ncnn`).
RUN pip3 install --no-cache-dir --timeout 600 \
        ncnn onnxruntime mediapipe

# Mesa Vulkan drivers (ICDs land in /usr/local/share/vulkan/icd.d, which the loader searches).
COPY --from=mesa-build /staging/ /
RUN ldconfig

# ROS + Unitree environment for every login shell in the box.
COPY unitree-env.sh /etc/profile.d/unitree-env.sh

RUN bash -c "source /etc/profile.d/unitree-env.sh && python3.10 -c '\
import unitree_sdk2py, cyclonedds, rclpy, unitree_hg, cv2, mediapipe, ncnn, onnxruntime; \
print(\"All imports OK, ncnn Vulkan devices:\", ncnn.get_gpu_count())'" \
    && vulkaninfo --summary | grep -E "deviceName|driverInfo"
