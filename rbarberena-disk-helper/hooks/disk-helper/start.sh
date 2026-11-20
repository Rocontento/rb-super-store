#!/bin/sh
# Disk Helper: monta el SSD, ejecuta EarlyOOM y sirve el panel (detras del login de Umbrel).
. /app/lib.sh

# 1. Montar el SSD (usa los binarios del host, no necesita red)
mount_ssd && apply_swap

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
collect
smart_scan &
( while true; do sleep 30; collect; done ) &
( while true; do sleep 3600; smart_scan; done ) &
busybox httpd -p 8790 -h /www

# 4. EarlyOOM en primer plano; su registro (con fecha) se guarda en /data para el historial.
#    Si se cae, termina el script y Docker reinicia el contenedor.
touch "$LOG" && tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
earlyoom -r 3600 --avoid '^(init|systemd|dockerd|containerd|umbreld|sshd)$' 2>&1 |
  while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') $line"; done | tee -a "$LOG"
