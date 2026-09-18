#!/bin/bash

# Default directories
SERVER="${SERVER_DIR:-/root/valheim-server}"
PERSISTENT="${PERSISTENT_DIR:-/root/.config/unity3d/IronGate/Valheim}"
SETTINGS="${PERSISTENT}/settings"

# Quick function to generate a timestamp
timestamp () {
  date +"%Y-%m-%d %H:%M:%S,%3N"
}

shutdown () {
    echo ""
    echo "$(timestamp) INFO: Received SIGTERM/SIGINT, shutting down gracefully"
    if [ -n "$valheim_pid" ]; then
        kill -2 $valheim_pid 2>/dev/null
    fi
}

# Set our traps for graceful shutdown
trap 'shutdown' TERM INT

echo "Load extra Box64 and Fex-emu settings from emulators.rc"
if [ -f /load_emulators_env.sh ]; then
    source /load_emulators_env.sh
fi
echo " "

if [ -x /print_app_versions.sh ]; then
    /print_app_versions.sh
fi

# Run SteamCMD update only if AUTO_UPDATE is true (default true)
AUTO_UPDATE="${AUTO_UPDATE:-true}"
if [ "$AUTO_UPDATE" = "true" ] || [ "$AUTO_UPDATE" = "1" ]; then
    echo "Updating Valheim Dedicated Server via SteamCMD (Windows x86_64 build)..."
    export SteamAppId=892970
    steamcmd.sh +@sSteamCmdForcePlatformType windows +force_install_dir ${SERVER} +login anonymous +app_update 896660 validate +quit
else
    echo "AUTO_UPDATE is disabled, skipping SteamCMD update."
fi

echo "Checking if BepInEx files need to be initialized"
mkdir -p "${SERVER}"
if [ ! -d "${SERVER}/BepInEx" ]; then
    echo "Copying BepInEx base files into ${SERVER}..."
    cp -r defaults/server/. "${SERVER}/"
else
    echo "The folder ${SERVER}/BepInEx already exists."
    # Ensure critical Doorstop loader files exist
    if [ ! -f "${SERVER}/winhttp.dll" ] && [ -f defaults/server/winhttp.dll ]; then
        cp defaults/server/winhttp.dll "${SERVER}/"
    fi
    if [ ! -f "${SERVER}/doorstop_config.ini" ] && [ -f defaults/server/doorstop_config.ini ]; then
        cp defaults/server/doorstop_config.ini "${SERVER}/"
    fi
fi
echo " "

echo "Wine configuration"
winetricks sound=disabled 2>/dev/null || true

echo "Trying to remove /tmp/.X0-lock"
rm -f /tmp/.X0-lock
echo " "

echo "Starting Xvfb"
Xvfb :0 -screen 0 1024x768x16 &
sleep 3

echo "Starting server PRESS CTRL-C to exit"
echo " "
cd ${SERVER}

# Ensure libpulse-mainloop-glib.so.0 is installed if needed
if [[ ! -f ${SERVER}/linux64/libpulse-mainloop-glib.so.0 ]]; then
    echo "Installing libpulse-mainloop-glib.so.0:x86_64"
    mkdir -p "${SERVER}/linux64/"
    pushd "$(mktemp -d)" > /dev/null
    wget -q http://mirrors.edge.kernel.org/ubuntu/pool/main/p/pulseaudio/libpulse-mainloop-glib0_17.0%2Bdfsg1-2ubuntu3_amd64.deb || true
    if [ -f libpulse-mainloop-glib0_17.0+dfsg1-2ubuntu3_amd64.deb ]; then
        dpkg -x libpulse-mainloop-glib0_17.0+dfsg1-2ubuntu3_amd64.deb ./
        cp usr/lib/x86_64-linux-gnu/libpulse-mainloop-glib.so.0 "${SERVER}/linux64/" 2>/dev/null || true
    fi
    popd > /dev/null
    echo "Installing libpulse-mainloop-glib.so.0:x86_64 - Done"
fi

