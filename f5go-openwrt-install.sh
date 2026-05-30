#!/usr/bin/env bash
# =====================================================
# НАЗВАНИЕ: F5GO OpenWRT Proxmox VE Installer
# ОПИСАНИЕ: Настройка IOMMU + Установка OpenWrt VM 
# Разработано для сообщества F5GO.ONE
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

get_next_vmbr_name() {
  local max=-1
  local name=""
  while read -r name; do
    [[ -z "$name" ]] && continue
    local n="${name#vmbr}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if (( n > max )); then
      max="$n"
    fi
  done < <(
    {
      ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr[0-9]+$' || true
      if [[ -f /etc/network/interfaces ]]; then
        awk '
          /^[[:space:]]*(auto|allow-hotplug)[[:space:]]+/ {
            for (i=2; i<=NF; i++) if ($i ~ /^vmbr[0-9]+$/) print $i
          }
          /^[[:space:]]*iface[[:space:]]+/ {
            if ($2 ~ /^vmbr[0-9]+$/) print $2
          }
        ' /etc/network/interfaces || true
      fi
    } | sort -u
  )

  if (( max < 0 )); then
    echo "vmbr0"
  else
    echo "vmbr$((max + 1))"
  fi
}

ensure_linux_bridge_in_interfaces() {
  local bridge_name="$1"
  local cidr_addr="$2"
  local iface_file="/etc/network/interfaces"

  if [[ ! -f "$iface_file" ]]; then
    msg_error "Не найден $iface_file. Невозможно добавить мост."
    return 1
  fi

  if grep -Eq "^[[:space:]]*iface[[:space:]]+$bridge_name[[:space:]]+inet[[:space:]]+" "$iface_file" || \
     grep -Eq "^[[:space:]]*auto[[:space:]]+$bridge_name([[:space:]]|$)" "$iface_file"; then
    msg_info "Мост $bridge_name уже присутствует в конфигурации сети"
    return 0
  fi

  {
    echo
    echo "auto $bridge_name"
    echo "iface $bridge_name inet static"
    echo "  address $cidr_addr"
    echo "  bridge-ports none"
    echo "  bridge-stp off"
    echo "  bridge-fd 0"
  } >> "$iface_file"

  return 0
}

reload_network_config() {
  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a >/dev/null 2>&1 || return 1
    return 0
  fi
  if systemctl list-unit-files >/dev/null 2>&1; then
    systemctl restart networking >/dev/null 2>&1 || return 1
    return 0
  fi
  return 1
}

