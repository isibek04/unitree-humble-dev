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
| Python | 3.10, `ncnn` (Vulkan), `onnxruntime`, `mediapipe`, OpenCV (no torch) |
| Tools | `tmux`, `git`, `colcon`, `ffmpeg`, PortAudio |

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

Non-login shells (e.g. `docker run ... cmd`) don't read `/etc/profile.d`; use `bash -lc 'cmd'` or source `/etc/profile.d/unitree-env.sh` in your entrypoint.

## Building locally

```bash
podman build -t localhost/unitree-humble-dev .
```

## Licenses

The image redistributes third-party software unmodified under its own licenses, including:

- Ubuntu packages and ROS 2 Humble: various open-source licenses (Apache-2.0, BSD, GPL, …); see `/usr/share/doc/*/copyright` in the image
- [unitree_ros2](https://github.com/unitreerobotics/unitree_ros2), [unitree_sdk2_python](https://github.com/unitreerobotics/unitree_sdk2_python): BSD-3-Clause (license files in `/opt/unitree_*`)
- [Eclipse Cyclone DDS](https://github.com/eclipse-cyclonedds/cyclonedds-python): EPL-2.0 / EDL-1.0
- [ncnn](https://github.com/Tencent/ncnn): BSD-3-Clause; [ONNX Runtime](https://github.com/microsoft/onnxruntime): MIT
- [MediaPipe](https://github.com/google-ai-edge/mediapipe), [OpenCV](https://github.com/opencv/opencv-python): Apache-2.0

Python package license texts are in each package's `*.dist-info` directory under `/usr/local/lib/python3.10/dist-packages`.
