# Funciones compartidas por start.sh y cgi-bin/action. Debian /bin/sh es dash: solo POSIX sh.
# "host" ejecuta un comando en los montajes del servidor (requiere privileged + pid: host).
UUID=2c939876-220a-42f8-bb43-14e79be7d9ad
MNT=/home/umbrel/umbrel/external/SSD
HOME_LINK=/home/umbrel/umbrel/home/SSD
LOG=/data/earlyoom.log
OOM_OFF=/data/earlyoom-off   # si existe, EarlyOOM se queda parado (interruptor del panel)
TEST_MARK=/tmp/dh-test       # lo crea start.sh con DH_TEST=1 (contenedor de prueba)

host() { nsenter -t 1 -m -- "$@"; }
host_net() { nsenter -t 1 -m -n -- "$@"; }   # con la red del servidor (para hablar con umbreld)

# Contenedor de prueba: nada de lo que cambia el servidor se ejecuta.
live() { [ ! -e "$TEST_MARK" ] || { echo "Modo prueba: no se cambia nada en el servidor."; return 1; }; }

# El EarlyOOM de ESTE contenedor (con pid: host, pgrep/pkill sin --ns verian los de otros contenedores)
eo_pids() { pgrep --ns $$ --nslist mnt -x earlyoom; }
eo_kill() { pkill --ns $$ --nslist mnt -x earlyoom; }

kb() { awk -v k="$1" '$1 == k":" {print $2}' /proc/meminfo; }

# ---------------------------------------------------------------- EarlyOOM
# Configuracion (panel) en /data/earlyoom.conf, lineas clave=valor:
#   mem, swap = % minimo libre (SIGTERM; SIGKILL a la mitad)
#   avoid / ignore / prefer = nombres de proceso (comm, max 15) separados por espacios
#   dryrun = 1 para solo registrar, sin cerrar nada
# Sin archivo = valores por defecto. Se valida al leer: un archivo roto nunca rompe EarlyOOM.
# Por defecto se protege lo critico por su nombre real: umbreld y Matter Hub son "node",
# Home Assistant es "python3", Matter Server es "MainThread". Immich se cierra primero.
EO_CONF=/data/earlyoom.conf
EO_DEFAULT_AVOID="systemd dockerd containerd sshd tailscaled node python3 MainThread"
EO_DEFAULT_PREFER="immich immich-api"

eo_get() { sed -n "s/^$1=//p" "$EO_CONF" 2>/dev/null | head -1; }
eo_valid_names() { printf '%s\n' "$1" | grep -Eqx '([A-Za-z0-9._-]{1,15}( |$))*'; }

eo_load() {
  if [ -e "$EO_CONF" ]; then
    eo_mem=$(eo_get mem); eo_swap=$(eo_get swap); eo_dryrun=$(eo_get dryrun)
    eo_avoid=$(eo_get avoid); eo_ignore=$(eo_get ignore); eo_prefer=$(eo_get prefer)
  else
    eo_mem=10; eo_swap=10; eo_dryrun=0; eo_avoid=$EO_DEFAULT_AVOID; eo_ignore=""; eo_prefer=$EO_DEFAULT_PREFER
  fi
  case "$eo_mem" in [1-9]|[1-4][0-9]|50) ;; *) eo_mem=10 ;; esac
  case "$eo_swap" in [1-9]|[1-9][0-9]|100) ;; *) eo_swap=10 ;; esac
  [ "$eo_dryrun" = 1 ] || eo_dryrun=0
  eo_valid_names "$eo_avoid" || eo_avoid=$EO_DEFAULT_AVOID
  eo_valid_names "$eo_ignore" || eo_ignore=""
  eo_valid_names "$eo_prefer" || eo_prefer=""
}

# "a b.c" -> ^(a|b\.c)$
eo_regex() { printf '^(%s)$' "$(printf '%s\n' "$1" | sed 's/\./\\./g; s/ /|/g')"; }

