#!/bin/bash
#
# Copyright (c) 2021 Matthew Penner
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

# Default the TZ environment variable to UTC.
TZ=${TZ:-UTC}
export TZ

# Set environment variable that holds the Internal Docker IP
# INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
#export INTERNAL_IP

# Switch to the container's working directory
cd /home/container || exit 1

# Update Resonite headless
STEAMCMD_BETA_PASSWORD=""
if [ ! "${BETA_CODE}" = "" ]; then
	STEAMCMD_BETA_PASSWORD="-betapassword ${BETA_CODE}"
fi

# Handle if we have no Steam branch
# - we will run into this with people using older eggs
if [ "${STEAM_BRANCH}" = "" ]; then
	echo "Manually adding Steam branch!"
	STEAM_BRANCH="headless"
fi

INSTALL_DIRECTORY="/home/container/Resonite"
LEGACY_INSTALL="FALSE"

if [ -f /home/container/Build.version ]; then
	echo "Legacy install location detected"
	INSTALL_DIRECTORY="/home/container"
	LEGACY_INSTALL="TRUE"
fi

if [ ${LEGACY_INSTALL} = "FALSE" ]; then
	if [ ! -L /home/container/Headless ]; then
		echo "Symlink doesn't exist!"
		mkdir -p /home/container/Resonite/Headless
		ln -s /home/container/Resonite/Headless /home/container/Headless
	fi
fi

./steamcmd/steamcmd.sh +login ${STEAM_USER} ${STEAM_PASSWORD} ${STEAM_AUTH} +@sSteamCmdForcePlatformType windows +force_install_dir ${INSTALL_DIRECTORY} +app_license_request 2519830 +app_update 2519830 -beta ${STEAM_BRANCH} ${STEAMCMD_BETA_PASSWORD} validate +quit

# Modding stuff
HEADLESS_DIRECTORY="/home/container"

if [ "${ENABLE_MODS}" = "true" ] || [ "${ENABLE_MODS}" = "1" ]; then
	echo "Mods are enabled."

	mkdir -p ${HEADLESS_DIRECTORY}/Libraries

	mkdir -p ${HEADLESS_DIRECTORY}/rml_mods
	mkdir -p ${HEADLESS_DIRECTORY}/rml_libs
	mkdir -p ${HEADLESS_DIRECTORY}/rml_config

	# Download ResoniteModLoader
	echo "Downloading ResoniteModLoader and 0Harmony"

	# Make sure we don't have older versions of 0Harmony
	rm ${HEADLESS_DIRECTORY}/rml_libs/0Harmony-Net8.dll
	rm ${HEADLESS_DIRECTORY}/rml_libs/0Harmony-Net9.dll

	curl -SslL https://github.com/resonite-modding-group/ResoniteModLoader/releases/latest/download/0Harmony.dll -o ${HEADLESS_DIRECTORY}/rml_libs/0Harmony.dll
	curl -SslL https://github.com/resonite-modding-group/ResoniteModLoader/releases/latest/download/ResoniteModLoader.dll -o ${HEADLESS_DIRECTORY}/Libraries/ResoniteModLoader.dll

	# Install mods
	if [ "${MOD_PROMETHEUS}" = "1" ]; then
		echo "Installing HeadlessPrometheusExporter by J4"
		curl -SslL https://i.j4.lc/resonite/mods/latest/HeadlessPrometheusExporter.dll -o ${HEADLESS_DIRECTORY}/rml_mods/HeadlessPrometheusExporter.dll
	fi

	if  [ "$MOD_HEADLESSTWEAKS" = "1" ]; then
		echo "Installing HeadlessTweaks by New_Project_Final_Final_WIP"
		curl -SslL https://github.com/New-Project-Final-Final-WIP/HeadlessTweaks/releases/latest/download/HeadlessTweaks.dll -o ${HEADLESS_DIRECTORY}/rml_mods/HeadlessTweaks.dll
	fi

	if [ "$MOD_HEADLESSUSERCULLING" = "1" ]; then
		echo "Installing HeadlessUserCulling by Raidriar"
		curl -SslL https://codeberg.org/Raidriar/HeadlessUserCulling/releases/download/latest/HeadlessUserCulling.dll -o ${HEADLESS_DIRECTORY}/rml_mods/HeadlessUserCulling.dll
	fi

	if [ "$MOD_STRESSLESSHEADLESS" = "1" ]; then
		echo "Installing StresslessHeadless by Raidriar"
		curl -SslL https://codeberg.org/Raidriar/StresslessHeadless/releases/download/latest/StresslessHeadless.dll -o ${HEADLESS_DIRECTORY}/rml_mods/StresslessHeadless.dll
	fi

