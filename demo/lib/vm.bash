# shellcheck disable=SC1091
# shellcheck source=command.bash
source "$(dirname "${BASH_SOURCE[0]}")/command.bash"
# shellcheck disable=SC1091
# shellcheck source=distro.bash
source "$(dirname "${BASH_SOURCE[0]}")/distro.bash"

VM_PROMPT=${VM_PROMPT-"\e[38;5;11mroot@vm>\e[0m "}

vm-compose-govm-template() {
    (echo "
vms:
  - name: ${VM_NAME}
    image: ${VM_IMAGE}
    cloud: true
    ContainerEnvVars:
      - KVM_CPU_OPTS=${VM_QEMU_CPUMEM:=-machine pc -smp cpus=4 -m 8G}
      - EXTRA_QEMU_OPTS=-monitor unix:/data/monitor,server,nowait ${VM_QEMU_EXTRA}
      - USE_NET_BRIDGES=${USE_NET_BRIDGES:-0}
    user-data: |
      #!/bin/bash
      set -e
"
     (if [ -n "$VM_EXTRA_BOOTSTRAP_COMMANDS" ]; then
          # shellcheck disable=SC2001
          sed 's/^/      /g' <<< "${VM_EXTRA_BOOTSTRAP_COMMANDS}"
     fi
      # shellcheck disable=SC2001
      sed 's/^/      /g' <<< "$(distro-bootstrap-commands)")) |
        grep -E -v '^ *$'
}

vm-image-url() {
    distro-image-url
}

vm-ssh-user() {
    if [ -n "$VM_SSH_USER" ]; then
        echo "$VM_SSH_USER"
    else
        distro-ssh-user
    fi
}

vm-check-env() {
    type -p govm >& /dev/null || {
        echo "ERROR:"
        echo "ERROR: environment check failed:"
        echo "ERROR:   govm binary not found."
        echo "ERROR:"
        echo "ERROR: You can install it using the following commands:"
        echo "ERROR:"
        echo "ERROR:     git clone https://github.com/govm-project/govm"
        echo "ERROR:     cd govm"
        echo "ERROR:     go build -o govm"
        echo "ERROR:     cp -v govm \$GOPATH/bin"
        echo "ERROR:     docker build . -t govm/govm:latest"
        echo "ERROR:     cd .."
        echo "ERROR:"
        return 1
    }
    docker inspect govm/govm >& /dev/null || {
        echo "ERROR:"
        echo "ERROR: environment check failed:"
        echo "ERROR:   govm/govm docker image not present (but govm needs it)."
        echo "ERROR:"
        echo "ERROR: You can install it using the following commands:"
        echo "ERROR:"
        echo "ERROR:     git clone https://github.com/govm-project/govm"
        echo "ERROR:     cd govm"
        echo "ERROR:     docker build . -t govm/govm:latest"
        echo "ERROR:     cd .."
        echo "ERROR:"
        return 1
    }
    if [ ! -e "$SSH_KEY".pub ]; then
        echo "ERROR:"
        echo "ERROR: environment check failed:"
        echo "ERROR:   $SSH_KEY.pub SSH public key not found (but govm needs it)."
        echo "ERROR:"
        echo "ERROR: You can generate it using the following command:"
        echo "ERROR:"
        echo "ERROR:     ssh-keygen"
        echo "ERROR:"
        return 1
    fi
    if [ -n "$SSH_AUTH_SOCK" ] && [ -e "$SSH_AUTH_SOCK" ]; then
        if ! ssh-add -l | grep -q "$(ssh-keygen -l -f "$SSH_KEY" < /dev/null 2>/dev/null | awk '{print $2}')"; then
            if ! ssh-add "$SSH_KEY" < /dev/null; then
                echo "ERROR:"
                echo "ERROR: environment setup failed:"
                echo "ERROR:   Failed to load $SSH_KEY SSH key to agent."
                echo "ERROR:"
                echo "ERROR: Please make sure an SSH agent is running, then"
                echo "ERROR: try loading the key using the following command:"
                echo "ERROR:"
                echo "ERROR:     ssh-add $SSH_KEY"
                echo "ERROR:"
                return 1
            fi
        fi
    else
        if host-is-encrypted-ssh-key "$SSH_KEY"; then
            echo "ERROR:"
            echo "ERROR: environment setup failed:"
            echo "ERROR:   $SSH_KEY SSH key is encrypted, but agent is not running."
            echo "ERROR:"
            echo "ERROR: Please make sure an SSH agent is running, then"
            echo "ERROR: try loading the key using the following command:"
            echo "ERROR:"
            echo "ERROR:     ssh-add $SSH_KEY"
            echo "ERROR:"
            return 1
        fi
    fi
}

