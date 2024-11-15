#!/bin/bash

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --mode <normal|tdx>       VM mode (default: normal)"
    echo "  --image PATH              Path to VM image (required)"
    echo "  --ram SIZE                RAM size in GB (default: 32)"
    echo "  --cpus NUMBER             Number of CPUs (default: 16)"
    echo "  --ssh-port PORT           SSH port forwarding (default: 10022)"
    echo "  --ports PORTS             Additional ports to open, comma-separated"
    echo "  --name STRING             Process name (default: qemu-vm)"
    echo "  --log PATH                Log file path (default: /tmp/qemu-guest.log)"
    echo "  --ovmf PATH               Path to OVMF firmware (default: /usr/share/ovmf/OVMF.fd)"
    echo "  --help                    Show this help message"
    exit 1
}

cleanup() {
    rm -f /tmp/qemu-guest*.log &> /dev/null
    rm -f /tmp/qemu-*-monitor.sock &> /dev/null

    PID_QEMU=$(cat /tmp/qemu-pid.pid 2> /dev/null)
    [ ! -z "$PID_QEMU" ] && echo "Cleanup, kill VM with PID: ${PID_QEMU}" && kill -TERM ${PID_QEMU} &> /dev/null
    sleep 3
}

# Default values
MODE="normal"
RAM_SIZE="32"
CPUS="16"
SSH_PORT="10022"
ADDITIONAL_PORTS=""
PROCESS_NAME="qemu-vm"
LOGFILE="/tmp/qemu-guest.log"
OVMF_PATH="/usr/share/ovmf/OVMF.fd"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --image)
            VM_IMG="$2"
            shift 2
            ;;
        --ram)
            RAM_SIZE="$2"
            shift 2
            ;;
        --cpus)
            CPUS="$2"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        --ports)
            ADDITIONAL_PORTS="$2"
            shift 2
            ;;
        --name)
            PROCESS_NAME="$2"
            shift 2
            ;;
        --log)
            LOGFILE="$2"
            shift 2
            ;;
        --ovmf)
            OVMF_PATH="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check required parameters
if [ -z "$VM_IMG" ]; then
    echo "Error: VM image path is required"
    usage
fi

# Verify mode
if [ "$MODE" != "normal" ] && [ "$MODE" != "tdx" ]; then
    echo "Error: Invalid mode. Must be 'normal' or 'tdx'"
    usage
fi

# Check KVM group membership
if ! groups | grep -qw "kvm"; then
    echo "Please add user $USER to kvm group to run this script (usermod -aG kvm $USER and then log in again)."
    exit 1
fi

# Clean up any existing instances
cleanup
if [ "$1" = "clean" ]; then
    exit 0
fi

# Prepare port forwarding string
PORT_FORWARDS="-device virtio-net-pci,netdev=nic0 -netdev user,id=nic0,hostfwd=tcp::${SSH_PORT}-:22"

# Add default flashbox ports
PORT_FORWARDS="${PORT_FORWARDS},hostfwd=tcp::24070-:24070,hostfwd=tcp::24071-:24071"

# Add additional ports if specified
if [ ! -z "$ADDITIONAL_PORTS" ]; then
    IFS=',' read -ra PORTS <<< "$ADDITIONAL_PORTS"
    for port in "${PORTS[@]}"; do
        PORT_FORWARDS="${PORT_FORWARDS},hostfwd=tcp::${port}-:${port}"
    done
fi

# Base QEMU command
QEMU_CMD="qemu-system-x86_64 -D $LOGFILE \
    -accel kvm \
    -m ${RAM_SIZE}G -smp $CPUS \
    -name ${PROCESS_NAME},process=${PROCESS_NAME},debug-threads=on \
    -cpu host \
    -nographic \
    -nodefaults \
    ${PORT_FORWARDS} \
    -drive file=${VM_IMG},if=none,id=virtio-disk0 \
    -device virtio-blk-pci,drive=virtio-disk0 \
    -bios ${OVMF_PATH} \
    -chardev stdio,id=char0,mux=on,signal=off \
    -mon chardev=char0 \
    -serial chardev:char0 \
    -pidfile /tmp/qemu-pid.pid"

# Add TDX-specific parameters if mode is tdx
if [ "$MODE" = "tdx" ]; then
    QEMU_CMD="$QEMU_CMD \
        -object '{\"qom-type\":\"tdx-guest\",\"id\":\"tdx\",\"quote-generation-socket\":{\"type\": \"vsock\", \"cid\":\"2\",\"port\":\"4050\"}}' \
        -machine q35,kernel_irqchip=split,confidential-guest-support=tdx,hpet=off \
        -device vhost-vsock-pci,guest-cid=4"
else
    QEMU_CMD="$QEMU_CMD \
        -machine q35"
fi

# Execute QEMU command
eval $QEMU_CMD

ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Failed to create VM. Please check logfile \"$LOGFILE\" for more information."
    exit $ret
fi

PID_QEMU=$(cat /tmp/qemu-pid.pid)

echo "VM started in $MODE mode with PID: ${PID_QEMU}"
echo "To login via SSH: ssh -p $SSH_PORT root@localhost"
