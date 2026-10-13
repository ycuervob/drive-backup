# drive-backup

Backups de bases de datos y archivos de servidores Linux, subidos a Google Drive con [rclone](https://rclone.org).

Google Drive es el destino por defecto, pero se puede usar cualquier servicio compatible con rclone (OneDrive, Dropbox, S3, Backblaze B2, SFTP, etc.). Ver [Otros servicios](#otros-servicios).

Los comandos de backup de cada servidor se definen en `db.sh` y `files.sh` (`mysqldump`, `docker exec`, `cp`, `zip`, `tar`...). La subida, la verificación, la retención, los logs y las notificaciones son comunes a todos los servidores.

## Estructura

```
drive-backup/
├── backup.sh              # Orquestador: ejecuta db.sh y files.sh, empaqueta, sube, verifica y limpia
├── restore.sh             # Lista y descarga backups
├── setup.sh               # Instalación: crea los archivos de configuración y programa el cron
├── lib/common.sh          # Funciones compartidas (logs, configuración, conexión con rclone)
├── config.env.example     # → config.env
├── db.sh.example          # → db.sh
└── files.sh.example       # → files.sh
```

`config.env`, `db.sh` y `files.sh` se crean a partir de las plantillas `.example` y no se versionan. Un `git pull` actualiza el resto sin modificar la configuración de cada servidor.

## Funcionamiento

```
backup.sh
 ├─ 1. db.sh     → escribe en $OUT (carpeta temporal db/)
 ├─ 2. files.sh  → escribe en $OUT (carpeta temporal files/)
 ├─ 3. Empaqueta todo en un archivo: BackUp_<servidor>_<AAAA-MM-DD_HHMMSS>.zip
 │       ├── db/...
 │       ├── files/...
 │       └── MANIFEST.txt
 ├─ 4. Sube el archivo a <DRIVE_PATH>/<SERVER_NAME>/ y verifica el MD5
 ├─ 5. Retención: elimina los backups con más de N días (remoto y local)
 └─ 6. Notificación (webhook o correo)
```

Cada ejecución genera un único archivo:

```
Backups/
└── servidor1/
    ├── BackUp_servidor1_2026-09-26_020000.zip
    └── BackUp_servidor1_2026-09-27_020000.zip
```

### Formato del archivo

`ARCHIVE_FORMAT` define el formato:

| Valor | Descripción |
|---|---|
| `zip` (por defecto) | Compatible con cualquier sistema. No conserva dueño ni atributos extendidos. |
| `tar.gz` | Conserva permisos, dueño, enlaces, ACL y atributos extendidos (xattrs). |
| `tar` | Igual que `tar.gz`, sin compresión. |

Se debe usar `tar` o `tar.gz` cuando los archivos guardan metadatos en xattrs, como Supabase Storage (`content-type`, `etag`...). Para restaurarlos, extraer como root:

```bash
tar --xattrs --xattrs-include='*' --acls -xpf BackUp_....tar -C destino
```

`ARCHIVE_PREFIX` cambia el prefijo del nombre (por defecto `BackUp`).

### Espacio en disco

El archivo final y los logs se guardan en `backups/` y `logs/` dentro del repo. La carpeta temporal se elimina al terminar.

Lo que `db.sh` y `files.sh` copian a `$OUT` ocupa espacio hasta que se genera el archivo final. Para carpetas grandes se recomienda un enlace simbólico (`ln -s /ruta "$OUT/nombre"`): su contenido se agrega directamente al archivo final, sin copia intermedia. `MIN_FREE_MB` evita que el backup inicie si no hay espacio suficiente.

### Comportamiento ante errores

- Si `db.sh` o `files.sh` fallan, no se sube nada (configurable con `UPLOAD_ON_PARTIAL_FAILURE`).
- Si la subida o la verificación fallan, no se elimina ningún backup anterior.
- Un lock (`flock`) impide ejecuciones simultáneas.
- La retención solo elimina archivos con el formato `BackUp_<servidor>_<fecha>`. Otros archivos de la carpeta no se modifican.

## Instalación

Requisitos: Linux, bash ≥ 4.4, `zip` o `tar`, rclone y las herramientas que usen los scripts (`docker`, `mysqldump`...). `setup.sh` puede instalar rclone.

```bash
git clone https://github.com/<usuario>/drive-backup.git
cd drive-backup
sudo ./setup.sh --install-rclone     # instala rclone y crea config.env, db.sh y files.sh
nano config.env                      # destino, retención y variables
nano db.sh files.sh                  # comandos de backup
```

### Autenticación con Google Drive

Se recomienda usar un client ID propio. El client ID compartido de rclone tiene límites de uso globales y puede rechazar subidas grandes (`403 rateLimitExceeded`). Para crearlo:

1. En [Google Cloud Console](https://console.cloud.google.com), crear un proyecto y habilitar **Google Drive API**.
2. Configurar la pantalla de consentimiento de OAuth. Si es de tipo *Externo*, publicarla; en modo de prueba el token vence a los 7 días.
3. En **Credenciales**, crear un **ID de cliente de OAuth** de tipo **App de escritorio**.

El token se genera en un equipo con navegador, con [rclone instalado](https://rclone.org/install/):

```bash
rclone authorize "drive" "CLIENT_ID" "CLIENT_SECRET"
# Imprime un JSON: {"access_token":"ya29...","token_type":"Bearer","refresh_token":"1//0g...","expiry":"..."}
```

En `config.env`, con comillas simples:

```bash
DRIVE_AUTH="token"
DRIVE_CLIENT_ID='CLIENT_ID'
DRIVE_CLIENT_SECRET='CLIENT_SECRET'
DRIVE_TOKEN='{"access_token":"ya29...","token_type":"Bearer","refresh_token":"1//0g...","expiry":"..."}'
```

Si el equipo no tiene rclone, se puede generar desde el servidor con un túnel SSH:

```bash
ssh -L 53682:localhost:53682 usuario@servidor
rclone authorize "drive" "CLIENT_ID" "CLIENT_SECRET" --auth-no-open-browser
# Abrir en el navegador local la URL que imprime (http://127.0.0.1:53682/auth?...)
```

rclone renueva el token automáticamente. La copia renovada se guarda en `.rclone.conf` (permisos 600) y se regenera solo cuando cambia `config.env`. Las mismas credenciales se pueden usar en varios servidores, siempre que cada uno tenga un `SERVER_NAME` distinto.

Otras opciones de `DRIVE_AUTH`:

- `service_account`: usa un JSON de cuenta de servicio. Solo funciona con Unidades compartidas (`DRIVE_TEAM_DRIVE`), ya que las cuentas de servicio no tienen espacio propio.
- `rclone_remote`: usa un remote creado con `rclone config`.

### Otros servicios

rclone soporta [más de 70 servicios](https://rclone.org/overview/). Para usar uno distinto de Google Drive:

1. Crear el remote con `rclone config`, con el mismo usuario que ejecuta el backup.
2. Configurar `config.env`:

   ```bash
   DRIVE_AUTH="rclone_remote"
   RCLONE_REMOTE="mi_remote"       # nombre del remote en rclone config
   DRIVE_PATH="Backups"            # carpeta o bucket/carpeta de destino
   ```

3. Probar con `./backup.sh --test`.

Las variables `DRIVE_*` aplican a cualquier remote, aunque conservan ese nombre. Las opciones exclusivas de Drive (`DRIVE_USE_TRASH`, `DRIVE_TEAM_DRIVE`...) se ignoran. Si el servicio no soporta MD5, usar `VERIFY_UPLOAD=false`.

### Archivos grandes

Para subidas de varios GB se recomienda:

```bash
RCLONE_EXTRA_FLAGS="--timeout 1h --drive-chunk-size 128M"
```

### Pruebas

```bash
./backup.sh --test            # sube y elimina un archivo de prueba
./backup.sh --test-email      # envía un correo de prueba
./db.sh                       # ejecuta solo db.sh    → ./test-output/db
./files.sh                    # ejecuta solo files.sh → ./test-output/files
./backup.sh --dry-run         # flujo completo sin subir ni eliminar
./backup.sh                   # backup real
```

### Programación

```bash
./setup.sh --cron "0 2 * * *"   # todos los días a las 2:00 (crontab del usuario actual)
./setup.sh --remove-cron        # eliminar la tarea
```

Si los scripts necesitan permisos de root (por ejemplo, para leer `/var/lib/docker/volumes`), ejecutar `setup.sh` con `sudo` para que la tarea quede en el crontab de root.

Cada ejecución genera un log en `LOG_DIR`. Los logs no se suben al destino.

## db.sh y files.sh

Son scripts de bash sin estructura fija. La única regla:

> Todo lo que se escriba en `$OUT` se incluye en el backup.

Puede ser un archivo, varios o una carpeta. `backup.sh` agrega la fecha al archivo final, por lo que no es necesario incluirla en los nombres.

```bash
# mysqldump
MYSQL_PWD="$DB_PASSWORD" mysqldump -u root --all-databases > "$OUT/mysql.sql"

# mysqldump dentro de Docker (-T: sin TTY, necesario en cron)
docker compose exec -T -e MYSQL_PWD="$DB_PASSWORD" db mysqldump -u root --all-databases > "$OUT/mysql.sql"

# Carpeta _data de Postgres, con el contenedor detenido
docker stop pg; trap 'docker start pg' EXIT
cp -a /var/lib/docker/volumes/pg_data/_data "$OUT/postgres_data"
```

```bash
# Enlace simbólico (recomendado para carpetas grandes, sin copia intermedia)
ln -s /var/www/html "$OUT/html"

# Copia
cp -a /var/www/html "$OUT/html"

# zip / tar
(cd /var/www && zip -qr "$OUT/sitio.zip" html)
tar -czf "$OUT/uploads.tar.gz" -C /var/www/html/wp-content uploads
```

Notas:

- Las plantillas deben conservar el encabezado que carga `config.env` y define `$OUT`. Solo se reemplaza la sección de comandos.
- Las variables de `config.env` están disponibles en los scripts (`$DB_PASSWORD`, rutas, nombres de contenedores...). Las contraseñas con `$` deben ir entre comillas simples.
- Si un comando falla, el script se detiene y no se sube nada.
- Las plantillas incluyen un `exit 1` para evitar subir backups vacíos. Se debe eliminar al agregar los comandos.
- `ENABLE_DB=false` o `ENABLE_FILES=false` desactivan cada parte.
- Bajo cron el `PATH` es reducido. Si un comando está en `/usr/local/bin`, agregar `export PATH="/usr/local/bin:$PATH"`.

## Restauración

```bash
./restore.sh list                          # backups de este servidor
./restore.sh list otro-servidor            # backups de otro servidor
./restore.sh latest                        # descarga el último en ./restore/ y verifica su integridad
./restore.sh get 2026-09-27_020000 /tmp/r  # descarga uno por fecha o nombre
```

El contenido (`db/`, `files/`) es exactamente lo que generaron `db.sh` y `files.sh`, y se restaura según el método usado (`mysql < archivo.sql`, `unzip`, `tar -x`, copiar `_data` con el contenedor detenido, etc.).

## Notificaciones

- `NOTIFY_ON`: `always`, `error` o `never`.
- `NOTIFY_WEBHOOK_URL`: envía un POST JSON `{"text": "...", "content": "..."}`. Compatible con Google Chat, Slack y Discord.
- Correo por SMTP: se envía con `curl`, sin necesidad de postfix ni `mail`.

```bash
NOTIFY_EMAIL="destino@ejemplo.com"            # uno o varios, separados por coma
SMTP_URL="smtps://smtp.gmail.com:465"
SMTP_USER="remitente@ejemplo.com"
SMTP_PASSWORD='abcdefghijklmnop'
```

En Gmail y Google Workspace, `SMTP_PASSWORD` debe ser una [contraseña de aplicación](https://myaccount.google.com/apppasswords). Probar con `./backup.sh --test-email`.

Si `SMTP_USER` está vacío, se usa el comando `mail` del sistema.

## Seguridad

- `config.env` contiene el token de acceso y las contraseñas. Debe tener permisos `600` y no debe versionarse (está incluido en `.gitignore`).
- El token da acceso a todo el Drive de la cuenta. Se recomienda una cuenta dedicada o una Unidad compartida.
- Para cifrar los backups, usar un remote [`crypt`](https://rclone.org/crypt/) de rclone con `DRIVE_AUTH="rclone_remote"`.
