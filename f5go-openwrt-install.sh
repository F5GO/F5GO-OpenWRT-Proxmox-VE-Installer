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

msg_info() { echo -e " ${YELLOW}.. $1...${NC}"; }
msg_ok()   { echo -e " ${GREEN}OK: $1${NC}"; }
msg_error() { echo -e " ${RED}ОШИБКА: $1${NC}"; }
msg_step() { echo -e "${BLUE}${BOLD}--- $1 ---${NC}"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Запустите скрипт от root (через sudo)"
    exit 1
  fi
}

check_proxmox() {
  if ! command -v qm >/dev/null 2>&1; then
    msg_error "Скрипт предназначен только для Proxmox VE"
    exit 1
  fi
}

check_execution_method() {
  if [[ ! -f "$SCRIPT_PATH" || "$SCRIPT_PATH" == *"/bash"* ]]; then
    header
    msg_error "Запуск через 'curl | bash' невозможен."
    echo -e "Используйте:\n${GREEN}wget -qO f5go-openwrt-installer.sh ССЫЛКА && bash f5go-openwrt-installer.sh${NC}"
    exit 1
  fi
}

safe_self_destruct() {
  echo
  msg_info "Очистка временных файлов и автоудаление скрипта"
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
  msg_step "ШАГ 1: НАСТРОЙКА IOMMU"

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
      msg_info "Настройка systemd-boot"
      sed -i "s|$| $IOMMU_SETTING iommu=pt|" /etc/kernel/cmdline
      msg_info "Обновление конфигурации загрузчика (proxmox-boot-tool)"
      proxmox-boot-tool refresh >/dev/null
      NEED_REBOOT=true
      msg_ok "Загрузчик обновлён"
    fi
  else
    # GRUB
    if ! grep -q "$IOMMU_SETTING" /etc/default/grub; then
      msg_info "Настройка GRUB"
      sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$IOMMU_SETTING iommu=pt /" /etc/default/grub
      msg_info "Применение настроек GRUB (update-grub)"
      update-grub >/dev/null
      NEED_REBOOT=true
      msg_ok "GRUB обновлён"
    fi
  fi

  # VFIO modules
  msg_info "Настройка модулей VFIO"
  for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
    if ! grep -q "^$mod" /etc/modules; then
      echo "$mod" >> /etc/modules
      NEED_REBOOT=true
    fi
  done

  if [[ "$NEED_REBOOT" == true ]]; then
    msg_info "Обновление initramfs (это может занять время)"
    update-initramfs -u -k all >/dev/null 2>&1 || true
    msg_ok "Система готова к активации IOMMU"

    echo
    echo -e "${YELLOW}${BOLD}ВНИМАНИЕ: Для активации IOMMU сервер будет перезагружен автоматически.${NC}"
    msg_info "Система уходит в перезагрузку..."
    sleep 3
    reboot
  else
    msg_ok "IOMMU уже настроен корректно"
  fi
}

