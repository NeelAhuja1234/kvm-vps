#!/bin/bash
set -Eeuo pipefail

# ============================================================
# NEELCRAFT - Enhanced Multi VM Manager
# Stable / Persistent / Safer QEMU VM Manager
# Made By NEELCRAFT
# ============================================================

SCRIPT_VERSION="2.0.0"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

BASE_DIR="${NEELCRAFT_VM_HOME:-/var/lib/neelcraft-vms}"
VM_DIR="$BASE_DIR/vms"
TMP_DIR="$BASE_DIR/tmp"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$VM_DIR" "$TMP_DIR" "$LOG_DIR"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

display_header() {
    clear 2>/dev/null || true

    cat <<'EOF'
===========================================================

    _   _ _____ _____ _     ____ ____      _    _____ _____
   | \ | | ____| ____| |   / ___|  _ \    / \  |  ___|_   _|
   |  \| |  _| |  _| | |  | |   | |_) |  / _ \ | |_    | |
   | |\  | |___| |___| |__| |___|  _ <  / ___ \|  _|   | |
   |_| \_|_____|_____|_____\____|_| \_\/_/   \_\_|     |_|

                    MADE BY NEELCRAFT

===========================================================
EOF

    echo
    echo -e "${CYAN}VM Manager Version: ${SCRIPT_VERSION}${RESET}"
    echo
}

# ------------------------------------------------------------
# Output
# ------------------------------------------------------------

print_status() {
    local type="${1:-INFO}"
    local message="${2:-}"

    case "$type" in
        INFO)
            echo -e "${BLUE}[INFO]${RESET} $message"
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${RESET} $message"
            ;;
        ERROR)
            echo -e "${RED}[ERROR]${RESET} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${RESET} $message"
            ;;
        INPUT)
            echo -e "${CYAN}[INPUT]${RESET} $message"
            ;;
        *)
            echo "[$type] $message"
            ;;
    esac
}

# ------------------------------------------------------------
# Error handler
# ------------------------------------------------------------

error_handler() {
    local exit_code=$?
    local line_no=$1

    echo
    print_status "ERROR" "Unexpected error at line $line_no."
    print_status "ERROR" "Exit code: $exit_code"
    echo

    return "$exit_code"
}

trap 'error_handler $LINENO' ERR

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

cleanup() {
    find "$TMP_DIR" -maxdepth 1 -type f \
        \( -name "*.tmp" -o -name "*.part" \) \
        -delete 2>/dev/null || true
}

trap cleanup EXIT

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        print_status "ERROR" "Please run this script as root."
        echo
        echo "Example:"
        echo "sudo ./vm-manager.sh"
        exit 1
    fi
}

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

check_dependencies() {
    local missing=()

    local commands=(
        "qemu-system-x86_64"
        "qemu-img"
        "cloud-localds"
        "wget"
        "openssl"
        "ss"
        "pgrep"
        "pkill"
    )

    for command in "${commands[@]}"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            missing+=("$command")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        print_status "ERROR" "Missing dependencies:"
        echo

        for item in "${missing[@]}"; do
            echo "  - $item"
        done

        echo
        print_status "INFO" "Ubuntu/Debian installation:"
        echo
        echo "apt update"
        echo "apt install -y qemu-system-x86 qemu-utils cloud-image-utils wget openssl iproute2 procps"
        echo

        exit 1
    fi
}

# ------------------------------------------------------------
# OS definitions
# ------------------------------------------------------------

declare -A OS_OPTIONS

OS_OPTIONS["Ubuntu 24.04"]="Ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu-vm|ubuntu|ubuntu"
OS_OPTIONS["Ubuntu 22.04"]="Ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu-vm|ubuntu|ubuntu"
OS_OPTIONS["Debian 12"]="Debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|debian-vm|debian|debian"

OS_NAMES=(
    "Ubuntu 24.04"
    "Ubuntu 22.04"
    "Debian 12"
)

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