ENABLE_PLUGINS="${ENABLE_PLUGINS:-true}"
if [ -f "${SERVER}/doorstop_config.ini" ]; then
    sed -i "s/^enabled *=.*/enabled = ${ENABLE_PLUGINS}/" "${SERVER}/doorstop_config.ini"
fi

if [ "$ENABLE_PLUGINS" = "true" ] || [ "$ENABLE_PLUGINS" = "1" ]; then
    echo "Plugins support is ENABLED"
    export WINEDLLOVERRIDES="winhttp=n,b"
else
    echo "Plugins support is DISABLED"
fi

if [ "$ENABLE_CROSSPLAY" = "true" ] || [ "$ENABLE_CROSSPLAY" = "1" ]; then
    echo "Crossplay is ENABLED"
    CROSSPLAY_FLAG="-crossplay"
else
    echo "Crossplay is DISABLED"
    CROSSPLAY_FLAG=""
fi

# World modifier flags support (e.g. -modifier deathpenalty casual -modifier raids muchless)
MODIFIERS_FLAGS=""
if [ -n "$MODIFIERS" ]; then
    echo "World modifiers configured: ${MODIFIERS}"
    MODIFIERS_FLAGS="${MODIFIERS}"
fi

# Extra custom arguments support
EXTRA_ARGS=""
if [ -n "$CUSTOM_ARGS" ]; then
    echo "Custom launch arguments configured: ${CUSTOM_ARGS}"
    EXTRA_ARGS="${CUSTOM_ARGS}"
fi

mkdir -p "${PERSISTENT}/logs"
LOG_FILE="${PERSISTENT}/logs/valheim_$(date '+%d-%m-%Y').log"

echo "Launching valheim_server.exe via Wine and Box64..."

wine valheim_server.exe \
    -name "${SERVER_NAME:-Valheim_Server}" \
    -port "${SERVER_PORT:-2456}" \
    -world "${SERVER_WORLD:-tsx_world}" \
    -password "${SERVER_PASSWORD}" \
    -public ${SERVER_VISIBILITY:-0} \
    -saveinterval ${SERVER_SAVE_INTERVAL:-1800} \
    -backups ${SERVER_BACKUPS:-4} \
    -backupshort ${SERVER_BACKUP_SHORT:-7200} \
    -backuplong ${SERVER_BACKUP_LONG:-43200} \
    -savedir "${PERSISTENT}" \
    ${CROSSPLAY_FLAG:+"$CROSSPLAY_FLAG"} \
    ${MODIFIERS_FLAGS:+"$MODIFIERS_FLAGS"} \
    ${EXTRA_ARGS:+"$EXTRA_ARGS"} \
    -nographics \
    -batchmode \
    2>&1 | tee -a ${LOG_FILE} &

# Find pid for valheim_server
timeout=0
while [ $timeout -lt 15 ]; do
    if ps -e | grep -i "valheim_server" | grep -v "grep" > /dev/null; then
        valheim_pid=$(ps -e | grep -i "valheim_server" | grep -v "grep" | awk '{print $1}' | head -n 1)
        echo "$(timestamp) INFO: valheim_server process detected (PID: $valheim_pid)"
        break
    elif [ $timeout -eq 14 ]; then
        echo "$(timestamp) ERROR: Timed out waiting for valheim_server.exe to be running"
        exit 1
    fi
    sleep 4
    ((timeout++))
    echo "$(timestamp) INFO: Waiting for valheim_server.exe to start..."
done

echo " "
echo "Checking NTSYNC"
echo "Kernel version on this machine is -- $(uname -r)"
if /sbin/lsmod 2>/dev/null | grep -q ntsync; then
  if /usr/bin/lsof /dev/ntsync > /dev/null 2>&1; then
    echo "NTSYNC Module is present in kernel, ntsync is running."
  else
    echo "NTSYNC Module is present in kernel, but ntsync is NOT running. No problem — ntsync is not necessary."
  fi
else
  echo "NTSYNC Module is NOT present in kernel. No problem — ntsync is not necessary."
fi
echo " "

# Wait for valheim_server to complete
wait $valheim_pid 2>/dev/null

echo "$(timestamp) INFO: Shutdown complete."
exit 0