vm-check-binary-cri-resmgr() {
    # Check running cri-resmgr version, print warning if it is not
    # the latest local build.
    # shellcheck disable=SC2016
    if [ -f "$BIN_DIR/cri-resmgr" ] && [ "$(vm-command-q 'md5sum < /proc/$(pidof cri-resmgr)/exe')" != "$(md5sum < "$BIN_DIR/cri-resmgr")" ]; then
        echo "WARNING:"
        echo "WARNING: Running cri-resmgr binary is different from"
        echo "WARNING: $BIN_DIR/cri-resmgr"
        echo "WARNING: Consider restarting with \"reinstall_cri_resmgr=1\" or"
        echo "WARNING: run.sh> uninstall cri-resmgr; install cri-resmgr; launch cri-resmgr"
        echo "WARNING:"
        sleep "${warning_delay:-0}"
        return 1
    fi
    return 0
}

vm-command() { # script API
    # Usage: vm-command COMMAND
    #
    # Execute COMMAND on virtual machine as root.
    # Returns the exit status of the execution.
    # Environment variable COMMAND_OUTPUT contains what COMMAND printed
    # in standard output and error.
    #
    # Examples:
    #   vm-command "kubectl get pods"
    #   vm-command "whoami | grep myuser" || command-error "user is not myuser"
    command-start "vm" "$VM_PROMPT" "$1"
    if [ "$2" == "bg" ]; then
        ( $SSH "${VM_SSH_USER}@${VM_IP}" sudo bash -l <<<"$COMMAND" 2>&1 | command-handle-output ;
          command-end "${PIPESTATUS[0]}"
        ) &
        command-runs-in-bg
    else
        $SSH "${VM_SSH_USER}@${VM_IP}" sudo bash -l <<<"$COMMAND" 2>&1 | command-handle-output ;
        command-end "${PIPESTATUS[0]}"
    fi
    return "$COMMAND_STATUS"
}

vm-command-q() {
    $SSH "${VM_SSH_USER}@${VM_IP}" sudo bash -l <<<"$1"
}

