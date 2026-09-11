#!/bin/bash
# Osprey Siacoin miner entrypoint.
#
# The sibling of modules/blake2b/run.sh, and it exists for the same reason: the
# web UI's START button regenerates /opt/siacoin/startsiacoin.sh from a template
# on every press, so anything written there is destroyed on first use. The
# generated wrapper ends with the `run_command` string from
# /var/www/html/libraries.json, which points here -- the first file the vendor
# will not overwrite.
#
# The generated wrapper has ALREADY stopped xvc_server_{1,2,3} and run
# `sudo /opt/siacoin/loadallsiacoin` to program the FPGA. This script must NOT
# re-run the loader: that would reprogram the part underneath a running miner.
#
# There is no SSH to this device, so this script is the only thing that can
# report a failure happening before the miner's main() runs:
#
#   curl http://<device>/siacoin/boot.log
#   curl http://<device>/siacoin/status.json
#
# WHAT DIFFERS FROM THE BLAKE2b MODULE
# ------------------------------------
# Siacoin is pool-only here. There is no Siacoin node behind this device, so
# there is no getblocktemplate path to fall back to -- the pool field is always
# a stratum endpoint. The miner binary is the same source tree built with a
# different default chain (--algo sia), because the two chains share the whole
# Sia stratum transport and differ only in the work-item layout (88 vs 168
# bytes) and the compare rule (H[0] vs H[3]).

WEB=/var/www/html/siacoin
LOG=$WEB/boot.log

mkdir -p "$WEB"
chmod 777 "$WEB" 2>/dev/null

exec >"$LOG" 2>&1

# Argument parsing runs with tracing OFF, deliberately. boot.log is served over
# HTTP with no authentication, and xtrace prints assignments with the value
# already expanded -- which is how a password reaches a world-readable file.
POOL=
WALLET=
WORKER=
CLK=
for a in "$@"; do
    case "$a" in
        --pool=*)   POOL=${a#--pool=}   ;;
        --wallet=*) WALLET=${a#--wallet=} ;;
        --worker=*) WORKER=${a#--worker=} ;;
        --clk=*)    CLK=${a#--clk=}     ;;
    esac
done

set -x

echo "=== siacoin boot $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
uname -a
ls -l /opt/siacoin/ /opt/siacoin/bits/ 2>&1
md5sum /opt/siacoin/bits/e335_v3.bit 2>&1
cat /opt/siacoin/bits/e335_v3.bit.md5sum 2>&1
file /opt/siacoin/siacoin 2>&1
ls -l /dev/uio* 2>&1
fuser -v /dev/uio8 2>&1

chmod +x /opt/siacoin/siacoin 2>/dev/null

# Publish a REDACTED copy of whatever the vendor actually generated. It carries
# the credential twice and in two different shapes -- as --wallet=<u>:<p> in the
# run_command and as "u":"<u>:<p>" in the trailing #{...} config comment -- so
# both patterns are handled. "u1" must not be caught, hence the exact "u":
# prefix. This destination is served over HTTP with no authentication.
redact() { sed -E -e 's/--wallet=[^ ]*/--wallet=<REDACTED>/g' -e 's/"u":"[^"]*"/"u":"<REDACTED>"/g'; }

redact < /opt/siacoin/startsiacoin.sh > "$WEB/generated-start.sh" 2>/dev/null
chmod 666 "$WEB/generated-start.sh" 2>/dev/null

# The generated wrapper's loader line has no output redirection, so the loader's
# own output goes to the unit journal, which is invisible over HTTP. Pull it in,
# redacted for the same reason.
echo "=== journal for previous run (loader output lands here) ==="
journalctl -u siacoin.service -n 400 --no-pager 2>&1 | redact | tail -120

set +x

# --- miner ---
# On a pool the "wallet" field is the worker name, with an optional ":password"
# suffix following the same convention the BLAKE2b module uses for
# rpcuser:rpcpassword. Tracing stays off through this whole section.
POOL_WORKER=${WALLET%%:*}
case "$WALLET" in
    *:*) POOL_PASS=${WALLET#*:} ;;
    *)   POOL_PASS=x ;;
esac

# Strip a scheme if the operator typed one; the miner wants host:port.
case "$POOL" in
    stratum+tcp://*) POOL=${POOL#stratum+tcp://} ;;
    stratum://*)     POOL=${POOL#stratum://}     ;;
esac

if [ -z "$POOL" ] || [ "$POOL" = "synthetic" ] || [ "$POOL" = "none" ] || [ "$POOL" = "-" ]; then
    echo "FATAL: siacoin is pool-only -- there is no Siacoin node behind this"
    echo "       device, so there is no getblocktemplate fallback. Set the pool"
    echo "       field to a Siacoin stratum endpoint (host:port)."
    exit 1
fi

echo "siacoin mode: pool=$POOL worker=$POOL_WORKER clk=$CLK"

export OSPREY_POOL_PASS="$POOL_PASS"
unset POOL_PASS WALLET
exec /opt/siacoin/siacoin \
    --uart /dev/uio8 \
    --algo sia \
    --stratum "$POOL" \
    --worker "$POOL_WORKER" \
    --pool-pass-env OSPREY_POOL_PASS \
    --submit \
    --status "$WEB/status.json" \
    --log "$WEB/miner.log"
