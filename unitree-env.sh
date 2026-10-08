# Sourced by login shells (/etc/profile.d/unitree-env.sh).
# ROS 2 Humble + Unitree messages, with
# CycloneDDS bound to the robot's ethernet interface.
#
# Change the interface per shell with: export ROBOT_IFACE=eth0; source /etc/profile.d/unitree-env.sh

_unitree_nounset=0; case $- in *u*) _unitree_nounset=1; set +u ;; esac
source /opt/ros/humble/setup.bash
source /opt/unitree_ros2/cyclonedds_ws/install/setup.bash
[ "$_unitree_nounset" = 1 ] && set -u
unset _unitree_nounset

export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI="<CycloneDDS><Domain><General><Interfaces><NetworkInterface name=\"${ROBOT_IFACE:-enp3s0}\" priority=\"default\" multicast=\"default\" /></Interfaces></General></Domain></CycloneDDS>"

# Scripts can source this instead of a local unitree_ros2/setup.sh
export UNITREE_ROS2_SETUP=/etc/profile.d/unitree-env.sh
