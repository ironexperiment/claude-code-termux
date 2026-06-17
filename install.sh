#!/usr/bin/env bash
#
# install.sh — Claude Code en Termux SIN proot-distro
#
# Contexto (verificado contra el paquete real, v2.x):
#   Claude Code 2.x ya NO es un bundle JS: es UN binario nativo compilado
#   (~235 MB) por plataforma. El paquete npm raíz solo trae un launcher que
#   localiza y ejecuta ese binario.
#
#   El instalador oficial YA contempla Android (process.platform === 'android'
#   -> 'linux-<arch>-android'), pero ese binario AÚN NO se publica en npm (404).
#
# Estrategia de este script:
#   1) Si el binario oficial de Android YA existe en npm -> instalación nativa
#      pura (npm install -g). Cero hacks. (Re-ejecuta este script para migrar.)
#   2) Si no existe (caso actual) -> ruta glibc-runner (grun): descarga el
#      binario linux-<arch> (glibc) y lo ejecuta sobre el kernel real con grun.
#      Sin proot-distro, sin rootfs emulado.
#
# Uso:  bash install.sh
# Idempotente.

set -euo pipefail

# --------------------------------------------------------------------------- colores
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'; C_RST=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_RST=""
fi
log()  { printf '%s==>%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[ok]%s %s\n'  "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n'   "$C_WARN" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n'   "$C_ERR"  "$C_RST" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- 0. Termux + arch
log "Comprobando entorno Termux..."
if [ -z "${PREFIX:-}" ] || [ "${PREFIX#*com.termux}" = "$PREFIX" ]; then
  die "Esto no parece Termux (\$PREFIX no apunta a com.termux). Ejecútalo dentro de Termux."
fi
command -v pkg >/dev/null 2>&1 || die "No se encontró 'pkg'. ¿Seguro que es Termux?"

case "$(uname -m)" in
  aarch64|arm64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x64" ;;
  *) die "Arquitectura $(uname -m) no soportada por Claude Code (solo arm64 y x64)." ;;
esac
ok "Termux detectado · arch=$ARCH · PREFIX=$PREFIX"

PKG_ROOT="@anthropic-ai/claude-code"
ANDROID_PKG="${PKG_ROOT}-linux-${ARCH}-android"
GLIBC_PKG="${PKG_ROOT}-linux-${ARCH}"
OPT_DIR="$PREFIX/opt/claude-code"
LAUNCHER="$PREFIX/bin/claude"

# --------------------------------------------------------------------------- 1. ¿Existe ya el binario oficial de Android?
log "Comprobando si Anthropic ya publicó el binario nativo de Android ($ANDROID_PKG)..."
NEED_NODE_FOR_CHECK=0
command -v npm >/dev/null 2>&1 || NEED_NODE_FOR_CHECK=1
if [ "$NEED_NODE_FOR_CHECK" -eq 1 ]; then
  log "Instalando nodejs-lts (necesario para npm)..."
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y nodejs-lts
fi

if npm view "$ANDROID_PKG" version >/dev/null 2>&1; then
  ok "¡Binario oficial de Android disponible! Instalación NATIVA pura."
  pkg install -y nodejs-lts git ripgrep termux-exec
  npm install -g "$PKG_ROOT"
  # Si existía un lanzador grun nuestro, lo quitamos: ahora 'claude' nativo manda.
  if [ -f "$LAUNCHER" ] && grep -q "grun" "$LAUNCHER" 2>/dev/null; then
    rm -f "$LAUNCHER"
    warn "Eliminado el lanzador grun antiguo; ahora usas el binario nativo de Android."
  fi
  echo
  ok "Instalación nativa completada. Ejecuta:  claude"
  exit 0
fi

warn "El binario oficial de Android aún no está publicado (404). Uso la ruta glibc-runner."

