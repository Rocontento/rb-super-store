#!/bin/sh
# Disk Helper: monta el SSD, ejecuta EarlyOOM y sirve el panel (detras del login de Umbrel).
. /app/lib.sh

# 1. Montar el SSD (usa los binarios del host, no necesita red)
mount_ssd && apply_swap
# zram: solo si se ha cambiado desde el panel; si no, se deja lo de Umbrel
[ -e "$ZRAMCONF" ] && apply_zram

# 2. Herramientas del contenedor (se instalan en cada arranque; reintenta si no hay red)
export DEBIAN_FRONTEND=noninteractive
until apt-get update -qq && apt-get install -y -qq earlyoom busybox procps smartmontools jq >/dev/null; do
  echo "No se pudieron instalar las herramientas; reintento en 60 s"
  sleep 60
done

# 3. Panel web: estaticos + accion CGI
mkdir -p /www/cgi-bin
cp /app/www/index.html /www/
cp /app/cgi-bin/action /www/cgi-bin/action && chmod +x /www/cgi-bin/action
smart_scan &
# El primer estado se toma 3 s despues, cuando EarlyOOM ya ha arrancado
( sleep 3; while true; do collect; sleep 30; done ) &
( while true; do sleep 3600; smart_scan; done ) &
busybox httpd -p 8790 -h /www

# 4. EarlyOOM supervisado: si se cae o se reinicia desde el panel, vuelve a arrancar en 2 s.
#    Si existe $OOM_OFF (interruptor del panel), se queda parado. Registro con fecha en /data.
touch "$LOG" && tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
while true; do
  if [ -e "$OOM_OFF" ]; then sleep 2; continue; fi
  earlyoom -r 3600 --avoid '^(init|systemd|dockerd|containerd|umbreld|sshd)$' 2>&1 |
    while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') $line"; done | tee -a "$LOG"
  sleep 2
done
