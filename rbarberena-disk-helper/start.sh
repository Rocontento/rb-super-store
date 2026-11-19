#!/bin/sh
# Disk Helper: monta el SSD interno, ejecuta EarlyOOM y sirve una pagina de estado.
# Los comandos con "host" se ejecutan en los montajes del servidor, no del contenedor
# (requiere privileged + pid: host en docker-compose.yml).
UUID=2c939876-220a-42f8-bb43-14e79be7d9ad
MNT=/home/umbrel/umbrel/external/SSD
PORT=8790

host() { nsenter -t 1 -m -- "$@"; }

# 1. Montar el SSD (solo si no esta ya montado y el disco existe)
if host mountpoint -q "$MNT"; then
  echo "SSD ya estaba montado en $MNT"
elif host test -e "/dev/disk/by-uuid/$UUID"; then
  host mkdir -p "$MNT" && host mount -o noatime "UUID=$UUID" "$MNT" && echo "SSD montado en $MNT"
else
  echo "ERROR: no se encuentra el SSD ($UUID); no se monta nada"
fi

# 2. Primera vez: dar el disco al usuario umbrel (uid 1000) para Files y las apps
if host mountpoint -q "$MNT" && [ "$(host stat -c %u "$MNT")" = 0 ]; then
  host chown 1000:1000 "$MNT"
  host install -d -o 1000 -g 1000 "$MNT/datos"
  echo "Permisos asignados a umbrel y creada la carpeta datos/"
fi

# 2b. Mostrar el SSD en Files: la barra lateral de Umbrel solo lista discos USB,
#     asi que enlazamos SSD/datos dentro de Home/SSD (bind mount).
HOME_LINK=/home/umbrel/umbrel/home/SSD
if host mountpoint -q "$MNT" && ! host mountpoint -q "$HOME_LINK"; then
  host test -d "$HOME_LINK" || host install -d -o 1000 -g 1000 "$HOME_LINK"
  # Inmutable mientras no este montado: si el SSD falta, nadie escribe ahi (iria al NVMe)
  host chattr +i "$HOME_LINK"
  host mount --bind "$MNT/datos" "$HOME_LINK" && echo "SSD visible en Files como Home/SSD"
fi

# 3. Herramientas (se instalan en el contenedor en cada arranque; reintenta si no hay red)
export DEBIAN_FRONTEND=noninteractive
until apt-get update -qq && apt-get install -y -qq earlyoom busybox procps >/dev/null; do
  echo "No se pudieron instalar las herramientas; reintento en 60 s"
  sleep 60
done

# 4. Pagina de estado en http://umbrel.local:8790
mkdir -p /www
(
  while true; do
    {
      echo "<meta http-equiv=refresh content=60><pre>Disk Helper - $(date)"
      echo; echo "== SSD =="
      host findmnt -no SOURCE,TARGET,OPTIONS "$MNT" || echo "NO MONTADO"
      host df -h "$MNT" | tail -1
      echo; echo "== Memoria =="
      free -h
      echo; echo "== EarlyOOM =="
      pgrep -x earlyoom >/dev/null && echo "activo" || echo "NO activo"
      echo "</pre>"
    } > /www/index.html.tmp && mv /www/index.html.tmp /www/index.html
    sleep 60
  done
) &
busybox httpd -p "$PORT" -h /www

# 5. EarlyOOM en primer plano: si se cae, Docker reinicia el contenedor
exec earlyoom -r 3600 --avoid '^(init|systemd|dockerd|containerd|umbreld|sshd)$'