get_next_vm_net_key() {
  local vmid="$1"
  local idx=0
  while (( idx < 32 )); do
    if ! qm config "$vmid" 2>/dev/null | grep -Eq "^net$idx:"; then
      echo "net$idx"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

setup_bridge_and_attach_nic() {
  local vmid="$1"
  local default_bridge=""
  local default_ip="192.168.1.5/24"

  header
  msg_step "ШАГ 3: ДОПОЛНИТЕЛЬНЫЙ МОСТ + NIC (ОПЦИОНАЛЬНО)"
  echo
  read -rp " Создать Linux Bridge и подключить VirtIO NIC к VM? [Y/n]: " CONFIRM_BRIDGE
  CONFIRM_BRIDGE=${CONFIRM_BRIDGE:-Y}
  if [[ ! "$CONFIRM_BRIDGE" =~ ^[Yy]$ ]]; then
    msg_info "Пропускаем создание моста и добавление NIC"
    return 0
  fi

  default_bridge="$(get_next_vmbr_name)"
  echo -e " Имя моста по умолчанию: ${GREEN}${default_bridge}${NC}"
  read -rp " Введите имя моста (или Enter для $default_bridge): " BRIDGE_NAME
  BRIDGE_NAME=${BRIDGE_NAME:-$default_bridge}

  if [[ ! "$BRIDGE_NAME" =~ ^vmbr[0-9]+$ ]]; then
    msg_error "Некорректное имя моста: $BRIDGE_NAME (ожидается vmbrN)"
    exit 1
  fi

  echo -e " IP/CIDR по умолчанию: ${GREEN}${default_ip}${NC}"
  read -rp " Введите IP/CIDR (или Enter для $default_ip): " BRIDGE_IP
  BRIDGE_IP=${BRIDGE_IP:-$default_ip}

  if ! echo "$BRIDGE_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
    msg_error "Некорректный формат IP/CIDR: $BRIDGE_IP"
    exit 1
  fi

  if ip -o -4 addr show | awk '{print $4}' | grep -qx "$BRIDGE_IP"; then
    msg_error "IP $BRIDGE_IP уже используется в системе. Продолжаем на ваш риск."
    read -rp " Продолжить несмотря на конфликт? [y/N]: " CONFIRM_CONFLICT
    CONFIRM_CONFLICT=${CONFIRM_CONFLICT:-N}
    if [[ ! "$CONFIRM_CONFLICT" =~ ^[Yy]$ ]]; then
      msg_info "Операция отменена пользователем"
      return 0
    fi
  fi

  echo
  msg_info "Будет создан мост: ${BRIDGE_NAME} с адресом ${BRIDGE_IP}"
  read -rp " Подтвердите (Y/n): " CONFIRM_APPLY
  CONFIRM_APPLY=${CONFIRM_APPLY:-Y}
  if [[ ! "$CONFIRM_APPLY" =~ ^[Yy]$ ]]; then
    msg_info "Пропускаем создание моста и добавление NIC"
    return 0
  fi

  msg_info "Добавление моста в /etc/network/interfaces"
  ensure_linux_bridge_in_interfaces "$BRIDGE_NAME" "$BRIDGE_IP"
  msg_ok "Конфигурация моста добавлена"

  msg_info "Применение сетевой конфигурации"
  if reload_network_config; then
    msg_ok "Сетевая конфигурация применена"
  else
    msg_error "Не удалось автоматически применить конфигурацию сети. Проверьте сеть и примените изменения вручную."
  fi

  local net_key=""
  if ! net_key="$(get_next_vm_net_key "$vmid")"; then
    msg_error "Не удалось подобрать свободный слот NIC для VM $vmid"
    return 1
  fi

  msg_info "Добавление VirtIO NIC ($net_key) в VM $vmid на мост $BRIDGE_NAME"
  qm set "$vmid" -"$net_key" "virtio,bridge=$BRIDGE_NAME" >/dev/null
  msg_ok "NIC добавлен в VM ($net_key -> $BRIDGE_NAME)"

  return 0
}

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

  DESCRIPTION=$(cat <<EOF
<div align="center">
  <a href="https://f5go.one" target="_blank" rel="noopener noreferrer">
    <img src="https://f5go.ru/content/images/2026/05/f5go.one_400px.png" alt="F5GO.ONE" width="72" style="max-width:72px;height:auto;" />
  </a>

  <h2 style="font-size:24px; margin:16px 0 10px;">F5GO OpenWrt VM</h2>

  <p style="margin:8px 0;">
    Разработано для сообщества <b>F5GO.ONE</b>
  </p>

  <p style="margin:10px 0;">
    OpenWrt x86_64 • Proxmox VE • Version: <b>${SELECTED_VER}</b>
  </p>

  <p style="margin:14px 0;">
    <a href="https://youtube.com/@f5go" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/YouTube-@f5go-FF0000?logo=youtube&logoColor=white" alt="YouTube" />
    </a>
    <a href="https://vk.ru/f5gou" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/VK-f5gou-0077FF?logo=vk&logoColor=white" alt="VK" />
    </a>
    <a href="https://t.me/f5gou" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/Telegram-@f5gou-26A5E4?logo=telegram&logoColor=white" alt="Telegram" />
    </a>
  </p>

  <p style="margin:12px 0;">
    <a href="https://github.com/F5GO/F5GO-OpenWRT-Proxmox-VE-Installer" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/Repo-F5GO--OpenWRT--Proxmox--VE--Installer-00617f?logo=github&logoColor=white" alt="Repository" />
    </a>
    <a href="https://github.com/F5GO" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/GitHub-F5GO-181717?logo=github&logoColor=white" alt="GitHub" />
    </a>
  </p>
</div>
EOF
)

  msg_info "Создание VM $VMID"
  qm create "$VMID" \
    -name "OpenWRT" \
    -cores 1 \
    -memory "$VM_RAM" \
    -description "$DESCRIPTION" \
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

  setup_bridge_and_attach_nic "$VMID"

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
