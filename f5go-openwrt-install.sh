#!/usr/bin/env bash
# =====================================================
# НАЗВАНИЕ: F5GO OpenWRT Proxmox VE Installer
# ОПИСАНИЕ: Настройка IOMMU + Установка OpenWrt VM 
# =====================================================
set -Eeuo pipefail

# =====================================================
# COLORS & TRAP
# =====================================================
GREEN='\033[1;92m'
YELLOW='\033[33m'
RED='\033[01;31m'
BLUE='\033[36m'
NC='\033[m'
BOLD='\033[1m'

TEMP_DIR=""
SCRIPT_PATH="$(realpath "$0")"
STATE_FILE="/root/.f5go-installer-stage"
SERVICE_NAME="f5go-installer.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

cleanup_temp() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup_temp EXIT INT TERM

# =====================================================
# FUNCTIONS
# =====================================================
header() {
  clear
  cat <<"EOF"
   ____                 _       __     __
  / __ \____  ___  ____| |     / /____/ /_
 / / / / __ \/ _ \/ __ \ | /| / / ___/ __/
/ /_/ / /_/ /  __/ / / / |/ |/ / /  / /_
\____/ .___/\___/_/ /_/|__/|__/_/   \__/
    /_/ W I R E L E S S   F R E E D O M
      F5GO OpenWRT Proxmox VE Installer
EOF
  echo
}

msg_info() { echo -ne " ${YELLOW}$1...${NC}"; }
msg_ok()  { echo -e " ${GREEN}$1${NC}"; }
msg_error() { echo -e " ${RED}$1${NC}"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Запустите скрипт от root (через sudo)"
    exit 1
  fi
}

check_proxmox() {
  if ! command -v qm >/dev/null 2>&1; then
    msg_error "Ошибка: Скрипт предназначен только для Proxmox VE"
    exit 1
  fi
}

check_execution_method() {
  if [[ ! -f "$SCRIPT_PATH" || "$SCRIPT_PATH" == *"/bash"* ]]; then
    header
    msg_error "Ошибка: Запуск через 'curl | bash' невозможен."
    echo -e "Используйте:\n${GREEN}wget -qO f5go-openwrt-installer.sh ССЫЛКА && bash f5go-openwrt-installer.sh${NC}"
    exit 1
  fi
}

cleanup_resume_service() {
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_PATH" "$STATE_FILE"
}

safe_self_destruct() {
  echo
  msg_info "Очистка временных файлов и автоудаление скрипта"
  cleanup_resume_service
  if [[ -f "$SCRIPT_PATH" ]]; then
    (sleep 3 && rm -f "$SCRIPT_PATH") &
  fi
  msg_ok "Скрипт успешно завершен и удален."
  exit 0
}

