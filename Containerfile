# Ubuntu 22.04 + ROS 2 Humble + Python 3.10 dev image for Unitree robots
# (G1/H1/Go2), usable as a distrobox or as a base image:
#   - Unitree ROS2 message packages (unitree_api, unitree_go, unitree_hg)
#   - Unitree Python SDK (unitree_sdk2py, cyclonedds 0.10.2)
#   - Inference only (no torch): ncnn (Vulkan), onnxruntime, mediapipe, OpenCV
#   - llama.cpp (Vulkan) for GGUF models: llama-cli, llama-server, ...
#   - unitree_mujoco simulator (C++ and Python) and the C++ unitree_sdk2 (/opt/unitree_robotics)
#
# Vulkan drivers come from a Mesa built from source (stage "mesa-build"), because
# Ubuntu 22.04's Mesa 23.2 is too old for e.g. NVK on Maxwell GPUs: RADV (AMD),
# ANV/HASVK (Intel), NVK (NVIDIA, open source) and lavapipe (CPU fallback).
#
# Built nightly by .github/workflows/build.yml.

# Shared by the mesa-build and llama-build stages.
ARG LLVM_VERSION=19
ARG VULKAN_SDK_REF=vulkan-sdk-1.4.363.0
# Shared by sim-build (C++ simulator) and the final stage (mujoco Python package).
ARG MUJOCO_VERSION=3.3.6

# ---------------------------------------------------------------------------
# Mesa, Vulkan drivers only (no OpenGL), installed into /staging
# ---------------------------------------------------------------------------
FROM docker.io/library/ubuntu:22.04 AS mesa-build

ARG MESA_VERSION=26.2.4
ARG LLVM_VERSION

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
        libclc-$LLVM_VERSION-dev libpolly-$LLVM_VERSION-dev cmake ninja-build \
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
    && curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal -c rustfmt \
    && cargo install --locked bindgen-cli cbindgen

# Build with clang: Mesa uses C23 enums with a fixed underlying type
# (`enum x : uint8_t`), which jammy's GCC 11 can't parse.
RUN curl -fsSL https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz | tar -xJ -C /opt \
    && cd /opt/mesa-$MESA_VERSION \
    && CC=clang-$LLVM_VERSION CXX=clang++-$LLVM_VERSION meson setup build --prefix=/usr/local --buildtype=release \
        -Dvulkan-drivers=amd,intel,intel_hasvk,nouveau,swrast \
        -Dvulkan-layers=device-select \
        -Dgallium-drivers= -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
        -Degl=disabled -Dgbm=disabled -Dglx=disabled -Dllvm=enabled -Dshared-llvm=disabled \
        -Dplatforms=x11,wayland -Dallow-fallback-for=libdrm -Dlmsensors=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
    && meson install -C build --destdir /staging

# Jammy's Vulkan loader (1.3.204) predates VK_EXT_layer_settings, which Mesa's
# layers advertise, so vulkaninfo fails on it; ship a current loader + vulkaninfo.
ARG VULKAN_SDK_REF
RUN git clone --depth 1 --branch "$VULKAN_SDK_REF" https://github.com/KhronosGroup/Vulkan-Loader /opt/vulkan-loader \
    && git clone --depth 1 --branch "$VULKAN_SDK_REF" https://github.com/KhronosGroup/Vulkan-Tools /opt/vulkan-tools \
    && cmake -S /opt/vulkan-loader -B /opt/vulkan-loader/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DUPDATE_DEPS=ON -DBUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /opt/vulkan-loader/build \
    && DESTDIR=/staging cmake --install /opt/vulkan-loader/build \
    && cmake -S /opt/vulkan-tools -B /opt/vulkan-tools/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DUPDATE_DEPS=ON -DBUILD_CUBE=OFF -DBUILD_ICD=OFF -DBUILD_VULKANINFO=ON -DBUILD_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /opt/vulkan-tools/build \
    && DESTDIR=/staging cmake --install /opt/vulkan-tools/build \
    && rm -rf /opt/vulkan-loader /opt/vulkan-tools

# ---------------------------------------------------------------------------
# llama.cpp with the Vulkan backend, installed into /staging-llama
# ---------------------------------------------------------------------------
FROM mesa-build AS llama-build

ARG LLVM_VERSION
ARG VULKAN_SDK_REF
ARG SHADERC_REF=v2026.4
ARG LLAMA_CPP_REF=b11535