run_earlyoom() {
  eo_load
  set -- -r 3600 -m "$eo_mem" -s "$eo_swap"
  [ -n "$eo_avoid" ] && set -- "$@" --avoid "$(eo_regex "$eo_avoid")"
  [ -n "$eo_ignore" ] && set -- "$@" --ignore "$(eo_regex "$eo_ignore")"
  [ -n "$eo_prefer" ] && set -- "$@" --prefer "$(eo_regex "$eo_prefer")"
  # En el contenedor de prueba EarlyOOM nunca cierra nada de verdad
  if [ "$eo_dryrun" = 1 ] || [ -e "$TEST_MARK" ]; then set -- "$@" --dryrun; fi
  earlyoom "$@"
}

# ¿Cabe en RAM lo que vuelve de un swap al vaciarlo, dejando margen sobre el umbral de EarlyOOM?
# $1 = KB que vuelven, $2 = KB libres en otro swap. Exige que queden libres 2 x el umbral de RAM,
# para que apagar swap/zram no provoque que EarlyOOM cierre procesos (p. ej. Home Assistant).
fits() {
  eo_load
  [ $(( $(kb MemAvailable) + ${2:-0} - $1 )) -gt $(( $(kb MemTotal) * eo_mem * 2 / 100 )) ]
}
fits_msg() {  # $1 = que se vacia, $2 = KB que vuelven
  echo "No se cambia: $1 tiene $(( $2 / 1024 )) MB dentro y vaciarlo dejaría la RAM demasiado justa (hay $(( $(kb MemAvailable) / 1024 )) MB libres; EarlyOOM empezaría a cerrar procesos). Activa antes el swap del SSD o espera a que baje el uso."
}

# ---------------------------------------------------------------- SSD
# Monta el SSD en External/SSD y lo enlaza en Home/SSD para que salga en Files.
# Los dos puntos de montaje vacios son inmutables: si el SSD falta, nadie escribe ahi (iria al NVMe).
mount_ssd() {
  live || return 1
  if host mountpoint -q "$MNT"; then
    echo "SSD ya estaba montado."
  elif host test -e "/dev/disk/by-uuid/$UUID"; then
    host test -d "$MNT" || host mkdir -p "$MNT"
    host chattr +i "$MNT"
    host mount -o noatime "UUID=$UUID" "$MNT" || { echo "ERROR al montar el SSD."; return 1; }
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
    host chattr +i "$HOME_LINK"
    host mount --bind "$MNT/datos" "$HOME_LINK" || { echo "ERROR al enlazar Home/SSD."; return 1; }
    echo "Enlazado en Files como Home/SSD."
  fi
}

# ---------------------------------------------------------------- Swap en el SSD
# Archivo en la raiz del SSD (fuera de datos/, no se ve en Files). Tamano en GB en /data/swap-size
# (0 = apagado). Sin archivo = no se toca nada. Prioridad 10: detras del zram (100).
SWAPFILE=$MNT/swapfile
SWAPCONF=/data/swap-size
GB=1073741824

apply_swap() {
  live || return 1
  [ -e "$SWAPCONF" ] || { echo "Swap del SSD sin configurar; no se toca."; return 0; }
  size=$(cat "$SWAPCONF")
  case "$size" in 0|2|4|8) ;; *) echo "ERROR: $SWAPCONF no es válido ($size); no se toca el swap."; return 1 ;; esac
  if grep -q "^$SWAPFILE[[:space:]]" /proc/swaps; then
    [ "$(host stat -c %s "$SWAPFILE")" = "$((size * GB))" ] && { echo "Swap del SSD ya activo ($size GB)."; return 0; }
    used_kb=$(awk -v f="$SWAPFILE" '$1 == f {print $4}' /proc/swaps)
    other_kb=$(awk -v f="$SWAPFILE" 'NR > 1 && $1 != f {s += $3 - $4} END {print s + 0}' /proc/swaps)
    fits "$used_kb" "$other_kb" || { fits_msg "el swap del SSD" "$used_kb"; return 1; }
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
  host swapon -p 10 "$SWAPFILE" || { echo "ERROR activando el swap del SSD."; return 1; }
  echo "Swap del SSD activo: $size GB (detras del zram)."
}