validate_input() {
    local type="$1"
    local value="$2"

    case "$type" in

        number)
            [[ "$value" =~ ^[0-9]+$ ]] || {
                print_status "ERROR" "Must be a number."
                return 1
            }
            ;;

        size)
            [[ "$value" =~ ^[0-9]+([GgMm])$ ]] || {
                print_status "ERROR" "Use a size such as 10G or 2048M."
                return 1
            }
            ;;

        port)
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Invalid port."
                return 1
            fi

            if (( value < 23 || value > 65535 )); then
                print_status "ERROR" "Port must be between 23 and 65535."
                return 1
            fi
            ;;

        name)
            [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || {
                print_status "ERROR" "Only letters, numbers, - and _ are allowed."
                return 1
            }
            ;;

        username)
            [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
                print_status "ERROR" "Invalid Linux username."
                return 1
            }
            ;;

        forward)
            [[ "$value" =~ ^[0-9]+:[0-9]+$ ]] || {
                print_status "ERROR" "Use HOST_PORT:GUEST_PORT."
                return 1
            }

            local host_port
            local guest_port

            IFS=':' read -r host_port guest_port <<< "$value"

            if (( host_port < 1 || host_port > 65535 )); then
                print_status "ERROR" "Invalid host port: $host_port"
                return 1
            fi

            if (( guest_port < 1 || guest_port > 65535 )); then
                print_status "ERROR" "Invalid guest port: $guest_port"
                return 1
            fi
            ;;

    esac

    return 0
}

# ------------------------------------------------------------
# Port check
# ------------------------------------------------------------

port_in_use() {
    local port="$1"

    ss -H -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(:|\])${port}$"
}

# ------------------------------------------------------------
# VM list
# ------------------------------------------------------------

get_vm_list() {
    find "$VM_DIR" -maxdepth 1 -type f -name "*.conf" \
        -printf "%f\n" 2>/dev/null |
        sed 's/\.conf$//' |
        sort
}

# ------------------------------------------------------------
# VM existence
# ------------------------------------------------------------

vm_exists() {
    local vm_name="$1"

    [[ -f "$VM_DIR/$vm_name.conf" ]]
}

# ------------------------------------------------------------
# VM config loader
# ------------------------------------------------------------

load_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name.conf"

    if [[ ! -f "$config_file" ]]; then
        print_status "ERROR" "VM '$vm_name' does not exist."
        return 1
    fi

    unset \
        VM_NAME \
        OS_TYPE \
        CODENAME \
        IMG_URL \
        HOSTNAME \
        USERNAME \
        PASSWORD \
        DISK_SIZE \
        MEMORY \
        CPUS \
        SSH_PORT \
        GUI_MODE \
        PORT_FORWARDS \
        IMG_FILE \
        SEED_FILE \
        PID_FILE \
        LOG_FILE \
        CREATED

    # shellcheck disable=SC1090
    source "$config_file"

    # Backward compatibility
    VM_NAME="${VM_NAME:-$vm_name}"
    PID_FILE="${PID_FILE:-$VM_DIR/$VM_NAME.pid}"
    LOG_FILE="${LOG_FILE:-$LOG_DIR/$VM_NAME.log}"

    return 0
}

# ------------------------------------------------------------
# Save config
# ------------------------------------------------------------

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    local tmp_config="$config_file.tmp"

    cat > "$tmp_config" <<EOF
VM_NAME=$(printf '%q' "$VM_NAME")
OS_TYPE=$(printf '%q' "$OS_TYPE")
CODENAME=$(printf '%q' "$CODENAME")
IMG_URL=$(printf '%q' "$IMG_URL")
HOSTNAME=$(printf '%q' "$HOSTNAME")
USERNAME=$(printf '%q' "$USERNAME")
PASSWORD=$(printf '%q' "$PASSWORD")
DISK_SIZE=$(printf '%q' "$DISK_SIZE")
MEMORY=$(printf '%q' "$MEMORY")
CPUS=$(printf '%q' "$CPUS")
SSH_PORT=$(printf '%q' "$SSH_PORT")
GUI_MODE=$(printf '%q' "$GUI_MODE")
PORT_FORWARDS=$(printf '%q' "$PORT_FORWARDS")
IMG_FILE=$(printf '%q' "$IMG_FILE")
SEED_FILE=$(printf '%q' "$SEED_FILE")
PID_FILE=$(printf '%q' "$PID_FILE")
LOG_FILE=$(printf '%q' "$LOG_FILE")
CREATED=$(printf '%q' "$CREATED")
EOF

    chmod 600 "$tmp_config"
    mv -f "$tmp_config" "$config_file"

    print_status "SUCCESS" "Configuration saved."
}

# ------------------------------------------------------------
# Generate cloud-init
# ------------------------------------------------------------