vm-mem-hotplug() { # script API
    # Usage: vm-mem-hotplug MEMORY
    #
    # Hotplug currently unplugged MEMORY to VM.
    # Find unplugged memory with "vm-mem-hw | grep unplugged".
    #
    # Examples:
    #   vm-mem-hotplug mem2
    local memmatch memline memid memdimm memnode memdriver
    memmatch=$1
    if [ -z "$memmatch" ]; then
        error "missing MEMORY"
        return 1
    fi
    memline="$(vm-mem-hw | grep unplugged | grep "$memmatch")"
    if [ -z "$memline" ]; then
        error "unplugged memory matching '$memmatch' not found"
        return 1
    fi
    memid="$(awk '{print $1}' <<< "$memline")"
    memid=${memid#mem}
    memid=${memid%[: ]*}
    memdimm="$(awk '{print $2}' <<< "$memline")"
    memnode="$(awk '{print $4}' <<< "$memline")"
    memnode=${memnode#node}
    if [ "$memdimm" == "nvdimm" ]; then
        memdriver="nvdimm"
    else
        memdriver="pc-dimm"
    fi
    vm-monitor "device_add ${memdriver},id=${memdimm}${memid},memdev=mem${memdimm}_${memid}_node_${memnode},node=${memnode}"
}

vm-mem-hotremove() { # script API
    # Usage: vm-mem-hotremove MEMORY
    #
    # Hotremove currently plugged MEMORY from VM.
    # Find plugged memory with "vm-mem-hw | grep ' plugged'".
    #
    # Examples:
    #   vm-mem-hotremove mem2
    local memmatch memline memid memdimm memnode memdriver
    memmatch=$1
    if [ -z "$memmatch" ]; then
        error "missing MEMORY"
        return 1
    fi
    memline="$(vm-mem-hw | grep \ plugged | grep "$memmatch")"
    if [ -z "$memline" ]; then
        error "plugged memory matching '$memmatch' not found"
        return 1
    fi
    memid="$(awk '{print $1}' <<< "$memline")"
    memid=${memid#mem}
    memid=${memid%[: ]*}
    memdimm="$(awk '{print $2}' <<< "$memline")"
    vm-monitor "device_del ${memdimm}${memid}"
}

vm-mem-hw() { # script API
    # Usage: vm-mem-hw
    #
    # List VM memory hardware with current status.
    # See also: vm-mem-hotplug, vm-mem-hotremove
    vm-monitor "$(echo info memdev; echo info memory-devices)" | awk '
      /memdev: /{
          split($2,a,"_");
          state[a[2]]="plugged  ";
      }
      /memory backend: membuiltin/{
          split($3,a,"_"); backend=1;
          type[a[2]]="ram    "; state[a[2]]="builtin  "; node[a[2]]=a[4];
      }
      /memory backend: memnvbuiltin/{
          split($3,a,"_"); backend=1;
          type[a[2]]="nvram  "; state[a[2]]="builtin  "; node[a[2]]=a[4];
      }
      /memory backend: memnvdimm/{
          split($3,a,"_"); backend=1;
          type[a[2]]="nvdimm "; state[a[2]]="unplugged"; node[a[2]]=a[4];
      }
      /memory backend: memdimm/{
          split($3,a,"_"); backend=1;
          type[a[2]]="dimm   "; state[a[2]]="unplugged"; node[a[2]]=a[4];
      }
      /size: /{sz=$2/1024/1024; if (backend==1) {size[a[2]]=sz;backend=0;}}
      END{
          for (m in node) print "mem"m": "type[m]" "state[m]" node"node[m]" size="size[m]"M";
      }'
}

vm-monitor() { # script API
    # Usage: vm-monitor COMMAND
    #
    # Execute COMMAND on Qemu monitor.
    #
    # Example: VM monitor help:
    #  vm-monitor "help" | less
    #
    # Example: print memdev objects and plugged in memory devices:
    #  vm-monitor "info memdev"
    #  vm-monitor "info memory-devices"
    #
    # Example: hot plug a NVDIMM to NUMA node 1 when launched with topology
    # topology='[{"cores":2,"mem":"2G"},{"nvmem":"4G","dimm":"unplugged"}]':
    #   vm-monitor "device_add pc-dimm,id=nvdimm0,memdev=nvmem0,node=1"
    [ -n "$VM_MONITOR" ] ||
        error "VM is not running"
    eval "$VM_MONITOR" <<< "$1" | sed 's/\r//g'
    if [ "${PIPESTATUS[0]}" != "0" ]; then
        error "sending command to Qemu monitor failed"
    fi
    echo ""
}

vm-wait-process() { # script API
    # Usage: vm-wait-process [--timeout TIMEOUT] PROCESS
    #
    # Wait for a PROCESS (string) to appear in process list (ps -A output).
    # The default TIMEOUT is 30 seconds.
    local process timeout invalid
    timeout=30
    while [ "${1#-}" != "$1" ] && [ -n "$1" ]; do
        case "$1" in
            --timeout)
                timeout="$2"
                shift; shift
                ;;
            *)
                invalid="${invalid}${invalid:+,}\"$1\""
                shift
                ;;
        esac
    done
    if [ -n "$invalid" ]; then
        error "invalid options: $invalid"
        return 1
    fi
    process="$1"
    vm-run-until --timeout "$timeout" "ps -A | grep -q \"$process\""
}

vm-run-until() { # script API
    # Usage: vm-run-until [--timeout TIMEOUT] CMD
    #
    # Keep running CMD (string) until it exits successfully.
    # The default TIMEOUT is 30 seconds.
    local cmd timeout invalid
    timeout=30
    while [ "${1#-}" != "$1" ] && [ -n "$1" ]; do
        case "$1" in
            --timeout)
                timeout="$2"
                shift; shift
                ;;
            *)
                invalid="${invalid}${invalid:+,}\"$1\""
                shift
                ;;
        esac
    done
    if [ -n "$invalid" ]; then
        error "invalid options: $invalid"
        return 1
    fi
    cmd="$1"
    if ! vm-command-q "retry=$timeout; until $cmd; do retry=\$(( \$retry - 1 )); [ \"\$retry\" == \"0\" ] && exit 1; sleep 1; done"; then
        error "waiting for command \"$cmd\" to exit successfully timed out after $timeout s"
    fi
}