# =====================================================
# OPENWRT INSTALL
# =====================================================
install_openwrt() {
  header
  msg_step "ШАГ 2: УСТАНОВКА OPENWRT"

  get_latest_openwrt_version() {
    local candidate=""
    local versions_page=""

    # 1) Предпочтительный путь: берем stable-версию с openwrt.org
    if versions_page=$(curl -fsSL https://openwrt.org 2>/dev/null); then
      candidate=$(echo "$versions_page" | sed -n 's/.*Current stable release - OpenWrt \([0-9.]\+\).*/\1/p' | head -n1)
      if [[ -n "$candidate" ]] && curl -fsSLI "https://downloads.openwrt.org/releases/$candidate/targets/x86/64/openwrt-$candidate-x86-64-generic-ext4-combined.img.gz" >/dev/null 2>&1; then
        echo "$candidate"
        return 0
      fi
    fi

    # 2) Резервный путь: парсим каталог releases и сортируем версии
    if versions_page=$(curl -fsSL https://downloads.openwrt.org/releases/ 2>/dev/null); then
      candidate=$(echo "$versions_page" | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/' | tr -d '"' | cut -d/ -f1 | sort -V | tail -n1)
      if [[ -n "$candidate" ]] && curl -fsSLI "https://downloads.openwrt.org/releases/$candidate/targets/x86/64/openwrt-$candidate-x86-64-generic-ext4-combined.img.gz" >/dev/null 2>&1; then
        echo "$candidate"
        return 0
      fi
    fi

    return 1
  }

  msg_info "Определение актуальной версии OpenWrt"
  if ! LATEST_VER=$(get_latest_openwrt_version); then
    msg_error "Не удалось автоматически определить актуальную стабильную версию OpenWrt."
    read -rp " Введите версию вручную (например 24.10.2): " USER_VER
    if [[ -z "${USER_VER:-}" ]]; then
      msg_error "Версия не указана. Установка прервана."
      exit 1
    fi
    LATEST_VER="$USER_VER"
  fi

  echo -e " Найдена актуальная версия: ${GREEN}$LATEST_VER${NC}"
  read -rp " Введите версию (или Enter для $LATEST_VER): " USER_VER
  SELECTED_VER=${USER_VER:-$LATEST_VER}

  BASE_URL="https://downloads.openwrt.org/releases/$SELECTED_VER/targets/x86/64"
  IMG_NAME="openwrt-$SELECTED_VER-x86-64-generic-ext4-combined.img.gz"

  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  msg_info "Загрузка образа и проверка SHA256"
  # Качаем образ
  curl -fL# -o openwrt.img.gz "$BASE_URL/$IMG_NAME"
  # Качаем файл контрольных сумм
  curl -fsSL -o sha256sums "$BASE_URL/sha256sums"

  # ИСПРАВЛЕННАЯ ПРОВЕРКА: Извлекаем хэш для нужного файла и подставляем наше локальное имя
  ACTUAL_HASH=$(grep "$IMG_NAME" sha256sums | awk '{print $1}')
  if [[ -z "$ACTUAL_HASH" ]]; then
      msg_error "Не удалось найти хэш для версии $SELECTED_VER в файле sha256sums!"
      exit 1
  fi

  if ! echo "$ACTUAL_HASH  openwrt.img.gz" | sha256sum -c - >/dev/null 2>&1; then
    msg_error "Ошибка проверки контрольной суммы (SHA256 mismatch)!"
    exit 1
  fi
  msg_ok "Образ загружен и успешно проверен"

  msg_info "Распаковка образа"
  zcat openwrt.img.gz > openwrt.img

  # === Создание VM ===
  NEXTID=$(pvesh get /cluster/nextid)
  read -rp " Введите VM ID [$NEXTID]: " VMID
  VMID=${VMID:-$NEXTID}

  STORAGE=$(pvesm status -content images | awk 'NR>1 && $1 !~ /^local$/ {print $1}' | head -n1)
  read -rp " Выберите Storage [$STORAGE]: " USER_STORAGE
  STORAGE=${USER_STORAGE:-$STORAGE}

  read -rp " Объем RAM (МБ) [512]: " VM_RAM
  VM_RAM=${VM_RAM:-512}
  read -rp " Объем диска (МБ) [512]: " VM_ROM
  VM_ROM=${VM_ROM:-512}

  msg_info "Создание VM $VMID"
  qm create "$VMID" \
    -name "OpenWRT" \
    -cores 1 \
    -memory "$VM_RAM" \
    -description "OpenWrt $SELECTED_VER. F5GO.ONE." \
    -ostype l26 \
    -cpu host \
    -scsihw virtio-scsi-pci \
    -onboot 1 \
    -tablet 0

  msg_info "Настройка EFI-диска"
  pvesm alloc "$STORAGE" "$VMID" "vm-$VMID-disk-0" 4M >/dev/null 2>&1 || true
  qm set "$VMID" -efidisk0 "${STORAGE}:vm-$VMID-disk-0,efitype=4m,size=4M" >/dev/null 2>&1 || \
  qm set "$VMID" -efidisk0 "${STORAGE}:0,efitype=4m,size=4M" >/dev/null

  msg_info "Импорт диска в хранилище $STORAGE"
  qm importdisk "$VMID" openwrt.img "$STORAGE" --format raw >/dev/null
  sleep 2

  DISK_REF="$(pvesm list "$STORAGE" | grep "vm-$VMID-disk" | grep -v "disk-0" | awk '{print $1}' | tail -n1)"
  if [[ -z "$DISK_REF" ]]; then
    msg_error "Не удалось определить ссылку на импортированный диск!"
    exit 1
  fi

  qm set "$VMID" \
    -scsi0 "$DISK_REF" \
    -boot order=scsi0 \
    -bootdisk scsi0 >/dev/null

  msg_info "Изменение размера диска до ${VM_ROM}MB"
  qm disk resize "$VMID" scsi0 "${VM_ROM}M" >/dev/null

  header
  msg_ok "OpenWrt VM $VMID успешно создана!"
  echo -e "${YELLOW}ДАЛЕЕ:${NC} Не забудьте пробросить PCI Device (сетевые карты) в Hardware VM."
  echo -e "Рекомендуется включить 'All Functions' и 'ROM-Bar'."
  echo -e "После этого запустите ВМ вручную командой: ${GREEN}qm start $VMID${NC}"

  safe_self_destruct
}

# =====================================================
# MAIN
# =====================================================
check_root
check_proxmox

check_execution_method

while true; do
  header
  echo " 1) Настроить IOMMU"
  echo " 2) Установить OpenWrt VM"
  echo " 0) Выход"
  echo
  read -rp " Выберите действие: " OPT

  case "$OPT" in
    1) setup_iommu ;;
    2) install_openwrt ;;
    0) exit 0 ;;
    *) echo " Неверный выбор." ;;
  esac
done