# ---------------------------------------------------------------- zram
# "PCT ALGO" en /data/zram.conf (PCT 0 = apagado). Sin archivo = lo que pone Umbrel (75 zstd)
# y la app no lo toca nunca.
ZRAMCONF=/data/zram.conf
ZDEV=/sys/block/zram0

zram_target() { cat "$ZRAMCONF" 2>/dev/null || echo "75 zstd"; }
zram_valid() { case "$1" in "0 "*|"25 "*|"50 "*|"75 "*|"100 "*) ;; *) return 1 ;; esac
               case "$1" in *" zstd"|*" lz4") ;; *) return 1 ;; esac; }

zram_setup() {  # $1 = bytes, $2 = algoritmo
  echo 1 > $ZDEV/reset && echo "$2" > $ZDEV/comp_algorithm && echo "$1" > $ZDEV/disksize &&
    host mkswap -q /dev/zram0 >/dev/null && host swapon -p 100 /dev/zram0
}

apply_zram() {
  live || return 1
  target=$(zram_target)
  zram_valid "$target" || { echo "ERROR: $ZRAMCONF no es válido ($target); no se toca el zram."; return 1; }
  set -- $target; pct=$1; algo=$2
  [ -e $ZDEV ] || { echo "ERROR: no existe zram0."; return 1; }
  total=$(( $(kb MemTotal) * 1024 ))
  want=$((total / 100 * pct))
  on=0; grep -q '^/dev/zram0[[:space:]]' /proc/swaps && on=1

  # Ya esta como se quiere? (tolerancia de 64 MB en el tamano)
  [ "$pct" = 0 ] && [ $on = 0 ] && { echo "zram ya está apagado."; return 0; }
  if [ $on = 1 ] && [ "$pct" != 0 ]; then
    diff=$(( ($(cat $ZDEV/disksize) - want) / 1048576 ))
    cur_algo=$(sed 's/.*\[\(.*\)\].*/\1/' $ZDEV/comp_algorithm)
    [ "$cur_algo" = "$algo" ] && [ "$diff" -ge -64 ] && [ "$diff" -le 64 ] && { echo "zram ya está así ($pct %, $algo)."; return 0; }
  fi

  # Para cambiarlo hay que vaciarlo: lo que tiene dentro debe caber con margen
  if [ $on = 1 ]; then
    used_kb=$(awk '$1 == "/dev/zram0" {print $4}' /proc/swaps)
    other_kb=$(awk 'NR > 1 && $1 != "/dev/zram0" {s += $3 - $4} END {print s + 0}' /proc/swaps)
    fits "$used_kb" "$other_kb" || { fits_msg "el zram" "$used_kb"; return 1; }
    host swapoff /dev/zram0 || { echo "ERROR al vaciar el zram; no se ha cambiado nada."; return 1; }
  fi

  if [ "$pct" = 0 ]; then echo 1 > $ZDEV/reset; echo "zram apagado."; return 0; fi
  if zram_setup "$want" "$algo"; then
    echo "zram activo: $pct % de la RAM ($((want / 1048576)) MB), $algo."
  else
    zram_setup $((total / 100 * 75)) zstd
    echo "ERROR configurando zram; se ha restaurado lo de Umbrel (75 %, zstd)."; return 1
  fi
}

# ---------------------------------------------------------------- Papelera
# Por la via oficial (umbreld), igual que el boton de Files: tambien actualiza su indice.
empty_trash() {
  live || return 1
  out=$(host_net /usr/local/bin/umbreld client files.emptyTrash.mutate 2>&1) ||
    { echo "ERROR: Umbrel no pudo vaciar la papelera: $(printf '%s' "$out" | tail -1)"; return 1; }
  echo "Papelera vaciada."
}