# =====================================================
# IOMMU SETUP
# =====================================================
setup_iommu() {
  header
  echo -e "${BLUE}${BOLD}--- ШАГ 1: НАСТРОЙКА IOMMU ---${NC}\n"

  CPU_VENDOR=$(grep -m 1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
  if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    IOMMU_SETTING="intel_iommu=on"
    msg_ok "Обнаружен Intel CPU"
  elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    IOMMU_SETTING="amd_iommu=on"
    msg_ok "Обнаружен AMD CPU"
  else
    msg_error "Неизвестный CPU. Пропускаем IOMMU."
    return
  fi

  NEED_REBOOT=false

  if [[ -f /etc/kernel/cmdline ]] && command -v proxmox-boot-tool >/dev/null 2>&1; then
    # systemd-boot
    if ! grep -q "$IOMMU_SETTING" /etc/kernel/cmdline; then
      sed -i "s|$| $IOMMU_SETTING iommu=pt|" /etc/kernel/cmdline
      proxmox-boot-tool refresh >/dev/null
      NEED_REBOOT=true
      msg_ok "systemd-boot обновлён"
    fi
  else
    # GRUB
    if ! grep -q "$IOMMU_SETTING" /etc/default/grub; then
      sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$IOMMU_SETTING iommu=pt /" /etc/default/grub
      update-grub >/dev/null
      NEED_REBOOT=true
      msg_ok "GRUB обновлён"
    fi
  fi

  # VFIO modules
  for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
    if ! grep -q "^$mod" /etc/modules; then
      echo "$mod" >> /etc/modules
      NEED_REBOOT=true
    fi
  done

  if [[ "$NEED_REBOOT" == true ]]; then
    update-initramfs -u -k all >/dev/null 2>&1 || true
    echo
    read -rp "Требуется перезагрузка. Перезагрузить сейчас? (y/n): " REB
    if [[ "$REB" =~ ^[Yy]$ ]]; then
      echo "openwrt_install" > "$STATE_FILE"
      create_resume_service
      reboot
    fi
    exit 0
  else
    msg_ok "IOMMU уже настроен корректно"
  fi
}

create_resume_service() {
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=F5GO Installer Auto Resume
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --continue
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

# =====================================================
# OPENWRT INSTALL
# =====================================================
install_openwrt() {
  # Защита от зацикливания
  cleanup_resume_service

  header
  echo -e "${BLUE}${BOLD}--- ШАГ 2: УСТАНОВКА OPENWRT ---${NC}\n"

  # === Определение последней версии ===
  msg_info "Определение актуальной версии OpenWrt"
  LATEST_VER=$(curl -fsSL https://downloads.openwrt.org/releases/ | \
               grep -oP 'href="\K[0-9]+\.[0-9]+\.[0-9]+(?=/)"' | sort -V | tail -n1 || echo "25.12.2")

  echo -e "Найдена актуальная версия: ${GREEN}$LATEST_VER${NC}"
  read -rp "Введите версию (или Enter для $LATEST_VER): " USER_VER
  SELECTED_VER=${USER_VER:-$LATEST_VER}

  BASE_URL="https://downloads.openwrt.org/releases/$SELECTED_VER/targets/x86/64"
  IMG_NAME="openwrt-$SELECTED_VER-x86-64-generic-ext4-combined.img.gz"

  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  msg_info "Загрузка образа и проверка SHA256"
  curl -fL# -o openwrt.img.gz "$BASE_URL/$IMG_NAME"
  curl -fsSL -o sha256sums "$BASE_URL/sha256sums"

  if ! grep "$IMG_NAME" sha256sums | sha256sum -c - >/dev/null 2>&1; then
    msg_error "Ошибка проверки контрольной суммы!"
    exit 1
  fi
  msg_ok "Образ загружен и проверен"

  zcat openwrt.img.gz > openwrt.img

  # === Создание VM ===
  NEXTID=$(pvesh get /cluster/nextid)
  read -rp "Введите VM ID [$NEXTID]: " VMID
  VMID=${VMID:-$NEXTID}

  STORAGE=$(pvesm status -content images | awk 'NR>1 && $1 !~ /^local$/ {print $1}' | head -n1)
  read -rp "Выберите Storage [$STORAGE]: " USER_STORAGE
  STORAGE=${USER_STORAGE:-$STORAGE}

  read -rp "Объем RAM (МБ) [512]: " VM_RAM
  VM_RAM=${VM_RAM:-512}
  read -rp "Объем диска (МБ) [512]: " VM_ROM
  VM_ROM=${VM_ROM:-512}

  msg_info "Создание VM $VMID"
  qm create "$VMID" \
    -name "OpenWrt-F5GO.ONE" \
    -cores 1 \
    -memory "$VM_RAM" \
    -machine q35 \
    -bios ovmf \
    -efidisk0 "$STORAGE:0,efitype=4m,size=4M" \
    -ostype l26 \
    -cpu host \
    -scsihw virtio-scsi-single \
    -onboot 1 \
    -tablet 0

  # Импорт диска
  qm importdisk "$VMID" openwrt.img "$STORAGE" --format raw
  sleep 2

  # Находим импортированный диск
  DISK_ID=$(qm config "$VMID" | grep -o '^unused[0-9]*:' | head -n1 | cut -d: -f1)
  if [[ -n "$DISK_ID" ]]; then
    qm set "$VMID" -scsi0 "${DISK_ID/unused/scsi}" -boot order=scsi0
  else
    msg_error "Не удалось найти импортированный диск!"
    exit 1
  fi

  qm disk resize "$VMID" scsi0 "${VM_ROM}M"

  qm set "$VMID" -net0 virtio,bridge=vmbr0,firewall=0

  header
  msg_ok "OpenWrt VM $VMID успешно создана!"
  echo -e "${YELLOW}ВНИМАНИЕ:${NC} Не забудьте пробросить PCI Device (сетевую карту) в Hardware VM."
  echo -e "Рекомендуется включить 'All Functions' и 'ROM-Bar'."

  read -rp "Запустить VM сейчас? (y/n): " START_VM
  if [[ "$START_VM" =~ ^[Yy]$ ]]; then
    qm start "$VMID"
    msg_ok "VM запущена"
  fi

  safe_self_destruct
}

# =====================================================
# MAIN
# =====================================================
check_root
check_proxmox

if [[ "${1:-}" == "--continue" ]]; then
  if [[ -f "$STATE_FILE" && "$(cat "$STATE_FILE")" == "openwrt_install" ]]; then
    install_openwrt
  else
    msg_error "Некорректное состояние продолжения."
    exit 1
  fi
fi

check_execution_method

while true; do
  header
  echo "1) Настроить IOMMU"
  echo "2) Установить OpenWrt"
  echo "3) Настроить IOMMU + Установить OpenWrt"
  echo "0) Выход"
  echo
  read -rp "Выберите действие: " OPT

  case "$OPT" in
    1) setup_iommu ;;
    2) install_openwrt ;;
    3) setup_iommu; install_openwrt ;;
    0) exit 0 ;;
    *) echo "Неверный выбор." ;;
  esac
done