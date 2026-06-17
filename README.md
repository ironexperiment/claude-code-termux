# Claude Code en Termux — sin proot-distro

Instala y ejecuta **Claude Code** en **Termux** (Android) **sin `proot-distro`**, es
decir, sin montar una distribución de Linux emulada encima. El instalador se apoya
en la capa **`glibc-runner` (`grun`)** mientras Anthropic no publique el binario
oficial de Android, y **migra automáticamente** a la instalación nativa pura en
cuanto ese binario esté disponible.

> ⚠️ **Proyecto no oficial / de la comunidad.** No está afiliado a Anthropic. Este
> instalador descarga el **binario oficial** de Claude Code desde npm y lo ejecuta;
> no modifica ni redistribuye el producto. Úsalo respetando los términos de servicio
> de Claude Code.

---

## Instalación rápida

En Termux:

```bash
pkg install -y git
git clone https://github.com/ironexperiment/Claude-code-for-termux.git
cd Claude-code-for-termux
bash install.sh
```

Cuando termine:

```bash
claude --version
claude
```

El script es **idempotente**: puedes ejecutarlo las veces que quieras sin romper nada.

---

## Requisitos

- **Termux** instalado desde [F-Droid](https://f-droid.org/packages/com.termux/) o
  GitHub (la versión de Google Play está obsoleta).
- Arquitectura **arm64** (aarch64) o **x64**. La mayoría de móviles son arm64.
- Conexión a internet — el binario de Claude Code pesa **~100–235 MB**.
- **~500 MB** de espacio libre (entre la descarga y el binario instalado).

---

## ¿Por qué hace falta esto?

Claude Code **2.x ya no es un paquete de JavaScript**: es **un binario nativo
compilado (~235 MB), uno por plataforma**. El paquete de npm solo trae un pequeño
launcher que localiza y ejecuta ese binario.

- El instalador oficial **ya contempla Android** (`process.platform === 'android'`
  → `linux-<arch>-android`), pero ese binario **aún no se publica** (npm devuelve 404).
- Los binarios que **sí** se publican para ARM/x64 están compilados contra **glibc**.
  Termux usa **bionic libc**, así que no arrancan directamente.

### ¿Qué es `glibc-runner` / `grun`?

Un binario "dynamically linked" necesita una **libc** (la biblioteca con las
funciones básicas del sistema) al arrancar. Existen varias y **no son
intercambiables**: el Linux de escritorio usa **glibc**, mientras que Android/Termux
usa **bionic**. El binario de Claude Code pide glibc; Termux no la tiene → no arranca.

`glibc-runner` instala una copia de **glibc** dentro de Termux, y el comando **`grun`**
arranca el binario **prestándole esa glibc**, ejecutándolo **directo sobre el kernel
real** del teléfono.

| | `proot-distro` | `glibc-runner` (`grun`) |
|---|---|---|
| Instala | Una distro Linux entera (rootfs) | Solo las librerías glibc |
| Ejecuta | Linux emulado interceptando syscalls (`ptrace`) | Binario directo sobre el kernel real |
| Coste | Pesado y más lento | Ligero y más rápido |

Por eso esta vía cumple el objetivo de **"sin proot"** y es más cercana a nativo.

---

## ¿Qué hace `install.sh`?

1. Comprueba que estás en **Termux** y detecta la **arquitectura**.
2. **Plan A** — consulta npm por el binario oficial de Android
   (`@anthropic-ai/claude-code-linux-<arch>-android`). Si existe → instalación
   **nativa pura** (`npm install -g`) y termina.
3. **Plan B** (situación actual) — instala `glibc-repo`, `glibc-runner`, `nodejs-lts`,
   `git`, `ripgrep` y utilidades Unix (`findutils`, `grep`, `sed`, `gawk`…); descarga
   el binario glibc con `npm pack` (evita el rechazo por plataforma), lo coloca en
   `$PREFIX/opt/claude-code/claude` y crea un lanzador `claude` que lo ejecuta con `grun`.

---

## Actualizar

Vuelve a ejecutar `bash install.sh`: descarga la última versión del binario y
reemplaza el instalado.

## Migrar al binario oficial de Android (cuando salga)

El soporte ya está en el código de Claude Code; solo falta que Anthropic publique el
binario. Cuando ocurra, basta con volver a ejecutar `bash install.sh`: el **Plan A**
lo detectará, instalará la versión nativa y **eliminará el lanzador `grun`**.

---

## Solución de problemas

### `grun` no arranca el binario / error de "interpreter" o de librería
Es el punto más propenso a fallar. Suele resolverse fijando el *interpreter* de glibc
del binario con `patchelf`:

```bash
pkg install -y patchelf
# Localiza el loader de glibc que instaló glibc-runner:
ls $PREFIX/glibc/lib/ld-linux-*.so*

# Apunta el binario a ese loader (ajusta el nombre del .so al que aparezca arriba):
patchelf --set-interpreter "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
  --set-rpath "$PREFIX/glibc/lib" \
  "$PREFIX/opt/claude-code/claude"

claude --version
```

> Si persiste, abre un *issue* con el **mensaje de error exacto**: el ajuste depende
> de qué librería o ruta reclame el binario.

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
Termux trae un set mínimo de utilidades. Claude Code lanza herramientas Unix estándar
que pueden faltar. Instala la que falte, por ejemplo:
```bash
pkg install -y findutils   # find, xargs
pkg install -y grep gawk sed coreutils diffutils which tar gzip less
```
`install.sh` ya instala las más comunes; si aparece otra, instálala con `pkg`.

### `find`/`grep` fallan con "error while loading shared libraries"
Bug conocido de la ruta `grun`. Claude Code envuelve `find`/`grep` como funciones
de shell que relanzan su propio binario (`$CLAUDE_CODE_EXECPATH`) como herramientas
internas (`bfs`/`ugrep`). Pero como `grun` arranca el binario vía el enlazador de
glibc (`ld.so claude ...`), `$CLAUDE_CODE_EXECPATH` apunta al **enlazador**, no al
binario, y al ejecutarlo con los flags de la herramienta revienta así:
```
-S: error while loading shared libraries: -S: cannot open shared object file...
```
**El `install.sh` ya lo mitiga**: el lanzador exporta `CLAUDE_CODE_EXECPATH=/dev/null`,
lo que hace que esas funciones caigan a su fallback (`command find` / `command grep`,
las herramientas nativas de Termux). Si ya tenías una instalación previa, vuelve a
ejecutar `bash install.sh` para regenerar el lanzador con el arreglo.

Comprobación (tras reiniciar `claude`):
```bash
echo "$CLAUDE_CODE_EXECPATH"   # debe imprimir /dev/null
```
> Contrapartida: se pierde el filtrado automático de `.gitignore`/ocultos del modo
> interno de búsqueda, pero `find`/`grep` vuelven a funcionar.

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

## Compatibilidad

| Arquitectura | Android | Termux | Resultado |
|---|---|---|---|
| arm64 (aarch64) | 14 | 0.118.3 | ✅ Funciona (Claude Code 2.1.179 vía `grun`) |

> Nota sobre la búsqueda: `find`/`grep` funcionan vía el fallback a las herramientas
> nativas de Termux (`command find`/`command grep`). Las versiones de búsqueda
> embebidas (`bfs`/`ugrep`) no pueden ejecutarse bajo `grun`, así que la primera
> llamada puede fallar y reintentar — funcional, pero no instantáneo. Se resuelve
> por completo cuando llegue el binario oficial de Android.

¿Lo probaste en tu dispositivo? Abre un *issue* o un *pull request* añadiendo tu fila
(arquitectura, versión de Android y Termux, y si funcionó) — ayuda a los demás.

---

## Contribuir

Las contribuciones son bienvenidas: reportes de errores, dispositivos probados,
o mejoras al instalador. Abre un *issue* o un *pull request*.

## Licencia

[MIT](LICENSE).