# ---------------------------------------------------------------- SMART y discos
# Discos fisicos: "nombre transporte" (sata, nvme, usb). Se leen del host para ver tambien
# discos USB conectados despues de arrancar el contenedor.
list_disks() { host lsblk -dno NAME,TRAN | awk '$2 != "" {print $1, $2}'; }
smart_opt() { [ "$1" = usb ] && echo "-d scsi"; }   # el puente USB del Seagate solo acepta scsi

# SMART de todos los discos -> /www/smart.json. -n standby: no despierta discos en reposo.
smart_scan() {
  list_disks | while read -r name tran; do
    host /usr/sbin/smartctl -j -n standby -a $(smart_opt "$tran") "/dev/$name" |
      jq -c --arg n "$name" --arg t "$tran" '{name: $n, tran: $t, data: .}'
  done | jq -s . > /www/smart.json.$$ && mv /www/smart.json.$$ /www/smart.json
}

# ---------------------------------------------------------------- Procesos y su app
# Los 40 procesos con mas memoria, agrupados por nombre (comm, lo que usa EarlyOOM), con la memoria
# total y de que apps vienen. Un proceso de app vive en un contenedor (su cgroup lleva el id); el
# nombre del contenedor empieza por el id de la app, y el nombre bonito sale de su umbrel-app.yml.
procs_json() {
  apps=$(host sh -c 'for f in /home/umbrel/umbrel/app-data/*/umbrel-app.yml; do
      id=${f%/umbrel-app.yml}; id=${id##*/}
      printf "%s\t%s\n" "$id" "$(sed -n "s/^name: *//p" "$f" | head -1 | tr -d "\"'"'"'")"; done' 2>/dev/null)
  ctrs=$(host docker ps --no-trunc --format '{{.ID}}	{{.Names}}' 2>/dev/null)
  ps -eo pid=,rss=,comm= --sort=-rss | head -40 | while read -r pid rss comm; do
    cid=$(grep -o '[0-9a-f]\{64\}' "/proc/$pid/cgroup" 2>/dev/null | head -1)
    if [ -n "$cid" ]; then
      ctr=$(printf '%s\n' "$ctrs" | awk -F'\t' -v c="$cid" '$1 == c {print $2; exit}')
      app=$(printf '%s\n' "$apps" | awk -F'\t' -v a="${ctr%%_*}" '$1 == a {print $2; exit}')
      label=${app:-${ctr:-Contenedor}}
    elif grep -q umbreld "/proc/$pid/cmdline" 2>/dev/null; then
      label="Umbrel (umbreld)"   # umbreld y sus piezas internas (p. ej. esbuild)
    else
      case "$comm" in
        dockerd|containerd*|docker-proxy) label="Docker" ;;
        smbd*|rpcd_*|samba*|nmbd*) label="Compartir archivos (Samba)" ;;
        sshd*) label="Acceso SSH" ;;
        tailscaled) label="Tailscale" ;;
        *) label="Sistema" ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$comm" "$rss" "$label"
  done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], kb: (.[1] | tonumber), app: .[2]})
    | group_by(.name) | map({name: .[0].name, bytes: (map(.kb) | add * 1024), count: length,
        apps: (map(.app) | unique), ok: (.[0].name | test("^[A-Za-z0-9._-]{1,15}$"))})
    | sort_by(-.bytes)'
}

