# Claude Code en Termux (sin proot-distro)

Instala y ejecuta **Claude Code** en Termux **sin `proot-distro`** (sin una distro
Linux emulada encima). Se apoya en la capa **`glibc-runner` (`grun`)** mientras
Anthropic no publique el binario oficial de Android, y migra solo a instalación
nativa pura cuando lo haga.

---

## Cómo funciona Claude Code 2.x (importante)

Claude Code **2.x ya no es un bundle de JavaScript**: es **un binario nativo
compilado (~235 MB), uno por plataforma**. El paquete npm raíz solo trae un
launcher (`cli-wrapper.cjs` / `install.cjs`) que localiza y ejecuta ese binario.

- El instalador oficial **ya contempla Android** (`process.platform === 'android'`
  → `linux-<arch>-android`), pero ese binario **aún no se publica en npm** (da 404).
- Los binarios que **sí** se publican para ARM/x64 están compilados contra
  **glibc** (o musl). Termux usa **bionic libc**, así que no arrancan "a pelo".

### ¿Qué es `glibc-runner` / `grun`?

Un binario "dynamically linked" necesita una **libc** (biblioteca de funciones
básicas) al arrancar. Hay varias y **no son intercambiables**: el escritorio Linux
usa **glibc**, Android/Termux usa **bionic**. El binario de Claude Code pide glibc;
Termux no la tiene → no arranca.

`glibc-runner` instala una copia de **glibc** dentro de Termux, y el comando
**`grun`** arranca el binario **prestándole esa glibc**, ejecutándolo **directo
sobre el kernel real** del teléfono.

| | `proot-distro` | `glibc-runner` (`grun`) |
|---|---|---|
| Instala | Una distro Linux entera (rootfs) | Solo las librerías glibc |
| Ejecuta | Linux emulado interceptando syscalls (`ptrace`) | Binario directo sobre el kernel real |
| Coste | Pesado y más lento | Ligero y más rápido |

Por eso esta vía cumple el objetivo de **"sin proot"** y es más cercana a nativo.

---

## Requisitos

- **Termux** de [F-Droid](https://f-droid.org/packages/com.termux/) o GitHub
  (el de Google Play está obsoleto).
- Arquitectura **arm64** (aarch64) o **x64**. La mayoría de móviles son arm64.
- Conexión a internet (la descarga del binario es de **~100-235 MB**).
- Espacio libre: cuenta con **~500 MB** entre descarga y binario instalado.

---

## Instalación

```bash
# Copia este repo en Termux, entra en la carpeta y ejecuta:
bash install.sh

# Cuando termine, prueba:
claude --version
claude
```

El script es **idempotente**: puedes ejecutarlo las veces que quieras.

---

## ¿Qué hace `install.sh`?

1. Comprueba que estás en **Termux** y detecta tu **arquitectura**.
2. **Plan A** — pregunta a npm si ya existe el binario oficial de Android
   (`@anthropic-ai/claude-code-linux-<arch>-android`). Si existe → instalación
   **nativa pura** (`npm install -g`) y termina.
3. **Plan B** (caso actual) — instala `glibc-repo`, `glibc-runner`, `nodejs-lts`,
   `git`, `ripgrep` y utilidades Unix (`findutils`, `grep`, `sed`, `gawk`…);
   descarga el binario glibc con `npm pack` (esquiva el
   rechazo de plataforma), lo coloca en `$PREFIX/opt/claude-code/claude` y crea
   un lanzador `claude` que lo ejecuta vía `grun`.

---

## Migrar al binario oficial de Android (cuando salga)

El camino ya está en el código de Claude Code; falta que Anthropic publique el
binario. Cuando ocurra, simplemente:

```bash
bash install.sh
```

El **Plan A** lo detectará, instalará lo nativo y **eliminará el lanzador `grun`**
automáticamente.

---

## Actualizar Claude Code (ruta glibc-runner)

Vuelve a ejecutar `bash install.sh`: descarga la última versión del binario y
reemplaza el de `$PREFIX/opt/claude-code/`.

---

## Solución de problemas

### `grun` no arranca el binario / error de "interpreter" o librería
Es lo más probable que falle. Suele resolverse fijando el *interpreter* glibc del
binario con `patchelf`:

```bash
pkg install -y patchelf
# Localiza el loader de glibc instalado por glibc-runner:
ls $PREFIX/glibc/lib/ld-linux-*.so*

# Apunta el binario a ese loader (ajusta el nombre del .so al que aparezca arriba):
patchelf --set-interpreter "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
  --set-rpath "$PREFIX/glibc/lib" \
  "$PREFIX/opt/claude-code/claude"

# Prueba directo:
claude --version
```

> Pega el **mensaje de error exacto** si persiste — el ajuste depende de qué
> librería o ruta reclame el binario.

### `command not found: claude`
```bash
echo "$PATH" | tr ':' '\n' | grep com.termux   # $PREFIX/bin debe estar en PATH
ls -l "$PREFIX/bin/claude"                      # el lanzador debe existir
```

### `grun: command not found`
```bash
pkg install -y glibc-repo
pkg update -y
pkg install -y glibc-runner
```

### "el comando X no está disponible en esta shell"
Termux trae un set mínimo de utilidades. Claude Code lanza herramientas Unix
estándar que pueden no estar instaladas. Instala la que falte, p. ej.:
```bash
pkg install -y findutils   # find, xargs
pkg install -y grep gawk sed coreutils diffutils which tar gzip less
```
El `install.sh` ya instala las más comunes; si aparece otra, instálala con `pkg`.

### Errores de búsqueda / `ripgrep`
El binario suele traer su propio `rg`, pero por si acaso:
```bash
pkg install -y ripgrep
command -v rg
```

---

## Desinstalar

```bash
rm -f "$PREFIX/bin/claude"
rm -rf "$PREFIX/opt/claude-code"
# Opcional, si no usas glibc para otra cosa:
# pkg uninstall glibc-runner
```

---

## Estado / probado en

> Rellena esto cuando lo pruebes — ayuda a depurar.

| Dispositivo | Arquitectura | Android | Termux | ¿`grun` arrancó? | Notas |
|---|---|---|---|---|---|
| _ej. Pixel 6_ | arm64 | 14 | 0.118 | ⬜ | |
