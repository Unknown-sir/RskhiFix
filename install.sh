#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"

BANNER() {
  cat <<'EOF'
 ____       _    _     _ _____ _
|  _ \ ___ | | _| |__ (_)  ___(_)_  __
| |_) / _ \| |/ / '_ \| | |_  | \ \/ /
|  _ < (_) |   <| | | | |  _| | |>  <
|_| \_\___/|_|\_\_| |_|_|_|   |_/_/\_\
                RskhiFix
EOF
}

need_root_or_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO=""
  else
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      echo "❌ Root privileges are required. Please run as root (or install sudo)."
      exit 1
    fi
  fi
}

have_systemd() {
  command -v systemctl >/dev/null 2>&1
}

ping_path() {
  if [[ -x /usr/bin/ping ]]; then
    echo "/usr/bin/ping"
  elif [[ -x /bin/ping ]]; then
    echo "/bin/ping"
  else
    echo ""
  fi
}

is_valid_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

self_install() {
  need_root_or_sudo
  $SUDO mkdir -p /usr/local/bin

  # Copy this script into /usr/local/bin/Rskhi
  # Works even when executed via: bash <(curl ...)
  if ! cat "$0" | $SUDO tee /usr/local/bin/Rskhi >/dev/null; then
    echo "❌ Installation failed (unable to copy script)."
    exit 1
  fi
  $SUDO chmod +x /usr/local/bin/Rskhi
  $SUDO ln -sf /usr/local/bin/Rskhi /usr/local/bin/rskhi >/dev/null 2>&1 || true
}

services_list() {
  # Output service base names (without .service)
  ls /etc/systemd/system/RskhiFix-*.service 2>/dev/null \
    | xargs -n1 basename 2>/dev/null \
    | sed 's/\.service$//' || true
}

next_service_name() {
  local n=1
  while [[ -f "/etc/systemd/system/RskhiFix-${n}.service" ]]; do
    n=$((n+1))
  done
  echo "RskhiFix-${n}"
}

write_unit_file() {
  local name="$1" side="$2" target_ip="$3" interval="$4"
  local p; p="$(ping_path)"
  if [[ -z "$p" ]]; then
    echo "❌ 'ping' command not found. Please install iputils-ping."
    exit 1
  fi

  local unit="/etc/systemd/system/${name}.service"
  $SUDO tee "$unit" >/dev/null <<EOF
# CreatedBy=RskhiFix
# Side=${side}
# TargetIP=${target_ip}
# CreatedAt=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
[Unit]
Description=RskhiFix KeepAlive (${side}) -> ${target_ip}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${p} -n -i ${interval} ${target_ip}
Restart=always
RestartSec=1
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
}

reload_and_start() {
  local name="$1"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "${name}.service"
}

create_service_wizard() {
  need_root_or_sudo

  if ! have_systemd; then
    echo "❌ systemd is not available on this system. RskhiFix requires systemd."
    exit 1
  fi

  echo
  echo "Select where you are installing:"
  echo "  1) Iran server (you must enter the OUTSIDE local IP)"
  echo "  2) Outside server (you must enter the IRAN local IP)"

  local choice=""
  while true; do
    read -r -p "Choose (1/2): " choice
    [[ "$choice" == "1" || "$choice" == "2" ]] && break
    echo "Please enter only 1 or 2."
  done

  local side=""
  local prompt=""
  if [[ "$choice" == "1" ]]; then
    side="IRAN"
    prompt="Enter OUTSIDE local IP (e.g., 10.100.100.2): "
  else
    side="OUTSIDE"
    prompt="Enter IRAN local IP (e.g., 10.100.100.1): "
  fi

  local ip=""
  while true; do
    read -r -p "$prompt" ip
    if is_valid_ip "$ip"; then break; fi
    echo "Invalid IP address. Please try again."
  done

  local interval="1"
  local tmp=""
  read -r -p "Ping interval in seconds (default: 1): " tmp || true
  if [[ -n "${tmp:-}" ]]; then
    if [[ "$tmp" =~ ^[0-9]+$ ]] && [[ "$tmp" -ge 1 && "$tmp" -le 60 ]]; then
      interval="$tmp"
    else
      echo "Invalid interval. Using default: 1"
    fi
  fi

  local name; name="$(next_service_name)"
  echo
  echo "✅ Creating service: ${name}"
  write_unit_file "$name" "$side" "$ip" "$interval"
  reload_and_start "$name"

  echo
  echo "Service status:"
  $SUDO systemctl --no-pager status "${name}.service" || true
  echo
  echo "✅ Done. Open the panel anytime with: Rskhi"
}

choose_service() {
  local -a arr=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && arr+=("$line")
  done < <(services_list)

  if [[ "${#arr[@]}" -eq 0 ]]; then
    echo ""
    return 1
  fi

  echo
  echo "Created services:"
  local i=1
  for s in "${arr[@]}"; do
    echo "  $i) $s"
    i=$((i+1))
  done

  local sel=""
  while true; do
    read -r -p "Which service? (number): " sel
    [[ "$sel" =~ ^[0-9]+$ ]] || { echo "Please enter a number."; continue; }
    if [[ "$sel" -ge 1 && "$sel" -le "${#arr[@]}" ]]; then
      echo "${arr[$((sel-1))]}"
      return 0
    fi
    echo "Out of range."
  done
}

service_get_exec() {
  local name="$1"
  grep -E '^ExecStart=' "/etc/systemd/system/${name}.service" | head -n1 | cut -d= -f2- || true
}

service_get_target_ip() {
  local exec; exec="$(service_get_exec "$1")"
  [[ -n "$exec" ]] || { echo ""; return; }
  echo "${exec##* }"
}