# ggml-vulkan compiles its shaders with glslc and needs current Vulkan and
# SPIRV headers; jammy has no glslc, so build shaderc and install the headers.
# The Vulkan loader comes from this stage's /staging.
RUN cp -a /staging/. / && ldconfig \
    && apt-get update && apt-get install -y --no-install-recommends libssl-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch "$VULKAN_SDK_REF" https://github.com/KhronosGroup/Vulkan-Headers /opt/vulkan-headers \
    && cmake -S /opt/vulkan-headers -B /opt/vulkan-headers/build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --install /opt/vulkan-headers/build \
    && git clone --depth 1 --branch "$SHADERC_REF" https://github.com/google/shaderc /opt/shaderc \
    && cd /opt/shaderc && python3 utils/git-sync-deps \
    && cmake -S third_party/spirv-headers -B build-spirv-headers -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --install build-spirv-headers \
    && cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
    && cmake --build build --target glslc_exe \
    && install -m 755 build/glslc/glslc /usr/local/bin/glslc \
    && rm -rf /opt/vulkan-headers /opt/shaderc

# Clang, since GCC 11 lacks some of the ISA extensions the CPU variants use.
# GGML_CPU_ALL_VARIANTS picks the best CPU kernels at runtime instead of
# tuning for the build machine; OpenMP off so the runtime needs no libomp.
RUN git clone --depth 1 --branch "$LLAMA_CPP_REF" https://github.com/ggml-org/llama.cpp /opt/llama.cpp \
    && CC=clang-$LLVM_VERSION CXX=clang++-$LLVM_VERSION cmake -S /opt/llama.cpp -B /opt/llama.cpp/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_OPENMP=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    && cmake --build /opt/llama.cpp/build \
    && DESTDIR=/staging-llama cmake --install /opt/llama.cpp/build \
    && rm -rf /opt/llama.cpp

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

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        tmux \
        vim-tiny \
        python3-pip \
        python3-colcon-common-extensions \
        ros-humble-rmw-cyclonedds-cpp \
        ros-humble-rosidl-generator-dds-idl \
        libyaml-cpp-dev \
        libdrm2 libdrm-amdgpu1 libdrm-intel1 libdrm-nouveau2 libxcb-dri3-0 libxcb-present0 \
        libxcb-sync1 libxcb-randr0 libxcb-xfixes0 libxshmfence1 libx11-xcb1 libwayland-client0 libzstd1 libelf1 \
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

# Unitree Python SDK first, so its cyclonedds==0.10.2 pin wins.
RUN git clone --depth 1 --branch "$UNITREE_SDK2_PYTHON_REF" \
        https://github.com/unitreerobotics/unitree_sdk2_python /opt/unitree_sdk2_python \
    && pip3 install --no-cache-dir -e /opt/unitree_sdk2_python

# Inference only, no torch: ncnn runs on Vulkan, onnxruntime on CPU.
# Train and export models elsewhere (e.g. `yolo export format=ncnn`).
# mujoco (same release as the C++ simulator) and pygame (gamepad) are for
# /opt/unitree_mujoco/simulate_python and MuJoCo scripting from Python.
RUN pip3 install --no-cache-dir --timeout 600 \
        ncnn onnxruntime mediapipe "mujoco==$MUJOCO_VERSION" pygame

# Mesa Vulkan drivers (ICDs land in /usr/local/share/vulkan/icd.d, which the loader searches).
COPY --from=mesa-build /staging/ /
COPY --from=llama-build /staging-llama/ /
COPY --from=sim-build /opt/unitree_robotics /opt/unitree_robotics
COPY --from=sim-build /opt/unitree_mujoco /opt/unitree_mujoco
RUN ldconfig \
    && ln -s /opt/unitree_mujoco/simulate/bin/unitree_mujoco /usr/local/bin/unitree_mujoco

# ROS + Unitree environment for every login shell in the box.
COPY unitree-env.sh /etc/profile.d/unitree-env.sh

RUN bash -c "source /etc/profile.d/unitree-env.sh && python3.10 -c '\
import unitree_sdk2py, cyclonedds, rclpy, unitree_hg, cv2, mediapipe, ncnn, onnxruntime, mujoco, pygame; \
print(\"All imports OK, ncnn Vulkan devices:\", ncnn.get_gpu_count())'" \
    && vulkaninfo --summary | grep -E "deviceName|driverInfo" \
    && llama-cli --version && llama-cli --list-devices \
    && unitree_mujoco --help