fi

# Convert all of the "{{VARIABLE}}" parts of the command into the expected shell
# variable format of "${VARIABLE}" before evaluating the string and automatically
# replacing the values.
parse_startup() {
    echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g' | eval echo "$(cat -)"
}

# ---------------------------------------------------------------------------
# Single-instance mode (default, unchanged behaviour)
# Used when the INSTANCES variable is empty.
# ---------------------------------------------------------------------------
if [ -z "${INSTANCES}" ]; then
    PARSED=$(parse_startup)

    # Display the command we're running in the output, and then execute it with the env
    # from the container itself.
    printf "\033[1m\033[33mcontainer@pterodactyl~ \033[0m%s\n" "$PARSED"

    # shellcheck disable=SC2086
    exec env ${PARSED}
fi

# ---------------------------------------------------------------------------
# Multi-instance mode
#
# INSTANCES is a comma-separated list of names, e.g. "main,events". Every
# instance shares the Resonite install and mods above, but gets its own:
#   - Config/<name>.json   (created from Config/Config.json if missing)
#   - Data/<name>          (-DataPath)
#   - Cache/<name>         (-CachePath)
#   - Logs/<name>/         (the -Logs argument from STARTUP is rewritten per instance)
#   - "[name] " prefix on its console output
#
# Console input is routed by prefix:
#   @<name> <command>   send to one instance
#   @all <command>      send to every instance
#   shutdown | exit     send to every instance
#   anything else       send to the first instance in the list
# ---------------------------------------------------------------------------
IFS=',' read -ra INSTANCE_LIST <<< "${INSTANCES// /}"
DEFAULT_INSTANCE="${INSTANCE_LIST[0]}"
declare -A PIDS FDS STARTED WARNED
STOPPING=0
FIFO_DIR=$(mktemp -d)

mkdir -p Config Logs Data Cache Watchdogs

# Optional watchdog: if WATCHDOG_TIMEOUT (seconds) is > 0, each instance is started with
# -Watchdog Watchdogs/<name>.txt and restarted if that file goes stale for that long.
# WATCHDOG_GRACE (default 300s) is the time allowed after (re)start before checking.
WATCHDOG_TIMEOUT="${WATCHDOG_TIMEOUT:-0}"
WATCHDOG_GRACE="${WATCHDOG_GRACE:-300}"

send() { # send <instance> <command>
    printf '%s\n' "$2" >&"${FDS[$1]}"
}

shutdown_all() {
    local n
    STOPPING=1
    for n in "${!PIDS[@]}"; do send "$n" "shutdown"; done
}

start_instance() {
    local name="$1" cfg="Config/$1.json" fifo="$FIFO_DIR/$1" parsed

    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Invalid instance name '$name' (use letters, numbers, - and _). Skipping."
        return
    fi

    if [ ! -f "$cfg" ]; then
        echo "[$name] $cfg not found, creating it from Config/Config.json. Edit it (session name, ports) before use!"
        cp Config/Config.json "$cfg"
    fi

    mkdir -p "Data/$name" "Cache/$name" "Logs/$name"

    # Per-instance stdin pipe, opened read/write so the reader never sees EOF.
    # (On a restart, close the old descriptor and recreate the pipe.)
    if [ -n "${FDS[$name]}" ]; then eval "exec ${FDS[$name]}>&-"; fi
    rm -f "$fifo"
    mkfifo "$fifo"
    exec {fd}<>"$fifo"
    FDS[$name]=$fd

    parsed=$(CONFIG_FILENAME="$name.json" parse_startup)

    # Give each instance its own log directory
    if [[ "$parsed" =~ -Logs[[:space:]] ]]; then
        parsed=$(sed -E "s#(-Logs[[:space:]]+)[^[:space:]]+#\1Logs/$name/#" <<< "$parsed")
    else
        parsed="$parsed -Logs Logs/$name/"
    fi

    if [ "$WATCHDOG_TIMEOUT" -gt 0 ] 2>/dev/null; then
        rm -f "Watchdogs/$name.txt"
        parsed="$parsed -Watchdog Watchdogs/$name.txt"
    fi

    printf "\033[1m\033[33m[%s] container@pterodactyl~ \033[0m%s -DataPath Data/%s -CachePath Cache/%s\n" \
        "$name" "$parsed" "$name" "$name"

    # shellcheck disable=SC2086
    env ${parsed} -DataPath "Data/$name" -CachePath "Cache/$name" \
        < "$fifo" > >(sed -u "s/^/[$name] /") 2>&1 &
    PIDS[$name]=$!
    STARTED[$name]=$(date +%s)
    WARNED[$name]=0
}

