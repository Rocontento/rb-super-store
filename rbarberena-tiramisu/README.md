# Tiramisu en Umbrel

Empaquetado de [MrRobotoGit/tiramisu](https://github.com/MrRobotoGit/tiramisu) para
umbrelOS, anclado a la imagen `mrrobotogit/tiramisu:v1.9.43` (amd64 y arm64).

## Cómo probarlo

1. En umbrelOS, ve a la App Store → botón de comunidad → añade
   `https://github.com/Rocontento/rb-super-store` (si no la tienes ya).
2. Instala **Tiramisu**. La primera vez tarda un poco: la imagen ronda los
   200 MB.
3. Abre la app. Te lleva al **Dashboard** (`/dashboard`). El **panel de
   control** está en `/control`.

### Comprobar que arrancó bien

Por SSH en tu Umbrel:

```sh
docker logs -f rbarberena-tiramisu_tiramisu_1
```

Deberías ver `Starting tiramisu` y luego el montaje FUSE. Para confirmar que el
montaje se ve desde el host:

```sh
mount | grep tiramisu-mkv-virtual
ls ~/umbrel/app-data/rbarberena-tiramisu/data/virtual
```

### Configuración mínima

Todo se hace desde el panel de control (`/control`), que escribe en
`~/umbrel/app-data/rbarberena-tiramisu/data/config.json`:

- **TMDB API key** — obligatoria para que el motor de sincronización descubra
  títulos.
- **Prowlarr** (opcional) — si no lo pones, cae a Torrentio.
- **Plex** — `url`, `token` y `library_id`. Usa la IP de tu Umbrel, por ejemplo
  `http://192.168.1.50:32400`. **No uses `127.0.0.1`**: dentro del contenedor
  eso apunta a Tiramisu, no a tu Umbrel.

También puedes editar el JSON a mano y reiniciar la app desde umbrelOS.

### Conectar Plex o Jellyfin

Los `.mkv` virtuales viven en el host, en:

```
~/umbrel/app-data/rbarberena-tiramisu/data/virtual
```

Para que la app de Plex/Jellyfin de Umbrel los vea, hay que montar esa ruta
dentro de su contenedor. Edita el compose de la app de Plex
(`~/umbrel/app-data/<app-de-plex>/docker-compose.yml`), añade a `volumes:`:

```yaml
      - type: bind
        source: /home/umbrel/umbrel/app-data/rbarberena-tiramisu/data/virtual
        target: /media/tiramisu
        bind:
          propagation: rslave
```

y reinicia la app de Plex. Después añade `/media/tiramisu` como biblioteca.

El `rslave` es lo que hace que Plex vea el montaje FUSE que crea Tiramisu; con
un bind normal solo vería una carpeta vacía.

## Estructura de datos

Todo lo que persiste está bajo `~/umbrel/app-data/rbarberena-tiramisu/data/`:

| Ruta         | Contenido                                            |
|--------------|------------------------------------------------------|
| `config.json`| Configuración. Montada en lectura/escritura porque el panel de control la reescribe. |
| `state/`     | Base de datos del motor de torrents, baneos de peers, caché de blocklist y logs. |
| `real/`      | Los stubs `.mkv` a partir de los que se construye la biblioteca. |
| `virtual/`   | El montaje FUSE. Vacío mientras la app está parada.  |

## Problemas conocidos

**El contenedor no arranca y los logs mencionan un "shared mount"**

Docker necesita que el punto de montaje del host sea compartido para poder
propagar el FUSE hacia fuera. Por SSH:

```sh
sudo mount --make-rshared /
```

Y reinicia la app. Para que sobreviva a reinicios del Umbrel, añádelo a
`/etc/rc.local` o a una unidad de systemd.

**La app no arranca después de un corte de luz / `Transport endpoint is not connected`**

Quedó un montaje FUSE huérfano. Por SSH:

```sh
sudo umount -l ~/umbrel/app-data/rbarberena-tiramisu/data/virtual
```

Y reinicia la app.

**Consumo de memoria**

El límite del heap de Go se fija en `GOMEMLIMIT`, por defecto `2200MiB` (lo que
recomienda upstream para una máquina de 4 GB). Si tu Umbrel tiene más RAM y
quieres darle más margen, edítalo en el `docker-compose.yml` de la app.

## Requisitos del contenedor

Esta app corre con más privilegios de lo habitual, porque monta un sistema de
ficheros real en el kernel:

- `/dev/fuse`
- `CAP_SYS_ADMIN` (montar FUSE)
- `CAP_NET_ADMIN` (NAT-PMP e `iptables` para el reenvío de puerto con VPN)
- `apparmor:unconfined`

## Nota legal

Tiramisu es un motor de streaming; no aloja ni indexa contenido. Qué se
descarga y se reproduce lo decides tú, y las leyes sobre eso cambian según el
país.
