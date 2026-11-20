# Funciones compartidas por start.sh y cgi-bin/action.
# "host" ejecuta un comando en los montajes del servidor (requiere privileged + pid: host).
UUID=2c939876-220a-42f8-bb43-14e79be7d9ad
MNT=/home/umbrel/umbrel/external/SSD
HOME_LINK=/home/umbrel/umbrel/home/SSD
TRASH=/home/umbrel/umbrel/trash
TRASH_META=/home/umbrel/umbrel/trash-meta
LOG=/data/earlyoom.log

host() { nsenter -t 1 -m -- "$@"; }

# Monta el SSD en External/SSD y lo enlaza en Home/SSD para que salga en Files.
mount_ssd() {
  if host mountpoint -q "$MNT"; then
    echo "SSD ya estaba montado."
  elif host test -e "/dev/disk/by-uuid/$UUID"; then
    host mkdir -p "$MNT" && host mount -o noatime "UUID=$UUID" "$MNT" || { echo "ERROR al montar el SSD."; return 1; }
    echo "SSD montado."
  else
    echo "ERROR: no se encuentra el SSD ($UUID)."; return 1
  fi
  # Primera vez: dar el disco al usuario umbrel (uid 1000)
  if [ "$(host stat -c %u "$MNT")" = 0 ]; then
    host chown 1000:1000 "$MNT"
    host install -d -o 1000 -g 1000 "$MNT/datos"
  fi
  if ! host mountpoint -q "$HOME_LINK"; then
    host test -d "$HOME_LINK" || host install -d -o 1000 -g 1000 "$HOME_LINK"
    # Inmutable mientras no este montado: si el SSD falta, nadie escribe ahi (iria al NVMe)
    host chattr +i "$HOME_LINK"
    host mount --bind "$MNT/datos" "$HOME_LINK" || { echo "ERROR al enlazar Home/SSD."; return 1; }
    echo "Enlazado en Files como Home/SSD."
  fi
}

# Swap en archivo dentro del SSD (fuera de datos/, no se ve en Files).
# Tamano deseado en GB guardado en /data/swap-size (0 = apagado). Prioridad 10: detras del zram (100).
SWAPFILE=$MNT/swapfile
SWAPCONF=/data/swap-size
GB=1073741824

apply_swap() {
  size=$(cat "$SWAPCONF" 2>/dev/null || echo 0)
  if grep -q "^$SWAPFILE " /proc/swaps; then
    [ "$(host stat -c %s "$SWAPFILE")" = "$((size * GB))" ] && { echo "Swap del SSD ya activo ($size GB)."; return 0; }
    # Antes de apagarlo: lo que tenga dentro tiene que caber en la RAM libre
    used_kb=$(awk -v f="$SWAPFILE" '$1 == f {print $4}' /proc/swaps)
    avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    [ "$used_kb" -lt $((avail_kb * 8 / 10)) ] ||
      { echo "No se apaga: el swap del SSD tiene $((used_kb / 1024)) MB y solo hay $((avail_kb / 1024)) MB de RAM libre."; return 1; }
    host swapoff "$SWAPFILE" || { echo "ERROR: no se pudo desactivar el swap del SSD."; return 1; }
  fi
  if [ "$size" = 0 ]; then
    host rm -f "$SWAPFILE"
    echo "Swap del SSD apagado."; return 0
  fi
  host mountpoint -q "$MNT" || { echo "ERROR: el SSD no esta montado; swap no activado."; return 1; }
  if [ "$(host stat -c %s "$SWAPFILE" 2>/dev/null)" != "$((size * GB))" ]; then
    host rm -f "$SWAPFILE"
    host fallocate -l "${size}G" "$SWAPFILE" && host chmod 600 "$SWAPFILE" && host mkswap -q "$SWAPFILE" >/dev/null ||
      { echo "ERROR creando el archivo de swap."; return 1; }
  fi
  host swapon -p 10 "$SWAPFILE" && echo "Swap del SSD activo: $size GB (detras del zram)."
}

