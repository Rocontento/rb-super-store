#!/bin/sh
# Disk Helper: monta el SSD, ejecuta EarlyOOM y sirve el panel (detras del login de Umbrel).
. /app/lib.sh

# Parar limpio (Docker manda SIGTERM): cerrar tambien httpd, EarlyOOM y los bucles
trap 'trap - TERM INT; kill 0; exit 0' TERM INT

# 0. Contenedor de prueba (DH_TEST=1, con /data vacio): marca local que desactiva todo lo que
#    cambia el servidor (ver live() en lib.sh) y fuerza EarlyOOM en modo --dryrun.
[ "$DH_TEST" = 1 ] && touch "$TEST_MARK"

# 1. SSD, swap y zram (usa los binarios del host, no necesita red)
mount_ssd && apply_swap
# zram: solo si se ha cambiado desde el panel; si no, se deja lo de Umbrel
[ -e "$ZRAMCONF" ] && apply_zram

# 2. Herramientas del contenedor. Umbrel borra el contenedor al pararlo, asi que se instalan en
#    cada arranque. Los .deb se guardan en /data/debs: sin red (corte de luz, router aun sin
#    arrancar) se instalan desde ahi y EarlyOOM no se queda sin arrancar.
export DEBIAN_FRONTEND=noninteractive
PKGS="earlyoom busybox procps jq"
mkdir -p /data/debs/partial
apt_ok() {
  apt-get update -qq && apt-get install -y -qq -o Dir::Cache::archives=/data/debs $PKGS >/dev/null &&
    apt-get autoclean -qq -o Dir::Cache::archives=/data/debs
}
if ! apt_ok; then
  echo "Sin red o sin repositorio: instalando desde la copia local de /data/debs"
  dpkg -i /data/debs/*.deb >/dev/null 2>&1 || until apt_ok; do
    echo "No se pudieron instalar las herramientas; reintento en 60 s"
    sleep 60
  done
fi

# 3. Panel web: estaticos + accion CGI. Solo acepta conexiones de la puerta de enlace del
#    contenedor, que es por donde entra el login de Umbrel (umbreld); las demas apps de la red
#    interna de Docker no pueden llamar al panel directamente.
mkdir -p /www/cgi-bin
cp /app/www/index.html /www/
cp /app/cgi-bin/action /www/cgi-bin/action && chmod +x /www/cgi-bin/action
GW=$(busybox ip route | awk '$1 == "default" {print $3; exit}')
printf 'A:%s\nA:127.0.0.1\nD:*\n' "$GW" > /etc/httpd.conf
echo "Panel solo accesible desde $GW (login de Umbrel)"
smart_scan &
# El primer estado se toma 3 s despues, cuando EarlyOOM ya ha arrancado
( sleep 3; while true; do collect; sleep 30; done ) &
( while true; do sleep 3600; smart_scan; done ) &
busybox httpd -p 8790 -h /www -c /etc/httpd.conf

# 4. EarlyOOM supervisado: si se cae o se reinicia desde el panel, vuelve a arrancar en 2 s.
#    Si existe $OOM_OFF (interruptor del panel), se queda parado. Registro con fecha en /data.
#    La configuracion ($EO_CONF) se lee en cada arranque de EarlyOOM (ver run_earlyoom en lib.sh).
touch "$LOG" && tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
#    En segundo plano + wait: asi el trap de SIGTERM se atiende al momento.
while true; do
  if [ -e "$OOM_OFF" ]; then sleep 2 & wait $!; continue; fi
  run_earlyoom 2>&1 |
    while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') $line"; done | tee -a "$LOG" &
  wait $!
  sleep 2 & wait $!
done