vm-write-file() {
    local vm_path_file="$1"
    local file_content_b64
    file_content_b64="$(base64 <<<"$2")"
    vm-command-q "mkdir -p $(dirname "$vm_path_file"); echo -n \"$file_content_b64\" | base64 -d > \"$vm_path_file\""
}

vm-put-file() { # script API
    # Usage: vm-put-file [--cleanup] [--append] SRC-HOST-FILE DST-VM-FILE
    #
    # Copy SRC-HOST-FILE to DST-VM-FILE on the VM, removing
    # SRC-HOST-FILE if called with the --cleanup flag, and
    # appending instead of copying if the --append flag is
    # specified.
    #
    # Example:
    #   src=$(mktemp) && \
    #       echo 'Ahoy, Matey...' > $src && \
    #       vm-put-file --cleanup $src /etc/motd
    local cleanup append invalid
    while [ "${1#-}" != "$1" ] && [ -n "$1" ]; do
        case "$1" in
            --cleanup)
                cleanup=1
                shift
                ;;
            --append)
                append=1
                shift
                ;;
            *)
                invalid="${invalid}${invalid:+,}\"$1\""
                shift
                ;;
        esac
    done
    if [ -n "$cleanup" ] && [ -n "$1" ]; then
        # shellcheck disable=SC2064
        trap "rm -f \"$1\"" RETURN EXIT
    fi
    if [ -n "$invalid" ]; then
        error "invalid options: $invalid"
        return 1
    fi
    [ "$(dirname "$2")" == "." ] || vm-command-q "[ -d \"$(dirname "$2")\" ]" || vm-command "mkdir -p \"$(dirname "$2")\"" ||
        command-error "cannot create vm-put-file destination directory to VM"
    host-command "$SCP \"$1\" ${VM_SSH_USER}@${VM_IP}:\"vm-put-file.${1##*/}\"" ||
        command-error "failed to copy file to VM"
    if [ -z "$append" ]; then
        vm-command "mv \"vm-put-file.${1##*/}\" \"$2\"" ||
            command-error "failed to rename file"
    else
        vm-command "touch \"$2\" && cat \"vm-put-file.${1##*/}\" >> \"$2\" && rm -f \"vm-put-file.${1##*/}\"" ||
            command-error "failed to append file"
    fi
}

vm-pipe-to-file() { # script API
    # Usage: vm-pipe-to-file [--append] DST-VM-FILE
    #
    # Reads stdin and writes the content to DST-VM-FILE, creating any
    # intermediate directories necessary.
    #
    # Example:
    #   echo 'Ahoy, Matey...' | vm-pipe-to-file /etc/motd
    local tmp append
    tmp="$(mktemp vm-pipe-to-file.XXXXXX)"
    if [ "$1" = "--append" ]; then
        append="--append"
        shift
    fi
    cat > "$tmp"
    vm-put-file --cleanup $append "$tmp" "$1"
}

vm-sed-file() { # script API
    # Usage: vm-sed-file PATH-IN-VM SED-EXTENDED-REGEXP-COMMANDS
    #
    # Edits the given file in place with the given extended regexp
    # sed commands.
    #
    # Example:
    #   vm-sed-file /etc/motd 's/Matey/Guybrush Threepwood/'
    local file="$1" cmd
    shift
    for cmd in "$@"; do
        vm-command "sed -E -i \"$cmd\" $file" ||
            command-error "failed to edit $file with sed"
    done
}

vm-set-kernel-cmdline() { # script API
    # Usage: vm-set-kernel-cmdline E2E-DEFAULTS
    #
    # Adds/replaces E2E-DEFAULTS to kernel command line"
    #
    # Example:
    #   vm-set-kernel-cmdline nr_cpus=4
    #   vm-reboot
    #   vm-command "cat /proc/cmdline"
    #   launch cri-resmgr
    distro-set-kernel-cmdline "$@"
}

vm-reboot() { # script API
    # Usage: vm-reboot
    #
    # Reboots the virtual machine and waits that the ssh server starts
    # responding again.
    vm-command "reboot"
    sleep 5
    host-wait-vm-ssh-server
}

vm-networking() {
    vm-command-q "touch /etc/hosts; grep -q \$(hostname) /etc/hosts" || {
        vm-command "echo \"$VM_IP \$(hostname)\" >>/etc/hosts"
    }
    distro-setup-proxies
}