# ---------------------------------------------------------------- Estado -> /www/status.json
collect() {
  disks=$(host findmnt -Jbl -o SOURCE,SIZE,USED,TARGET | jq -c '[.filesystems[]
    | select(.target == "/data" or (.target | test("^/home/umbrel/umbrel/external/[^/]+$")))
    | .source |= sub("\\[.*"; "")] | unique_by(.target)')
  mem=$(awk '{v[$1] = $2 * 1024} END {printf "{\"total\":%d,\"avail\":%d,\"swap_total\":%d,\"swap_free\":%d}",
    v["MemTotal:"], v["MemAvailable:"], v["SwapTotal:"], v["SwapFree:"]}' /proc/meminfo)
  procs=$(procs_json)
  oom=$(grep -h "sending SIG[A-Z]* to process\|would have killed\|dry run" "$LOG" 2>/dev/null | tail -15 |
    jq -R -s -c 'split("\n") | map(select(length > 0)) | reverse')
  swaps=$(tail -n +2 /proc/swaps | jq -R -s -c 'split("\n") | map(select(length > 0) | [splits("\\s+")]
    | {name: .[0], size: ((.[2] | tonumber) * 1024), used: ((.[3] | tonumber) * 1024), prio: (.[4] | tonumber)})')
  ztarget=$(zram_target); zram_valid "$ztarget" || ztarget="75 zstd"
  zram=$(jq -n -c --arg algo "$(sed 's/.*\[\(.*\)\].*/\1/' $ZDEV/comp_algorithm 2>/dev/null)" \
    --argjson size "$(cat $ZDEV/disksize 2>/dev/null || echo 0)" \
    --argjson swappiness "$(cat /proc/sys/vm/swappiness)" \
    --argjson on "$(grep -q '^/dev/zram0[[:space:]]' /proc/swaps && echo true || echo false)" \
    --argjson custom "$([ -e "$ZRAMCONF" ] && echo true || echo false)" \
    --arg target "$ztarget" \
    '{algo: $algo, size: $size, swappiness: $swappiness, on: $on, custom: $custom,
      pct: ($target | split(" ")[0] | tonumber), target_algo: ($target | split(" ")[1])}')
  # Swap del SSD: lo configurado (null = sin configurar) y lo real se envian por separado
  swap_conf=$(cat "$SWAPCONF" 2>/dev/null); case "$swap_conf" in 0|2|4|8) ;; *) swap_conf=null ;; esac
  eo_load
  eo_cfg=$(jq -n -c --argjson mem "$eo_mem" --argjson swap "$eo_swap" --arg avoid "$eo_avoid" --arg ignore "$eo_ignore" \
    --arg prefer "$eo_prefer" --argjson dryrun "$([ "$eo_dryrun" = 1 ] && echo true || echo false)" \
    --argjson custom "$([ -e "$EO_CONF" ] && echo true || echo false)" \
    '{mem: $mem, swap: $swap, avoid: $avoid, ignore: $ignore, prefer: $prefer, dryrun: $dryrun, custom: $custom}')
  trash_bytes=$(host du -sb /home/umbrel/umbrel/trash 2>/dev/null | cut -f1)
  trash_items=$(host ls -A /home/umbrel/umbrel/trash 2>/dev/null | wc -l)
  jq -n -c \
    --arg time "$(date '+%Y-%m-%d %H:%M:%S')" --argjson epoch "$(date +%s)" \
    --argjson test "$([ -e "$TEST_MARK" ] && echo true || echo false)" \
    --argjson disks "${disks:-[]}" --argjson mem "$mem" --argjson procs "${procs:-[]}" --argjson oom "${oom:-[]}" \
    --argjson ssd "$(host mountpoint -q "$MNT" && echo true || echo false)" \
    --argjson link "$(host mountpoint -q "$HOME_LINK" && echo true || echo false)" \
    --argjson earlyoom "$(eo_pids >/dev/null && echo true || echo false)" \
    --argjson earlyoom_off "$([ -e "$OOM_OFF" ] && echo true || echo false)" \
    --argjson trash_bytes "${trash_bytes:-0}" --argjson trash_items "${trash_items:-0}" \
    --argjson swaps "${swaps:-[]}" --argjson zram "$zram" --argjson swap_conf "$swap_conf" \
    --argjson eo_cfg "$eo_cfg" \
    '{time: $time, epoch: $epoch, test: $test, ssd_mounted: $ssd, home_link: $link,
      earlyoom: $earlyoom, earlyoom_off: $earlyoom_off, disks: $disks,
      mem: $mem, procs: $procs, oom: $oom, trash: {bytes: $trash_bytes, items: $trash_items},
      swaps: $swaps, zram: $zram, swap_conf: $swap_conf, earlyoom_cfg: $eo_cfg}' \
    > /www/status.json.$$ && mv /www/status.json.$$ /www/status.json
}
