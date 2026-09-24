# drive-backup

Backups de bases de datos y archivos de un servidor Linux, subidos a **Google Drive** con [rclone](https://rclone.org).

Se clona en cada servidor, se llena `config.env` y se escriben **tus propios comandos** en `db.sh` y `files.sh`. Pueden ser un `mysqldump`, un `docker exec`, un `cp` de la carpeta `_data`, un `zip -r`, un `tar` o lo que ese servidor necesite. Lo demás es igual en todos: subida, verificación, retención, logs y notificaciones.

```
drive-backup/
├── backup.sh                 # Orquestador: ejecuta db.sh + files.sh, sube, verifica, limpia
├── restore.sh                # Lista y descarga backups desde Drive
├── setup.sh                  # Instalación: dependencias, archivos locales y cron
├── config.env.example        # Configuración: Drive, retención, notificaciones y tus variables
├── lib/common.sh             # Funciones compartidas (logs, config, conexión con Drive)
└── templates/
    ├── db.sh.example         # Plantilla libre + ejemplos (mysqldump, docker, _data, pg_dump)
    └── files.sh.example      # Plantilla libre + ejemplos (cp, zip -r, tar)

# Archivos que crea setup.sh en cada servidor (ignorados por git):
config.env   db.sh   files.sh   .rclone.conf
```

Como `config.env`, `db.sh` y `files.sh` no se versionan, un `git pull` actualiza el orquestador sin pisar lo que ajustaste en cada servidor.

## Flujo

```
backup.sh
 ├─ 1. db.sh     → $BACKUP_DIR/<fecha>/db/*
 ├─ 2. files.sh  → $BACKUP_DIR/<fecha>/files/*
 ├─ 3. SHA256SUMS + MANIFEST.txt
 ├─ 4. rclone copy → Drive:<DRIVE_PATH>/<SERVER_NAME>/<fecha>/   (+ rclone check)
 ├─ 5. Retención: borra en Drive lo más viejo que REMOTE_RETENTION_DAYS
 │                y en local lo más viejo que LOCAL_RETENTION_DAYS
 └─ 6. Notificación (webhook / correo) y subida del log
```

Medidas de seguridad:

- Si `db.sh` o `files.sh` fallan, **no se sube nada**. Se puede cambiar con `UPLOAD_ON_PARTIAL_FAILURE`.
- Si la subida o la verificación fallan, **no se borra nada**, ni en Drive ni en local.
- Un lock (`flock`) impide que dos ejecuciones corran al mismo tiempo.
- En Drive solo se borran carpetas con nombre de backup (`AAAA-MM-DD_HHMMSS`). Si hay otras carpetas, no se tocan.

## Instalación en un servidor

Requisitos: Linux, bash ≥ 4.4, `sha256sum` y rclone, más las herramientas que usen tus scripts (`zip`, `docker`, `mysqldump`...). `setup.sh` puede instalar rclone.

```bash
git clone https://github.com/<tu-usuario>/drive-backup.git /opt/drive-backup
cd /opt/drive-backup
sudo ./setup.sh --install-rclone     # instala rclone y crea config.env, db.sh, files.sh
sudo nano config.env                 # Drive, retención y tus variables
sudo nano db.sh files.sh             # tus comandos de backup
```

### Obtener el token de Google Drive

El servidor no tiene navegador, así que el token se genera en tu computador.

**Opción A (recomendada): en tu Mac**

```bash
brew install rclone
rclone authorize "drive"
# Se abre el navegador, inicias sesión y la terminal imprime un JSON:
# {"access_token":"ya29...","token_type":"Bearer","refresh_token":"1//0g...","expiry":"..."}
```

Copia ese JSON completo en `config.env`, **entre comillas simples**:

```bash
DRIVE_AUTH="token"
DRIVE_TOKEN='{"access_token":"ya29...","token_type":"Bearer","refresh_token":"1//0g...","expiry":"..."}'
```

Si configuraste `DRIVE_CLIENT_ID` y `DRIVE_CLIENT_SECRET`, genera el token con esos mismos valores:
`rclone authorize "drive" "CLIENT_ID" "CLIENT_SECRET"`.

**Opción B: túnel SSH, sin instalar nada en el Mac**

```bash
ssh -L 53682:localhost:53682 usuario@servidor
rclone authorize "drive" --auth-no-open-browser
# Abre en el navegador del Mac la URL que imprime (http://127.0.0.1:53682/auth?...)
```

**Otras formas de autenticarse**

- `DRIVE_AUTH="service_account"`: usa un JSON de cuenta de servicio. Solo sirve con **Unidades compartidas** (`DRIVE_TEAM_DRIVE`), porque las cuentas de servicio no tienen espacio propio.
- `DRIVE_AUTH="rclone_remote"`: usa un remote que ya creaste con `rclone config`.

rclone renueva el token solo. La copia renovada se guarda en `.rclone.conf`, dentro del repo y con permisos 600. Ese archivo se regenera únicamente cuando cambias `config.env`.

### Probar

```bash
./backup.sh --test            # escribe y borra un archivo de prueba en Drive
./db.sh                       # prueba solo las bases  → ./test-output/db
./files.sh                    # prueba solo archivos   → ./test-output/files
./backup.sh --dry-run         # flujo completo, simula la subida y los borrados
./backup.sh                   # backup real
```

### Programar

```bash
sudo ./setup.sh --cron "0 2 * * *"   # todos los días a las 2:00 a.m. (crontab de root)
sudo ./setup.sh --remove-cron        # quitarlo
```

Los logs quedan en `LOG_DIR`, uno por ejecución, y además se suben junto a cada backup como `backup.log`.

## Escribir db.sh y files.sh

Son scripts de bash **libres**. Solo hay una regla:

> **Todo lo que dejes dentro de `$OUT` se sube a Drive.** Puede ser un archivo comprimido, varios o una carpeta tal cual.

Ejemplos:

```bash
# Servidor A: mysqldump directo
MYSQL_PWD="$DB_PASSWORD" mysqldump -u root --all-databases | gzip > "$OUT/mysql_$STAMP.sql.gz"

# Servidor B: mysqldump dentro de Docker
docker exec -e MYSQL_PWD="$DB_PASSWORD" mysql_prod mysqldump -u root --all-databases | gzip > "$OUT/mysql_$STAMP.sql.gz"

# Servidor C: copiar la carpeta _data de Postgres (deteniendo el contenedor)
docker stop pg; trap 'docker start pg' EXIT
cp -a /var/lib/docker/volumes/pg_data/_data "$OUT/postgres_data"
```

```bash
# files.sh: subir la carpeta tal cual
cp -a /var/www/html "$OUT/html"

# files.sh: zip
(cd /var/www && zip -qr "$OUT/sitio_$STAMP.zip" html)

# files.sh: tar
tar -czf "$OUT/uploads_$STAMP.tar.gz" -C /var/www/html/wp-content uploads
```

Detalles:

- Las variables de `config.env` están disponibles. Pon ahí las contraseñas, los nombres de contenedores o las rutas, y úsalas como `$VARIABLE`. Así las credenciales quedan en un solo archivo protegido.
- `$STAMP` trae la fecha del backup para usarla en los nombres de archivo.
- Si **cualquier comando falla**, el script se detiene y `backup.sh` no sube nada.
- Las plantillas traen un `exit 1` al principio para que no se suba un backup vacío por accidente. Bórralo cuando pongas tus comandos.
- Si un servidor no tiene base de datos (o no tiene archivos), pon `ENABLE_DB=false` (o `ENABLE_FILES=false`) en `config.env`.
- Para probar cada script por separado: `./db.sh` y `./files.sh` dejan el resultado en `./test-output/`.

## Restaurar

```bash
./restore.sh list                          # backups de este servidor en Drive
./restore.sh list otro-servidor            # backups de otro servidor
./restore.sh latest                        # descarga el último en ./restore/<fecha> y verifica checksums
./restore.sh get 2026-09-24_020000 /tmp/r  # descarga uno en concreto
```

Se descarga exactamente lo que dejaron `db.sh` y `files.sh`. Restaurarlo depende de cómo lo generaste (`mysql < archivo.sql`, `unzip`, `tar -x`, copiar `_data` de vuelta con el contenedor detenido, etc.).

## Notificaciones

- **Webhook** (`NOTIFY_WEBHOOK_URL`): envía un POST JSON `{"text": "...", "content": "..."}`. Funciona con Google Chat, Slack y Discord.
- **Correo** (`NOTIFY_EMAIL`): requiere el comando `mail` configurado en el servidor.
- **Cuándo** (`NOTIFY_ON`): `always`, `error` o `never`.

## Seguridad

- `config.env` guarda el token de Drive y las contraseñas de la base de datos. Mantenlo en `chmod 600` y **nunca lo subas a git** (ya está en `.gitignore`).
- El token da acceso a todo el Drive de la cuenta. Lo mejor es usar una cuenta dedicada a backups o una Unidad compartida.
- Si necesitas cifrar los backups en Drive, crea un remote `crypt` con `rclone config` y usa `DRIVE_AUTH="rclone_remote"` apuntando a él.
