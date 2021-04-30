#!/bin/bash

MASTER_NAME=control-plane

vm=$MASTER_NAME ./run.sh init
master_name=$MASTER_NAME vm=centos-worker-1 distro=centos-7 topology='[{"cores": 4, "mem": "2G", "nodes": 1}]' ./run.sh join
master_name=$MASTER_NAME vm=ubuntu-worker-2 distro=ubuntu-20_04 topology='[{"cores": 2, "mem": "2G", "nodes": 2}]' ./run.sh join
master_name=$MASTER_NAME vm=fedora-worker-3 distro=fedora topology='[{"cores": 2, "mem": "2G", "nodes": 4}]' ./run.sh join