# Discos fisicos: "nombre transporte" (sata, nvme, usb)
list_disks() { host lsblk -dno NAME,TRAN | awk '$2 != "" {print $1, $2}'; }

# SMART de todos los discos -> /www/smart.json
smart_scan() {
  list_disks | while read -r name tran; do
    opt=""; [ "$tran" = usb ] && opt="-d scsi"   # el puente USB del Seagate solo acepta scsi
    smartctl -j -a $opt "/dev/$name" | jq -c --arg n "$name" --arg t "$tran" '{name: $n, tran: $t, data: .}'
  done | jq -s . > /www/smart.json.tmp && mv /www/smart.json.tmp /www/smart.json
}

# Estado general -> /www/status.json
collect() {
  mounts=$( (echo /data; host findmnt -rno TARGET | grep '^/home/umbrel/umbrel/external/[^/]*$') | sort -u)
  disks=$(host df -B1 --output=source,size,used,target $mounts 2>/dev/null | tail -n +2 |
    jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ") | map(select(length > 0))
      | {source: .[0], size: (.[1] | tonumber), used: (.[2] | tonumber), target: .[3]})')
  mem=$(awk '{v[$1] = $2 * 1024} END {printf "{\"total\":%d,\"avail\":%d,\"swap_total\":%d,\"swap_free\":%d}",
    v["MemTotal:"], v["MemAvailable:"], v["SwapTotal:"], v["SwapFree:"]}' /proc/meminfo)
  top=$(ps -eo rss=,comm= --sort=-rss | head -8 |
    jq -R -s -c 'split("\n") | map(select(length > 0) | capture("^ *(?<rss>[0-9]+) +(?<name>.+)$") | {name, bytes: ((.rss | tonumber) * 1024)})')
  oom=$(grep -h "sending SIG[A-Z]* to process" "$LOG" 2>/dev/null | tail -15 | jq -R -s -c 'split("\n") | map(select(length > 0)) | reverse')
  swaps=$(tail -n +2 /proc/swaps | jq -R -s -c 'split("\n") | map(select(length > 0) | [splits("\\s+")]
    | {name: .[0], size: ((.[2] | tonumber) * 1024), used: ((.[3] | tonumber) * 1024), prio: (.[4] | tonumber)})')
  zram=$(jq -n -c --arg algo "$(sed 's/.*\[\(.*\)\].*/\1/' /sys/block/zram0/comp_algorithm 2>/dev/null)" \
    --argjson size "$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)" \
    --argjson swappiness "$(cat /proc/sys/vm/swappiness)" '{algo: $algo, size: $size, swappiness: $swappiness}')
  trash_bytes=$(host du -sb "$TRASH" 2>/dev/null | cut -f1)
  trash_items=$(host ls -A "$TRASH" 2>/dev/null | wc -l)
  jq -n -c \
    --arg time "$(date '+%Y-%m-%d %H:%M:%S')" \
    --argjson disks "${disks:-[]}" --argjson mem "$mem" --argjson top "${top:-[]}" --argjson oom "${oom:-[]}" \
    --argjson ssd "$(host mountpoint -q "$MNT" && echo true || echo false)" \
    --argjson link "$(host mountpoint -q "$HOME_LINK" && echo true || echo false)" \
    --argjson earlyoom "$(pgrep -x earlyoom >/dev/null && echo true || echo false)" \
    --argjson trash_bytes "${trash_bytes:-0}" --argjson trash_items "${trash_items:-0}" \
    --argjson swaps "${swaps:-[]}" --argjson zram "$zram" --argjson swap_conf "$(cat "$SWAPCONF" 2>/dev/null || echo 0)" \
    '{time: $time, ssd_mounted: $ssd, home_link: $link, earlyoom: $earlyoom, disks: $disks,
      mem: $mem, top: $top, oom: $oom, trash: {bytes: $trash_bytes, items: $trash_items},
      swaps: $swaps, zram: $zram, swap_conf: $swap_conf}' \
    > /www/status.json.tmp && mv /www/status.json.tmp /www/status.json
}