generate_cloud_init() {
    local user_data="$TMP_DIR/$VM_NAME-user-data"
    local meta_data="$TMP_DIR/$VM_NAME-meta-data"

    local password_hash

    password_hash="$(openssl passwd -6 "$PASSWORD")"

    cat > "$user_data" <<EOF
#cloud-config

hostname: $HOSTNAME
manage_etc_hosts: true

ssh_pwauth: true
disable_root: false

users:
  - name: $USERNAME
    gecos: NEELCRAFT VM User
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $password_hash

chpasswd:
  expire: false

package_update: false

ssh_deletekeys: false
EOF

    cat > "$meta_data" <<EOF
instance-id: iid-neelcraft-$VM_NAME
local-hostname: $HOSTNAME
EOF

    chmod 600 "$user_data" "$meta_data"

    if ! cloud-localds "$SEED_FILE" "$user_data" "$meta_data"; then
        rm -f "$user_data" "$meta_data"
        print_status "ERROR" "Failed to create cloud-init seed."
        return 1
    fi

    rm -f "$user_data" "$meta_data"

    chmod 600 "$SEED_FILE"

    return 0
}

# ------------------------------------------------------------
# Download image
# ------------------------------------------------------------

download_vm_image() {
    print_status "INFO" "Downloading VM image..."

    local temp_file="$IMG_FILE.part"

    rm -f "$temp_file"

    if ! wget \
        --https-only \
        --timeout=30 \
        --tries=5 \
        --continue \
        --show-progress \
        "$IMG_URL" \
        -O "$temp_file"; then

        rm -f "$temp_file"

        print_status "ERROR" "Image download failed."
        return 1
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        print_status "ERROR" "Downloaded image is empty."
        return 1
    fi

    mv -f "$temp_file" "$IMG_FILE"

    print_status "SUCCESS" "Image downloaded successfully."
}

# ------------------------------------------------------------
# Prepare disk
# ------------------------------------------------------------

prepare_disk() {
    if [[ ! -f "$IMG_FILE" ]]; then
        download_vm_image || return 1
    else
        print_status "INFO" "VM image already exists."
    fi

    print_status "INFO" "Checking disk image..."

    if ! qemu-img info "$IMG_FILE" >/dev/null 2>&1; then
        print_status "ERROR" "Invalid QEMU disk image."
        return 1
    fi

    local current_size
    current_size="$(qemu-img info --output=json "$IMG_FILE" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])' 2>/dev/null || echo "0")"

    if [[ "$current_size" == "0" ]]; then
        print_status "WARN" "Could not determine current disk size."
    else
        print_status "INFO" "Current virtual disk: $current_size bytes"
    fi

    # Resize only when the requested size is larger.
    # This prevents accidental shrinking and data loss.
    if qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "SUCCESS" "Disk size set to $DISK_SIZE."
    else
        print_status "WARN" "Disk resize could not be applied."
        print_status "INFO" "The existing disk image has NOT been deleted."
    fi

    return 0
}

# ------------------------------------------------------------
# Setup VM
# ------------------------------------------------------------

setup_vm_image() {
    mkdir -p "$VM_DIR" "$TMP_DIR" "$LOG_DIR"

    prepare_disk || return 1

    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "INFO" "Creating cloud-init seed..."
        generate_cloud_init || return 1
    fi

    print_status "SUCCESS" "VM '$VM_NAME' is ready."
}

# ------------------------------------------------------------
# Create VM
# ------------------------------------------------------------

