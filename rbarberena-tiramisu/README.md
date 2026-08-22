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
      - /home/umbrel/umbrel/app-data/rbarberena-tiramisu/data/virtual:/media/tiramisu:rslave
```

y reinicia la app de Plex. Después añade `/media/tiramisu` como biblioteca.

El `rslave` es lo que hace que Plex vea el montaje FUSE que crea Tiramisu; con
un bind normal solo vería una carpeta vacía.

Usa la sintaxis corta, no la larga (`type: bind` / `propagation:`). El parche
de compose de `umbreld` da por hecho que cada entrada de `volumes` es un string
y falla con `TypeError: volume?.replace is not a function` si encuentra un
mapa.

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

**Se queda sin memoria / tumba el Umbrel entero**

Los defaults de upstream asumen una máquina holgada. Los que más pesan:

| Parámetro | Default | Efecto |
|---|---|---|
| GoStorm `CacheSize` | 128 MB **por torrent activo** | se multiplica por cada torrent caliente |
| `master_concurrency_limit` | 25 | durante un escaneo permite hasta 20 simultáneos |
| `read_ahead_budget_mb` | 256 | presupuesto global de lectura anticipada |

Un `Run` del sync registra cientos de torrents, y el escaneo posterior de
Plex/Jellyfin abre suficientes ficheros a la vez como para mantener ~20
calientes. Sin techo, eso se lleva por delante el host.

Esta app pone dos límites:

- `mem_limit` (por defecto `1600m`): techo duro del contenedor. Si se pasa, el
  kernel mata Tiramisu y el contenedor vuelve solo, en lugar de que el OOM
  killer del host elija víctima entre todas tus apps.
- `GOMEMLIMIT` (por defecto `1024MiB`): límite blando del heap de Go. Hace que
  el recolector apriete al acercarse, así que normalmente no se llega a tocar
  el techo duro.

Si tu Umbrel va sobrado de RAM y quieres más margen, súbelos en el
`docker-compose.yml` de la app manteniendo `GOMEMLIMIT` bastante por debajo de
`mem_limit`: el proceso también necesita sitio para stacks, mmap y los buffers
de FUSE, que no son heap.

Para bajar el consumo aún más, en el Control Panel:

- `master_concurrency_limit` → 6-8
- `read_ahead_budget_mb` → 96
- GoStorm `CacheSize` → 32-64 MB (está en la sección de ajustes de GoStorm, no
  en `config.json`)

Los dos primeros ya vienen ajustados en el `config.json` que trae esta app,
pero solo aplican a instalaciones nuevas: si ya la tenías instalada, tu
`config.json` no se toca y hay que cambiarlos a mano.

**El primer escaneo de Plex va lentísimo**

Es esperado, y viene avisado por upstream: el servidor de medios abre y cierra
cientos de ficheros durante el análisis, y eso congestiona el motor. Espera a
que termine el escaneo antes de intentar reproducir nada.

Y desactiva en Plex todo lo que lea el fichero completo, o te descargarás la
biblioteca entera de fondo: análisis multimedia exhaustivo, miniaturas de
vista previa de vídeo, análisis de intensidad sonora y detección de
intros/créditos.

**No encuentro el token de Plex**

El indicador de Plex del dashboard se pone verde solo con la URL, porque el
health check hace un `GET /` sin autenticar. El token hace falta igualmente
para los streams activos, los pósters, el refresco de biblioteca tras un sync
y la watchlist. Sácalo del disco:

```sh
sudo grep -o 'PlexOnlineToken="[^"]*"' \
  ~/umbrel/app-data/plex/data/config/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml
```

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