vm-install-cri-resmgr() {
    prefix=/usr/local
    # shellcheck disable=SC2154
    if [ "$binsrc" == "github" ]; then
        vm-install-golang
        vm-install-pkg make
        vm-command "go get -d -v github.com/intel/cri-resource-manager"
        CRI_RESMGR_SOURCE_DIR=$(awk '/package.*cri-resource-manager/{print $NF}' <<< "$COMMAND_OUTPUT")
        vm-command "cd $CRI_RESMGR_SOURCE_DIR && make install && cd -"
    elif [ "${binsrc#packages/}" != "$binsrc" ]; then
        suf=$(vm-pkg-type)
        vm-command "rm -f *.$suf"
        local pkg_count
        # shellcheck disable=SC2010,SC2126
        pkg_count="$(ls "$HOST_PROJECT_DIR/$binsrc"/cri-resource-manager*."$suf" | grep -v dbg | wc -l)"
        if [ "$pkg_count" == "0" ]; then
            error "installing from $binsrc failed: cannot find cri-resource-manager_*.$suf from $HOST_PROJECT_DIR/$binsrc"
        elif [[ "$pkg_count" -gt 1 ]]; then
            error "installing from $binsrc failed: expected exactly one cri-resource-manager*.$suf in $HOST_PROJECT_DIR/$binsrc, found $pkg_count alternatives."
        fi
        host-command "$SCP $HOST_PROJECT_DIR/$binsrc/*.$suf $VM_SSH_USER@$VM_IP:/tmp" || {
            command-error "copying *.$suf to vm failed, run \"make cross-$suf\" first"
        }
        vm-install-pkg "/tmp/cri-resource-manager*.$suf" || {
            command-error "installing packages failed"
        }
        vm-command "systemctl daemon-reload"
    elif [ -z "$binsrc" ] || [ "$binsrc" == "local" ]; then
        local bin_change
        local src_change
        bin_change=$(stat --format "%Z" "$BIN_DIR/cri-resmgr")
        src_change=$(find "$HOST_PROJECT_DIR" -name '*.go' -type f -print0 | xargs -0 stat --format "%Z" | sort -n | tail -n 1)
        if [[ "$src_change" > "$bin_change" ]]; then
            echo "WARNING:"
            echo "WARNING: Source files changed - installing possibly outdated binaries from"
            echo "WARNING: $BIN_DIR/"
            echo "WARNING:"
            sleep "${warning_delay:-0}"
        fi
        vm-put-file "$BIN_DIR/cri-resmgr" "$prefix/bin/cri-resmgr"
        vm-put-file "$BIN_DIR/cri-resmgr-agent" "$prefix/bin/cri-resmgr-agent"
    else
        error "vm-install-cri-resmgr: unknown binsrc=\"$binsrc\""
    fi
}

vm-install-cri-resmgr-agent() {
    prefix=/usr/local
    local bin_change
    local src_change
    bin_change=$(stat --format "%Z" "$BIN_DIR/cri-resmgr-agent")
    src_change=$(find "$HOST_PROJECT_DIR" -name '*.go' -type f -print0 | xargs -0 stat --format "%Z" | sort -n | tail -n 1)
    if [[ "$src_change" > "$bin_change" ]]; then
        echo "WARNING:"
        echo "WARNING: Source files changed - installing possibly outdated binaries from"
        echo "WARNING: $BIN_DIR/"
        echo "WARNING:"
        sleep "${warning_delay:-0}"
    fi
    vm-put-file "$BIN_DIR/cri-resmgr-agent" "$prefix/bin/cri-resmgr-agent"
}

vm-cri-import-image() {
    local image_name="$1"
    local image_tar="$2"
    case "$VM_CRI" in
        containerd)
            vm-command "ctr -n k8s.io images import '$image_tar'" ||
                command-error "failed to import \"$image_tar\" on VM"
            ;;
        *)
            error "vm-cri-import-image unsupported container runtime: \"$VM_CRI\""
    esac
}

vm-put-docker-image() {
    local image_name="$1"
    local image_file_on_vm="images/${image_name//:/__}"
    vm-command-q "mkdir -p $(dirname "$image_file_on_vm")"
    docker save "$image_name" | vm-pipe-to-file "$image_file_on_vm" ||
        error "failed to save and pipe image '$image_name'"
    vm-cri-import-image "$image_name" "$image_file_on_vm"
}

