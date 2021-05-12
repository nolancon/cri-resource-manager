#!/bin/bash

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
MASTER_NAME=control-plane

vm=$MASTER_NAME $SCRIPT_DIR/run.sh init

master_name=$MASTER_NAME vm=centos-worker distro=centos topology='[{"cores": 4, "mem": "2G","nodes": 1}]' $SCRIPT_DIR/run.sh join

master_name=$MASTER_NAME vm=ubuntu-worker topology='[{"cores": 2, "mem": "2G","nodes": 2}]' $SCRIPT_DIR/run.sh join

master_name=$MASTER_NAME vm=fedora-worker-3 distro=fedora topology='[{"cores": 2, "mem": "2G", "nodes": 4}]' $SCRIPT_DIR/run.sh join