service_get_interval() {
  local exec; exec="$(service_get_exec "$1")"
  [[ -n "$exec" ]] || { echo ""; return; }
  local -a parts=()
  read -r -a parts <<<"$exec"
  local idx=0
  for ((idx=0; idx<${#parts[@]}; idx++)); do
    if [[ "${parts[$idx]}" == "-i" && $((idx+1)) -lt ${#parts[@]} ]]; then
      echo "${parts[$((idx+1))]}"
      return
    fi
  done
  echo ""
}

list_services_panel() {
  need_root_or_sudo
  local list; list="$(services_list || true)"
  if [[ -z "${list:-}" ]]; then
    echo
    echo "No RskhiFix services found."
    return
  fi

  echo
  echo "Services list:"
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    local enabled active ip interval
    enabled="$($SUDO systemctl is-enabled "${s}.service" 2>/dev/null || echo "unknown")"
    active="$($SUDO systemctl is-active "${s}.service" 2>/dev/null || echo "unknown")"
    ip="$(service_get_target_ip "$s")"
    interval="$(service_get_interval "$s")"
    echo "----------------------------------------"
    echo "Name    : $s"
    echo "Target  : ${ip:-?}"
    echo "Interval: ${interval:-?}s"
    echo "Enabled : $enabled"
    echo "Active  : $active"
  done <<<"$list"
  echo "----------------------------------------"
}

edit_service_panel() {
  need_root_or_sudo
  local svc
  svc="$(choose_service)" || { echo; echo "No services available to edit."; return; }

  local unit="/etc/systemd/system/${svc}.service"
  echo
  echo "Editing service: $svc"
  echo "  1) Change Target IP / Interval (recommended)"
  echo "  2) Open unit file in an editor"

  local op=""
  while true; do
    read -r -p "Choose (1/2): " op
    [[ "$op" == "1" || "$op" == "2" ]] && break
    echo "Please enter only 1 or 2."
  done

  if [[ "$op" == "2" ]]; then
    local editor="${EDITOR:-}"
    if [[ -z "$editor" ]]; then
      if command -v nano >/dev/null 2>&1; then editor="nano"
      elif command -v vi >/dev/null 2>&1; then editor="vi"
      else editor=""; fi
    fi

    if [[ -z "$editor" ]]; then
      echo "❌ No editor found (nano/vi). Set \$EDITOR or install nano/vi."
      return
    fi

    $SUDO "$editor" "$unit"
  else
    local cur_ip cur_int
    cur_ip="$(service_get_target_ip "$svc")"
    cur_int="$(service_get_interval "$svc")"
    echo
    echo "Current values:"
    echo "  Target IP : ${cur_ip:-?}"
    echo "  Interval  : ${cur_int:-?}"

    local new_ip new_int
    read -r -p "New Target IP (leave empty to keep): " new_ip || true
    if [[ -n "${new_ip:-}" ]]; then
      is_valid_ip "$new_ip" || { echo "Invalid IP. Aborted."; return; }
    else
      new_ip="$cur_ip"
    fi

    read -r -p "New Interval seconds (leave empty to keep): " new_int || true
    if [[ -n "${new_int:-}" ]]; then
      [[ "$new_int" =~ ^[0-9]+$ ]] && [[ "$new_int" -ge 1 && "$new_int" -le 60 ]] || { echo "Invalid interval. Aborted."; return; }
    else
      new_int="$cur_int"
    fi

    local p; p="$(ping_path)"
    [[ -n "$p" ]] || { echo "❌ 'ping' not found."; return; }

    $SUDO sed -i -E "s|^ExecStart=.*$|ExecStart=${p} -n -i ${new_int} ${new_ip}|" "$unit"
    $SUDO sed -i -E "s|^Description=RskhiFix KeepAlive.*$|Description=RskhiFix KeepAlive (EDIT) -> ${new_ip}|" "$unit" || true
  fi

  $SUDO systemctl daemon-reload
  $SUDO systemctl restart "${svc}.service" || true

  echo
  echo "✅ Updated. Current status:"
  $SUDO systemctl --no-pager status "${svc}.service" || true
}

delete_service_panel() {
  need_root_or_sudo
  local svc
  svc="$(choose_service)" || { echo; echo "No services available to delete."; return; }

  echo
  read -r -p "Delete service '${svc}'? (y/N): " ans || true
  ans="${ans:-N}"
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    echo "Cancelled."
    return
  fi

  local unit="/etc/systemd/system/${svc}.service"
  $SUDO systemctl stop "${svc}.service" 2>/dev/null || true
  $SUDO systemctl disable "${svc}.service" 2>/dev/null || true
  $SUDO rm -f "$unit"
  $SUDO systemctl daemon-reload

  echo "✅ Deleted: $svc"
}

menu() {
  while true; do
    echo
    echo "RskhiFix Panel (v${VERSION})"
    echo "  1) Create new service"
    echo "  2) List created services"
    echo "  3) Edit created services"
    echo "  4) Delete created services"
    echo "  0) Exit"
    echo

    local opt=""
    read -r -p "Select: " opt

    case "${opt:-}" in
      1) create_service_wizard ;;
      2) list_services_panel ;;
      3) edit_service_panel ;;
      4) delete_service_panel ;;
      0) exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

main() {
  BANNER

  # If executed with --create, directly create a service
  if [[ "${1:-}" == "--create" ]]; then
    create_service_wizard
    exit 0
  fi

  # If not running from /usr/local/bin/Rskhi, treat as first install/update
  local real0
  real0="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  if [[ "$real0" != "/usr/local/bin/Rskhi" ]]; then
    echo
    echo "Installing/Updating RskhiFix ..."
    self_install
    echo "✅ Installed: /usr/local/bin/Rskhi"
    echo
    create_service_wizard
    exit 0
  fi

  # Panel mode
  menu
}

main "$@"
