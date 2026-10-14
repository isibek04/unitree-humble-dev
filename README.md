# unitree-humble-dev

Ubuntu 22.04 + ROS 2 Humble + Python 3.10 development image for Unitree robots (G1, H1, Go2), built for [distrobox](https://distrobox.it) but usable as a plain container base image.

```
ghcr.io/isibek04/unitree-humble-dev:latest
```

Rebuilt nightly from scratch, so it picks up Ubuntu/ROS updates and the latest Unitree commits.

## What's inside

| | |
|---|---|
| ROS 2 | Humble (`ros:humble-ros-base-jammy`), `rmw_cyclonedds_cpp` |
| Unitree messages | `unitree_api`, `unitree_go`, `unitree_hg` built from [unitree_ros2](https://github.com/unitreerobotics/unitree_ros2) in `/opt/unitree_ros2` |
| Unitree Python SDK | [unitree_sdk2_python](https://github.com/unitreerobotics/unitree_sdk2_python) in `/opt/unitree_sdk2_python` (with `cyclonedds==0.10.2`) |
| Python | 3.10, `ncnn` (Vulkan), `onnxruntime`, `mediapipe`, OpenCV, `mujoco`, `pygame` (no torch) |
| Simulator | [unitree_mujoco](https://github.com/unitreerobotics/unitree_mujoco) (MuJoCo) in `/opt/unitree_mujoco`: C++ as `unitree_mujoco` on the `PATH`, Python in `simulate_python/` |
| Unitree C++ SDK | [unitree_sdk2](https://github.com/unitreerobotics/unitree_sdk2) in `/opt/unitree_robotics` |
| LLMs | [llama.cpp](https://github.com/ggml-org/llama.cpp) with the Vulkan backend for GGUF models: `llama-cli`, `llama-server`, … in `/usr/local/bin` |
| Tools | `tmux`, `vi`, `git`, `colcon`, `ffmpeg`, PortAudio |

Every login shell sources `/etc/profile.d/unitree-env.sh`: ROS 2 Humble, the Unitree messages, `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`, and CycloneDDS bound to `$ROBOT_IFACE` (default `enp3s0`). It also exports `UNITREE_ROS2_SETUP` pointing at itself, for scripts that would otherwise source `unitree_ros2/setup.sh`.

## Usage

**Distrobox** (shares the host network, `$HOME`, webcam, audio and display):

```bash
distrobox create --name unitree --image ghcr.io/isibek04/unitree-humble-dev:latest
ROBOT_IFACE=eth0 distrobox enter unitree
```

**Base image:**

```dockerfile
FROM ghcr.io/isibek04/unitree-humble-dev:latest
RUN pip3 install --no-cache-dir -r requirements.txt
```

**GGUF models** with llama.cpp (Vulkan GPU, CPU fallback):

```bash
llama-cli --list-devices
llama-cli -m ~/models/model.gguf -ngl 99
llama-server -m ~/models/model.gguf -ngl 99 --port 8080   # OpenAI-compatible API
```

**Simulator**: `unitree_mujoco` stands in for the robot over the same DDS topics (`rt/lowstate`, `rt/lowcmd`, …), on DDS domain 1 over the loopback interface, apart from a real robot on domain 0. Low-level control only: no sport mode or other built-in services.

```bash
unitree_mujoco -r go2                        # also go2w, b2, b2w, h1, g1, h2, as2
unitree_mujoco -r g1 -s scene_29dof.xml      # scenes in /opt/unitree_mujoco/unitree_robots/<robot>/
```

Then point your code at it: `ChannelFactoryInitialize(1, "lo")` with the Python SDK, or for ROS 2:

```bash
export ROBOT_IFACE=lo ROS_DOMAIN_ID=1; source /etc/profile.d/unitree-env.sh
ros2 topic echo /lowstate
```

Defaults (gamepad, elastic band for hanging humanoids) are in `/opt/unitree_mujoco/simulate/config.yaml`.

The Python version (on `unitree_sdk2py` and the `mujoco` package) is easier to modify, but its timing is less faithful than the C++ one. It takes no flags: robot, scene and the rest are in `config.py`, and it must run from its own directory:

```bash
cd /opt/unitree_mujoco/simulate_python && python3 unitree_mujoco.py
```

Non-login shells (e.g. `docker run ... cmd`) don't read `/etc/profile.d`; use `bash -lc 'cmd'` or source `/etc/profile.d/unitree-env.sh` in your entrypoint.

## Building locally

```bash
podman build -t localhost/unitree-humble-dev .
```

## Licenses

The image redistributes third-party software unmodified under its own licenses, including:

- Ubuntu packages and ROS 2 Humble: various open-source licenses (Apache-2.0, BSD, GPL, …); see `/usr/share/doc/*/copyright` in the image
- [unitree_ros2](https://github.com/unitreerobotics/unitree_ros2), [unitree_sdk2_python](https://github.com/unitreerobotics/unitree_sdk2_python), [unitree_sdk2](https://github.com/unitreerobotics/unitree_sdk2), [unitree_mujoco](https://github.com/unitreerobotics/unitree_mujoco): BSD-3-Clause (license files in `/opt/unitree_*`)
- [MuJoCo](https://github.com/google-deepmind/mujoco): Apache-2.0 (notices in `/opt/unitree_mujoco/simulate/lib`)
- [Eclipse Cyclone DDS](https://github.com/eclipse-cyclonedds/cyclonedds-python): EPL-2.0 / EDL-1.0
- [ncnn](https://github.com/Tencent/ncnn): BSD-3-Clause; [ONNX Runtime](https://github.com/microsoft/onnxruntime): MIT
- [llama.cpp](https://github.com/ggml-org/llama.cpp): MIT
- [MediaPipe](https://github.com/google-ai-edge/mediapipe), [OpenCV](https://github.com/opencv/opencv-python): Apache-2.0

Python package license texts are in each package's `*.dist-info` directory under `/usr/local/lib/python3.10/dist-packages`.