vm-install-cri-resmgr-webhook() {
    local service=cri-resmgr-webhook
    local namespace=cri-resmgr
    vm-command-q "\
        kubectl delete secret -n ${namespace} cri-resmgr-webhook-secret 2>/dev/null; \
        kubectl delete csr ${service}.${namespace} 2>/dev/null; \
        kubectl delete -f webhook/mutating-webhook-config.yaml 2>/dev/null; \
        kubectl delete -f webhook/webhook-deployment.yaml 2>/dev/null; \
        "
    local webhook_image_info webhook_image_id webhook_image_repotag webhook_image_tar
    webhook_image_info="$(docker images --filter=reference=cri-resmgr-webhook --format '{{.ID}} {{.Repository}}:{{.Tag}} (created {{.CreatedSince}}, {{.CreatedAt}})' | head -n 1)"
    if [ -z "$webhook_image_info" ]; then
        error "cannot find cri-resmgr-webhook image on host, run \"make images\" and check \"docker images --filter=reference=cri-resmgr-webhook\""
    fi
    echo "installing webhook to VM from image: $webhook_image_info"
    sleep 2
    webhook_image_id="$(awk '{print $1}' <<< "$webhook_image_info")"
    webhook_image_repotag="$(awk '{print $2}' <<< "$webhook_image_info")"
    webhook_image_tar="$(realpath "$OUTPUT_DIR/webhook-image-$webhook_image_id.tar")"
    # It is better to export (save) the image with image_repotag rather than image_id
    # because otherwise manifest.json RepoTags will be null and containerd will
    # remove the image immediately after impoting it as part of garbage collection.
    docker image save "$webhook_image_repotag" > "$webhook_image_tar"
    vm-put-file "$webhook_image_tar" "webhook/$(basename "$webhook_image_tar")" || {
        command-error "copying webhook image to VM failed"
    }
    vm-cri-import-image cri-resmgr-webhook "webhook/$(basename "$webhook_image_tar")"
    # Create a self-signed certificate with SANs
    vm-command "openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes -keyout webhook/server-key.pem -out webhook/server-crt.pem -subj '/CN=${service}.${namespace}.svc' -addext 'subjectAltName=DNS:${service},DNS:${service}.${namespace},DNS:${service}.${namespace}.svc'" ||
        command-error "creating self-signed certificate failed, requires openssl >= 1.1.1"
    # Allow webhook to run on node tainted by cmk=true
    sed -e "s|IMAGE_PLACEHOLDER|$webhook_image_repotag|" \
        -e 's|^\(\s*\)tolerations:$|\1tolerations:\n\1  - {"key": "cmk", "operator": "Equal", "value": "true", "effect": "NoSchedule"}|g' \
        -e 's/imagePullPolicy: Always/imagePullPolicy: Never/' \
        < "${HOST_PROJECT_DIR}/cmd/cri-resmgr-webhook/webhook-deployment.yaml" \
        | vm-pipe-to-file webhook/webhook-deployment.yaml
    # Create secret that contains svc.crt and svc.key for webhook deployment
    local server_crt_b64 server_key_b64
    server_crt_b64="$(vm-command-q "cat webhook/server-crt.pem" | base64 -w 0)"
    server_key_b64="$(vm-command-q "cat webhook/server-key.pem" | base64 -w 0)"
    cat <<EOF | vm-pipe-to-file --append webhook/webhook-deployment.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: cri-resmgr-webhook-secret
  namespace: cri-resmgr
data:
  svc.crt: ${server_crt_b64}
  svc.key: ${server_key_b64}
type: Opaque
EOF
    local cabundle_b64
    cabundle_b64="$server_crt_b64"
    sed -e "s/CA_BUNDLE_PLACEHOLDER/${cabundle_b64}/" \
        < "${HOST_PROJECT_DIR}/cmd/cri-resmgr-webhook/mutating-webhook-config.yaml" \
        | vm-pipe-to-file webhook/mutating-webhook-config.yaml
}

vm-pkg-type() {
    distro-pkg-type
}

vm-install-pkg() {
    distro-install-pkg "$@"
}

vm-install-golang() {
    distro-install-golang
}

vm-install-cri() {
    distro-install-"$VM_CRI"
    distro-config-"$VM_CRI"
}

