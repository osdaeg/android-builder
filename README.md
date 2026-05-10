# Android CI Pipeline — Homelab

Pipeline de build automatizado para apps Android usando Gitea + Gitea Runner.
Un solo comando configura un proyecto nuevo de punta a punta.

## Arquitectura

```
git push
    ↓
Gitea (puerto 3000)
    ↓
Gitea Runner (self-hosted, acceso a Docker socket)
    ↓
Container android-builder (imagen local, SDK/Gradle cacheados en volúmenes)
    ↓
chmod +x gradlew → local.properties → dependencies → assembleDebug → test
    ↓
APK artifact (14 días) + Notificación Gotify
    ↓
git push github main  (mirror opcional)
```

## Archivos

```
android-ci/
├── docker-compose.yml          # Gitea + Runner (sin emulador)
├── Dockerfile                  # Imagen del builder (SDK + Gradle + Node.js)
├── build.yml.template          # Template de workflow CI reutilizable
├── setup-android-project.sh   # Script de setup completo por proyecto
├── .env.example                # Template de credenciales
├── .gitignore                  # Excluye .env del control de versiones
└── README.md
```

---

## Setup inicial (una sola vez)

### 1. Credenciales

```bash
cp .env.example .env
# Editar .env con los tokens reales
```

Contenido del `.env`:
```bash
GITEA_URL=http://192.168.88.100:3000
GITEA_USER=daniel
GITEA_TOKEN=...    # Gitea → Settings → Applications → Generate Token
                   # Permisos necesarios: repository (R/W), user (R)
GOTIFY_TOKEN=...   # Token de la app en Gotify
GITHUB_USER=...    # Usuario de GitHub para mirror (opcional)
```

### 2. Construir la imagen del builder

```bash
docker compose --profile build-only build android-builder
```

La imagen se llama `android-builder:latest`. Incluye JDK 17, Android SDK,
build-tools, Node.js (requerido por las GitHub Actions del runner) y Gradle.

> **Nota:** el builder tiene `profiles: [build-only]` en el compose para que
> `docker compose up` no intente arrancarlo como servicio.

### 3. Levantar Gitea y el Runner

```bash
docker compose up -d gitea gitea-runner
```

### 4. Registrar el Runner

Obtener un token en Gitea: *Administración del sitio → Acciones → Nodos → Crear nuevo nodo*

```bash
docker exec -it gitea-runner act_runner register \
  --instance http://gitea:3000 \
  --token <TOKEN> \
  --name homelab-runner \
  --labels self-hosted \
  --no-interactive

# Persistir el registro en el volumen
docker exec gitea-runner cp /.runner /data/.runner

docker compose restart gitea-runner
```

Verificar que el nodo figura como activo en Gitea.

### 5. Configurar la red del Runner

El runner lanza containers de build dinámicamente. Para que puedan resolver
el hostname `gitea`, hay que generar el config y apuntar a la red correcta:

```bash
docker exec -it gitea-runner act_runner generate-config > /tmp/config.yaml
```

Editar `/tmp/config.yaml`, sección `container`:
```yaml
container:
  network: "GeneralNetwork"
  force_pull: false
```

```bash
docker cp /tmp/config.yaml gitea-runner:/data/config.yaml
docker compose restart gitea-runner
```

Asegurarse de que el compose tenga:
```yaml
gitea-runner:
  environment:
    - CONFIG_FILE=/data/config.yaml
    - HOME=/data
```

### 6. Crear volúmenes de caché

```bash
docker volume create gradle-cache
docker volume create sdk-cache
```

Estos volúmenes son compartidos por todos los proyectos — las dependencias
de Gradle y el SDK se descargan una sola vez y se reutilizan en cada build.

---

## Agregar una nueva app al pipeline

```bash
./setup-android-project.sh <directorio> "<NombreApp>" [--private]
```

El script hace automáticamente:
1. Genera `gradlew` (Gradle 8.7) si no existe, y asegura permisos de ejecución
2. Crea `local.properties` apuntando al SDK del container
3. Actualiza `.gitignore` (excluye builds, elimina `.gitea/` si estaba ignorado)
4. Copia y configura el workflow en `.gitea/workflows/build.yml`
5. Crea el repo en Gitea via API
6. Habilita Actions en el repo
7. Configura el secret `GOTIFY_TOKEN`
8. Apunta el remote `origin` a Gitea
9. Configura el remote `github` (si `GITHUB_USER` está en `.env`)
10. Hace el primer commit y push (dispara el CI automáticamente)

### Ejemplos

```bash
./setup-android-project.sh ~/Proyectos/MoveDroid        "MoveDroid"
./setup-android-project.sh ~/Proyectos/pastebin-android "PasteDrop"
./setup-android-project.sh ~/Proyectos/silo-android     "Silo"
```

### Push a ambos remotos

```bash
git push origin main   # Gitea → dispara CI
git push github main   # GitHub → mirror/backup
```

---

## Dependencias de las apps

**No van en el Dockerfile.** Jetpack Compose, Room, Hilt, Retrofit, etc.
se declaran en `build.gradle.kts` de cada proyecto y Gradle las descarga
automáticamente desde Maven Central / Google Maven al primer build.
Quedan cacheadas en el volumen `gradle-cache` para todos los builds siguientes.

---

## Actualizar componentes

| Componente | Cómo actualizar |
|---|---|
| Gradle (wrapper) | Cambiar `GRADLE_VERSION` en el Dockerfile → rebuild imagen |
| Android SDK / build-tools | Modificar bloque `sdkmanager` en el Dockerfile → rebuild |
| Dependencias de una app | Editar `build.gradle.kts` del proyecto — sin tocar la imagen |

```bash
docker compose --profile build-only build android-builder
```

---

## Notas

- **Sin emulador:** el `emulator.Dockerfile` fue excluido. Requiere 8-10 GB
  de imagen y ~3 GB RAM en runtime — inviable para algunos hardware.
  El pipeline compila y corre unit tests; los tests instrumentados quedan fuera.
- **Node.js en el builder:** requerido por las actions JS del runner
  (`actions/checkout`, `actions/upload-artifact`). Sin él el checkout falla
  con `exec: "node": executable file not found`.
- **`--no-daemon`:** todos los tasks de Gradle corren con esta flag para evitar
  procesos zombie en containers efímeros.
- **APK artifacts:** se guardan 14 días en Gitea y se descargan desde
  *Actions → build → Artifacts*.
- **El `.runner` va en `/data`:** por defecto el runner lo guarda en `/`,
  hay que copiarlo al volumen manualmente después del registro para que
  persista entre reinicios.