# Restart an instance whose watchdog file has stopped updating.
# Only acts on instances that are still running but frozen; instances that exited
# (crash or an explicit "@name shutdown") are left alone.
check_watchdog() {
    local n="$1" f="Watchdogs/$1.txt" now mtime
    [ "$WATCHDOG_TIMEOUT" -gt 0 ] 2>/dev/null || return 0
    now=$(date +%s)
    (( now - STARTED[$n] < WATCHDOG_GRACE )) && return 0

    if [ ! -f "$f" ]; then
        # Never written since start: the argument may be unsupported. Don't restart-loop.
        if [ "${WARNED[$n]}" = 0 ]; then
            echo "[$n] Watchdog file $f has not been written ${WATCHDOG_GRACE}s after start; watchdog disabled for this instance."
            WARNED[$n]=1
        fi
        return 0
    fi

    mtime=$(stat -c %Y "$f")
    if (( now - mtime > WATCHDOG_TIMEOUT )); then
        echo "[$n] Watchdog stale for $((now - mtime))s (limit ${WATCHDOG_TIMEOUT}s). Restarting instance."
        restart_instance "$n"
    fi
}

restart_instance() {
    local n="$1" pid="${PIDS[$n]}" i
    send "$n" "shutdown"
    for i in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "[$n] Did not stop gracefully, killing."
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi
    start_instance "$n"
}

route() {
    local line="$1" n
    if [[ "$line" =~ ^@all[[:space:]]+(.*)$ ]]; then
        for n in "${!PIDS[@]}"; do send "$n" "${BASH_REMATCH[1]}"; done
    elif [[ "$line" =~ ^@([A-Za-z0-9_-]+)[[:space:]]+(.*)$ ]]; then
        if [ -n "${FDS[${BASH_REMATCH[1]}]}" ]; then
            send "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        else
            echo "Unknown instance '${BASH_REMATCH[1]}'. Instances: ${INSTANCE_LIST[*]}"
        fi
    elif [ "$line" = "shutdown" ] || [ "$line" = "exit" ]; then
        shutdown_all
    else
        send "$DEFAULT_INSTANCE" "$line"
    fi
}

trap shutdown_all TERM INT

for name in "${INSTANCE_LIST[@]}"; do
    start_instance "$name"
    sleep "${INSTANCE_STAGGER:-5}"   # stagger startup so instances don't all hit disk/CPU at once
done

# Forward console input; exit once every instance has stopped
while true; do
    alive=0
    for n in "${!PIDS[@]}"; do
        kill -0 "${PIDS[$n]}" 2>/dev/null && alive=1
    done
    [ "$alive" = 0 ] && break

    if [ "$STOPPING" = 0 ]; then
        for n in "${!PIDS[@]}"; do
            kill -0 "${PIDS[$n]}" 2>/dev/null && check_watchdog "$n"
        done
    fi

    IFS= read -r -t 1 line
    rc=$?
    if [ $rc -eq 0 ]; then
        route "$line"
    elif [ $rc -eq 1 ]; then
        sleep 1   # stdin closed; avoid a busy loop
    fi
done

echo "All instances have stopped."
rm -rf "$FIFO_DIR"
exit 0