vm-install-containernetworking() {
    vm-install-golang
    vm-command "go get -d github.com/containernetworking/plugins"
    CNI_PLUGINS_SOURCE_DIR="$(awk '/package.*plugins/{print $NF}' <<< "$COMMAND_OUTPUT")"
    [ -n "$CNI_PLUGINS_SOURCE_DIR" ] || {
        command-error "downloading containernetworking plugins failed"
    }
    vm-command "pushd \"$CNI_PLUGINS_SOURCE_DIR\" && ./build_linux.sh && mkdir -p /opt/cni && cp -rv bin /opt/cni && popd" || {
        command-error "building and installing cri-tools failed"
    }
    vm-command "rm -rf /etc/cni/net.d && mkdir -p /etc/cni/net.d && cat > /etc/cni/net.d/10-bridge.conf <<EOF
{
  \"cniVersion\": \"0.4.0\",
  \"name\": \"mynet\",
  \"type\": \"bridge\",
  \"bridge\": \"cni0\",
  \"isGateway\": true,
  \"ipMasq\": true,
  \"ipam\": {
    \"type\": \"host-local\",
    \"subnet\": \"$CNI_SUBNET\",
    \"routes\": [
      { \"dst\": \"0.0.0.0/0\" }
    ]
  }
}
EOF"
    vm-command 'cat > /etc/cni/net.d/20-portmap.conf <<EOF
{
    "cniVersion": "0.4.0",
    "type": "portmap",
    "capabilities": {"portMappings": true},
    "snat": true
}
EOF'
    vm-command 'cat > /etc/cni/net.d/99-loopback.conf <<EOF
{
  "cniVersion": "0.4.0",
  "name": "lo",
  "type": "loopback"
}
EOF'
}

vm-install-k8s() {
    distro-install-k8s
    distro-restart-$VM_CRI
}

vm-create-singlenode-cluster() {
    vm-create-cluster
    vm-command "kubectl taint nodes $vm node-role.kubernetes.io/master:NoSchedule-"
    if [ $mode == "init" ]; then
	vm-install-flannel
    else	
        vm-install-cni-"$(distro-k8s-cni)"
    fi
    if ! vm-command "kubectl wait --for=condition=Ready node/\$(hostname) --timeout=120s"; then
        command-error "kubectl waiting for node readiness timed out"
    fi
}

vm-node-join-cluster(){
    KUBE_JOIN=$(cat $HOME/.kubeadm-join)
    vm-command 	"$KUBE_JOIN --v=5"
}

vm-create-cluster() {
    if [ $mode == "init" ]; then
        vm-master-config	    
        vm-command "kubeadm init --pod-network-cidr=$CNI_SUBNET"
    else
        vm-command "kubeadm init --pod-network-cidr=$CNI_SUBNET --cri-socket /var/run/cri-resmgr/cri-resmgr.sock"
    fi	    
    if ! grep -q "initialized successfully" <<< "$COMMAND_OUTPUT"; then
        command-error "kubeadm init failed"
    fi
    vm-command "mkdir -p \$HOME/.kube"
    vm-command "cp /etc/kubernetes/admin.conf \$HOME/.kube/config"
    vm-command "mkdir -p ~root/.kube"
    vm-command "cp /etc/kubernetes/admin.conf ~root/.kube/config"
}

vm-install-flannel(){
   vm-command "kubectl create -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
   if ! vm-command "kubectl rollout status --timeout=360s -n kube-system daemonsets/kube-flannel-ds"; then
	command-error "installing flannel to Kubernetes timed out"
   fi	
}

vm-install-cni-cilium() {
    vm-command "kubectl create -f https://raw.githubusercontent.com/cilium/cilium/v1.8/install/kubernetes/quick-install.yaml"
    if ! vm-command "kubectl rollout status --timeout=360s -n kube-system daemonsets/cilium"; then
        command-error "installing cilium CNI to Kubernetes timed out"
    fi
}

vm-install-cni-weavenet() {
    vm-command "kubectl apply -f \"https://cloud.weave.works/k8s/net?k8s-version=\$(kubectl version | base64 | tr -d '\n')\""
    if ! vm-command "kubectl rollout status --timeout=360s -n kube-system daemonsets/weave-net"; then
        command-error "installing weavenet CNI to Kubernetes failed/timed out"
    fi
}

vm-print-usage() {
    echo "- Login VM:     ssh $VM_SSH_USER@$VM_IP"
    echo "- Stop VM:      govm stop $VM_NAME"
    echo "- Delete VM:    govm delete $VM_NAME"
}

vm-check-env || exit 1
