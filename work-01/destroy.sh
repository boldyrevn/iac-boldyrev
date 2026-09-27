#!/bin/bash
set -e

PREFIX=boldyrev-04
ZONE=ru-central1-a
CIDR=10.14.1.0/24
DISK_SIZE=15
IMAGE_FAMILY=ubuntu-2204-lts
yc compute instance delete "$PREFIX-app-1"
yc compute instance delete "$PREFIX-app-2"
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"