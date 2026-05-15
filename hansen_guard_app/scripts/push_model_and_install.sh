#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_USER="${SUDO_USER:-$(id -un)}"
CALLER_HOME="$(getent passwd "$CALLER_USER" | cut -d: -f6)"

APP_ID="com.example.hansen_guard"
ADB="${ADB:-$CALLER_HOME/Android/Sdk/platform-tools/adb}"
MODEL_PATH="${1:-$CALLER_HOME/Downloads/gemma4-litert/gemma-4-E2B-it.litertlm}"
APK_PATH="${2:-$PROJECT_DIR/build/app/outputs/flutter-apk/app-debug.apk}"
AUTO_LAUNCH="${AUTO_LAUNCH:-0}"
TARGET_DIR="/sdcard/Android/data/${APP_ID}/files"
TARGET_MODEL_PATH="${TARGET_DIR}/gemma-4-E2B-it.litertlm"

# Mirrors the runtime contract used by MainActivity.getRecommendedModelPath():
# install the debug APK, create the app-scoped external-files directory, and
# push the Gemma 4 LiteRT-LM artifact to the exact filename the app auto-loads.

if [[ ! -x "$ADB" ]]; then
  echo "ADB nao encontrado em: $ADB" >&2
  exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Modelo nao encontrado em: $MODEL_PATH" >&2
  exit 1
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "APK nao encontrado em: $APK_PATH" >&2
  echo "Execute: flutter build apk --debug" >&2
  exit 1
fi

echo "Verificando dispositivos ADB"
"$ADB" devices

DEVICE_ID="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
if [[ -z "$DEVICE_ID" ]]; then
  echo "Nenhum dispositivo ADB pronto foi encontrado." >&2
  exit 1
fi

echo
echo "Gerando APK de debug atualizado"
(
  cd "$PROJECT_DIR"
  flutter build apk --debug
)

echo
echo "Instalando APK de debug"
set +e
INSTALL_OUTPUT="$({ "$ADB" -s "$DEVICE_ID" install -r "$APK_PATH"; } 2>&1)"
INSTALL_STATUS=$?
set -e

if [[ $INSTALL_STATUS -ne 0 ]]; then
  echo "$INSTALL_OUTPUT" >&2
  if grep -q "INSTALL_FAILED_USER_RESTRICTED" <<<"$INSTALL_OUTPUT"; then
    cat >&2 <<'EOF'

Instalacao bloqueada pelo telefone.
No POCO, deixe a tela desbloqueada e confirme qualquer prompt de instalacao USB.
Se o prompt nao aparecer, ative nas Opcoes do desenvolvedor:
- Instalar via USB
- Depuracao USB (Configuracoes de seguranca), se existir

Depois rode o mesmo script novamente.
EOF
  fi
  exit $INSTALL_STATUS
fi

echo "$INSTALL_OUTPUT"

echo
echo "Criando pasta do app no telefone"
"$ADB" -s "$DEVICE_ID" shell "mkdir -p '$TARGET_DIR'"

echo
echo "Enviando modelo para o telefone"
"$ADB" -s "$DEVICE_ID" push "$MODEL_PATH" "$TARGET_MODEL_PATH"

echo
echo "Encerrando qualquer instancia anterior do app"
"$ADB" -s "$DEVICE_ID" shell am force-stop "$APP_ID"

if [[ "$AUTO_LAUNCH" == "1" ]]; then
  echo
  echo "Abrindo o app no telefone"
  "$ADB" -s "$DEVICE_ID" shell am start -n "${APP_ID}/.MainActivity"
else
  echo
  echo "App instalado e modelo enviado. Desbloqueie o telefone e abra o app manualmente pelo icone para iniciar uma instancia limpa."
fi

echo
echo "Modelo enviado para: $TARGET_MODEL_PATH"