# --------------------------------------------------------------------------- 2. Ruta glibc-runner (grun)
log "Instalando dependencias: glibc-repo, glibc-runner, ripgrep, git, nodejs-lts ..."
pkg update -y >/dev/null 2>&1 || warn "pkg update dio avisos (continuo)."
# glibc-repo añade el repositorio que contiene glibc-runner (provee 'grun').
pkg install -y glibc-repo || warn "No pude instalar glibc-repo (¿ya estaba?). Continúo."
pkg update -y >/dev/null 2>&1 || warn "pkg update (post glibc-repo) dio avisos (continuo)."
# glibc-runner -> grun ; nodejs-lts -> npm para descargar el binario.
# El resto son utilidades Unix que Claude Code lanza como subprocesos y que
# Termux NO trae de fábrica (find, xargs, grep, sed, awk, diff, which, etc.).
pkg install -y glibc-runner nodejs-lts git ripgrep \
  findutils grep gawk sed coreutils diffutils which tar gzip less

command -v grun >/dev/null 2>&1 || die "glibc-runner no dejó disponible 'grun'. Revisa 'pkg install glibc-runner'."
command -v npm  >/dev/null 2>&1 || die "npm no quedó disponible."

# Descargar el binario glibc linux-<arch>. Usamos 'npm pack' para esquivar el
# rechazo EBADPLATFORM (el sub-paquete declara os=linux/cpu=arch y Node reporta
# 'android'); pack solo descarga el tarball, sin validar plataforma.
log "Descargando el binario nativo glibc ($GLIBC_PKG) — son ~100-235 MB, paciencia..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(
  cd "$TMP"
  npm pack "${GLIBC_PKG}@latest" >/dev/null
  TGZ="$(ls -1 *.tgz | head -n1)"
  [ -n "$TGZ" ] || die "npm pack no produjo tarball."
  tar -xzf "$TGZ"
  [ -f package/claude ] || die "No se encontró el binario 'claude' dentro del paquete."
  mkdir -p "$OPT_DIR"
  install -m 0755 package/claude "$OPT_DIR/claude"
)
ok "Binario instalado en $OPT_DIR/claude"

# Lanzador: ejecuta el binario glibc a través de grun (kernel real, sin proot).
# Borramos primero por si $LAUNCHER es un symlink preexistente (p.ej. de un
# 'npm install -g @anthropic-ai/claude-code' previo, que apunta a node_modules).
# Sin esto, 'cat >' escribiría A TRAVÉS del symlink dentro de node_modules y npm
# podría sobrescribir el lanzador en una futura actualización.
log "Creando lanzador en $LAUNCHER ..."
rm -f "$LAUNCHER"
cat > "$LAUNCHER" <<LAUNCHER_EOF
#!$PREFIX/bin/bash
# Lanzador de Claude Code (ruta glibc-runner). Generado por install.sh.
# Ejecuta el binario glibc nativo sobre Termux mediante grun, sin proot-distro.
#
# CLAUDE_CODE_EXECPATH se fuerza a /dev/null (no ejecutable) ANTES de exec'ar grun.
# Motivo: grun arranca el binario glibc como \`ld.so claude ...\`, asi que el
# "self-exe" real del proceso es el enlazador dinamico (ld-linux-*.so), no el
# binario claude. Si se deja que Claude Code fije CLAUDE_CODE_EXECPATH solo, sus
# funciones de shell find()/grep() (que re-ejecutan "\$CLAUDE_CODE_EXECPATH" como
# bfs/ugrep) acaban invocando el enlazador con los flags de la herramienta y
# rompen con "X: error while loading shared libraries". Con la variable no
# ejecutable, esas funciones caen a su fallback (command find / command grep,
# herramientas nativas de Termux). Ver seccion de troubleshooting del README.
export CLAUDE_CODE_EXECPATH=/dev/null
exec grun "$OPT_DIR/claude" "\$@"
LAUNCHER_EOF
chmod +x "$LAUNCHER"
ok "Lanzador creado."

# --------------------------------------------------------------------------- final
echo
ok "Instalación completada (ruta glibc-runner)."
echo
log "Prueba:"
printf '      claude --version\n'
printf '      claude\n\n'
warn "Si 'grun' falla al cargar el binario, revisa la sección 'Solución de problemas'"
warn "del README (suele resolverse con patchelf / el intérprete de glibc)."
echo
log "Cuando Anthropic publique el binario oficial de Android, vuelve a ejecutar:"
printf '      bash install.sh\n'
printf '   y migrará solo a la instalación nativa pura.\n'