create_new_vm() {

    display_header

    print_status "INFO" "Creating a new VM."
    echo

    local index=1
    local choice

    for os in "${OS_NAMES[@]}"; do
        echo "  $index) $os"
        ((index += 1))
    done

    echo

    while true; do
        read -r -p "Select OS: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 && choice <= ${#OS_NAMES[@]} )); then

            local selected_os="${OS_NAMES[$((choice - 1))]}"

            IFS='|' read -r \
                OS_TYPE \
                CODENAME \
                IMG_URL \
                DEFAULT_HOSTNAME \
                DEFAULT_USERNAME \
                DEFAULT_PASSWORD \
                <<< "${OS_OPTIONS[$selected_os]}"

            break
        fi

        print_status "ERROR" "Invalid selection."
    done

    # VM name
    while true; do
        read -r -p "VM name [$DEFAULT_HOSTNAME]: " VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"

        if ! validate_input name "$VM_NAME"; then
            continue
        fi

        if vm_exists "$VM_NAME"; then
            print_status "ERROR" "VM '$VM_NAME' already exists."
            continue
        fi

        break
    done

    # Hostname
    while true; do
        read -r -p "Hostname [$VM_NAME]: " HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"

        validate_input name "$HOSTNAME" && break
    done

    # Username
    while true; do
        read -r -p "Username [$DEFAULT_USERNAME]: " USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"

        validate_input username "$USERNAME" && break
    done

    # Password
    while true; do
        read -r -s -p "Password [$DEFAULT_PASSWORD]: " PASSWORD
        echo

        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"

        if [[ -n "$PASSWORD" ]]; then
            break
        fi

        print_status "ERROR" "Password cannot be empty."
    done

    # Disk
    while true; do
        read -r -p "Disk size [20G]: " DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"

        validate_input size "$DISK_SIZE" && break
    done

    # RAM
    while true; do
        read -r -p "Memory in MB [2048]: " MEMORY
        MEMORY="${MEMORY:-2048}"

        if validate_input number "$MEMORY" && (( MEMORY > 0 )); then
            break
        fi
    done

    # CPU
    while true; do
        read -r -p "CPU count [2]: " CPUS
        CPUS="${CPUS:-2}"

        if validate_input number "$CPUS" && (( CPUS > 0 )); then
            break
        fi
    done

    # SSH
    while true; do
        read -r -p "SSH port [2222]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"

        if ! validate_input port "$SSH_PORT"; then
            continue
        fi

        if port_in_use "$SSH_PORT"; then
            print_status "ERROR" "Port $SSH_PORT is already in use."
            continue
        fi

        break
    done

    # GUI
    while true; do
        read -r -p "Enable GUI? (y/N): " gui_input
        gui_input="${gui_input:-n}"

        case "$gui_input" in
            y|Y)
                GUI_MODE=true
                break
                ;;
            n|N)
                GUI_MODE=false
                break
                ;;
            *)
                print_status "ERROR" "Enter y or n."
                ;;
        esac
    done

    # Port forwards
    PORT_FORWARDS=""

    echo
    print_status "INFO" "Add additional port forwards."
    print_status "INFO" "Format: HOST_PORT:GUEST_PORT"
    print_status "INFO" "Example: 8080:80"
    echo

    while true; do

        read -r -p "Additional forward (Enter to finish): " forward

        if [[ -z "$forward" ]]; then
            break
        fi

        if ! validate_input forward "$forward"; then
            continue
        fi

        local host_port
        host_port="${forward%%:*}"

        if port_in_use "$host_port"; then
            print_status "ERROR" "Host port $host_port is already in use."
            continue
        fi

        if [[ -n "$PORT_FORWARDS" ]]; then
            PORT_FORWARDS="$PORT_FORWARDS,$forward"
        else
            PORT_FORWARDS="$forward"
        fi
    done

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    PID_FILE="$VM_DIR/$VM_NAME.pid"
    LOG_FILE="$LOG_DIR/$VM_NAME.log"

    CREATED="$(date '+%Y-%m-%d %H:%M:%S')"

    setup_vm_image || return 1

    save_vm_config

    echo
    print_status "SUCCESS" "VM '$VM_NAME' created successfully."
    echo
}

# ------------------------------------------------------------
# PID validation
# ------------------------------------------------------------

pid_is_vm() {
    local pid="$1"
    local image="$2"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    local cmdline
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"

    [[ "$cmdline" == *"$image"* ]]
}

# ------------------------------------------------------------
# VM running check
# ------------------------------------------------------------

is_vm_running() {
    local vm_name="$1"

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"

        if pid_is_vm "$pid" "$IMG_FILE"; then
            return 0
        fi

        rm -f "$PID_FILE"
    fi

    return 1
}

# ------------------------------------------------------------
# Build QEMU command
# ------------------------------------------------------------

build_qemu_command() {

    QEMU_CMD=(
        qemu-system-x86_64

        -name "$VM_NAME"

        -machine type=q35

        -m "$MEMORY"
        -smp "$CPUS"

        -cpu qemu64

        -drive "file=$IMG_FILE,format=qcow2,if=virtio"

        -drive "file=$SEED_FILE,format=raw,if=virtio,readonly=on"

        -boot order=c

        -device virtio-net-pci,netdev=net0

        -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22"

        -device virtio-balloon-pci

        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0
    )

    # Additional port forwards
    if [[ -n "${PORT_FORWARDS:-}" ]]; then

        local forward
        local host_port
        local guest_port

        IFS=',' read -ra forward_list <<< "$PORT_FORWARDS"

        for forward in "${forward_list[@]}"; do
        
