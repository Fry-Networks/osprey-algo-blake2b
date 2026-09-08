#!/bin/bash
# Osprey BLAKE2b miner entrypoint.
#
# WHY THIS FILE EXISTS SEPARATELY FROM startblake2b.sh
# ---------------------------------------------------
# The web UI's "START" button (Page=setDracaenaMiner) REGENERATES
# /opt/blake2b/startblake2b.sh from a template every time it is pressed, so
# anything we write there is destroyed on first use. The generated script ends
# with the `run_command` string from /var/www/html/libraries.json, with its %s
# placeholders filled from the POSTed form fields named by `run_args`. That
# run_command points here, so this file is the first thing we control that the
# vendor will not overwrite.
#
# The generated wrapper has already done the parts we must not repeat:
#   - stopped xvc_server_{1,2,3} (they hold the JTAG cores)
#   - run `sudo /opt/blake2b/loadallblake2b` to program the FPGA
# so this script must NOT re-run the loader; doing so would reprogram the part
# underneath a running miner.
#
# There is no SSH to this device. This script is therefore the only thing that
# can report a failure happening BEFORE the miner's main() runs -- a missing
# file, a bad bitstream md5, or an "Exec format error" from a wrong-architecture
# build. Everything it does goes to a file under the web root:
#
#   curl http://<device>/blake2b/boot.log
#   curl http://<device>/blake2b/status.json
#
# Args are always passed as --key=value (never bare positionals) because an
# empty UI field expands %s to nothing; with positionals that would silently
# shift every later argument by one.

WEB=/var/www/html/blake2b
LOG=$WEB/boot.log

mkdir -p "$WEB"
chmod 777 "$WEB" 2>/dev/null

exec >"$LOG" 2>&1
set -x

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

echo "=== blake2b run $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "pool=[$POOL] worker=[$WORKER] clk=[$CLK]"   # wallet deliberately not echoed
uname -a
cat /proc/device-tree/model 2>/dev/null; echo

# --- what actually landed on the device ---
# The filename is not cosmetic. The loader reads the JTAG IDCODE and derives the
# path from it: 4b71093 (plain VU35P, this board) -> bits/e335_v3.bit, whereas
# 4b77093 (VU35P_CIV) -> bits/e335c_v3.bit. Ship it under the wrong one and the
# loader never looks at it, falls through to wget-ing the vendor zip, and -- since
# that wget fails cert verification on this Ubuntu 16.04 image -- leaves the FPGA
# unprogrammed and silent.
ls -l /opt/blake2b/ /opt/blake2b/bits/ 2>&1
md5sum /opt/blake2b/bits/e335_v3.bit 2>&1
cat /opt/blake2b/bits/e335_v3.bit.md5sum 2>&1

# --- the UIO devices we depend on ---
# uio8 is the AXI UartLite for FPGA board 0 (serial@42c00000, bound
# "generic-uio" so there is no /dev/ttyUL*); uio1-3 are the axi_jtag cores the
# loader bit-bangs.
ls -l /dev/uio* 2>&1
for u in /sys/class/uio/uio*/name; do echo "$u = $(cat "$u" 2>/dev/null)"; done 2>&1
for u in /sys/class/uio/uio*/maps/map0/addr; do echo "$u = $(cat "$u" 2>/dev/null)"; done 2>&1

# --- nothing else may hold the UART or reprogram the FPGA underneath us ---
# The web UI stops the previously-selected algo, but a stale unit left enabled by
# an earlier firmware update can still come back on its own timer.
for svc in tari_os tari_aft astrix ironfish wala hoohash cryptix verus pyrin \
           nexell odo_os tari_anonymous ironfish_tari_os vecno_os; do
    systemctl stop "$svc".service 2>/dev/null
done
sleep 2
fuser -v /dev/uio8 2>&1

chmod +x /opt/blake2b/blake2b 2>/dev/null

# --- what the vendor actually generated ---
# setDracaenaMiner rewrites startblake2b.sh from its template every START, so
# the only way to know what really ran is to publish the generated copy.
cp /opt/blake2b/startblake2b.sh "$WEB/generated-start.sh" 2>/dev/null
chmod 666 "$WEB/generated-start.sh" 2>/dev/null

# The generated wrapper's loader line has NO output redirection (only the
# ironfish_tari variant redirects to ~/loadbit_log.txt), so its output goes to
# the unit's journal, which is invisible over HTTP. Pull it in.
echo "=== journal for previous run (loader output lands here) ==="
journalctl -u blake2b.service -n 400 --no-pager 2>&1 | tail -120

# Run the loader again ourselves, capturing it this time. FPGA configuration is
# volatile and idempotent -- the vendor reprograms on every start -- so a second
# pass costs nothing and is the only way to see whether the bitstream actually
# takes, which is the difference between "our RTL is wrong" and "our RTL never
# got loaded".
echo "=== loader (captured) ==="
/opt/blake2b/loadallblake2b 2>&1
echo "loader exit=$?"

echo "=== post-loader state ==="
cat ~/loadbit_log.txt 2>/dev/null | tail -40
dmesg 2>/dev/null | tail -20

# --- prove the binary runs at all before trusting the mining loop ---
echo "=== selftest vectors ==="
/opt/blake2b/blake2b --selftest vectors --status "$WEB/status.json" --log "$WEB/miner.log"
echo "vectors exit=$?"

echo "=== selftest uart ==="
/opt/blake2b/blake2b --uart /dev/uio8 --selftest uart --status "$WEB/status.json" --log "$WEB/miner.log"
echo "uart exit=$?"

# The loopback selftest walks up to 168 byte phases at ~3s each -- 8.4 minutes --
# and with Restart=always a failing board just loops on it forever, which starves
# every other diagnostic. It only pays for itself once the FPGA is answering at
# all, so it is gated behind a marker file rather than run unconditionally.
if [ -f /opt/blake2b/ENABLE_LOOPBACK ]; then
    echo "=== selftest loopback ==="
    /opt/blake2b/blake2b --uart /dev/uio8 --selftest loopback --status "$WEB/status.json" --log "$WEB/miner.log"
    echo "loopback exit=$?"
else
    echo "=== selftest loopback SKIPPED (no /opt/blake2b/ENABLE_LOOPBACK) ==="
fi

chmod 666 "$WEB"/* 2>/dev/null

# --- mine ---
# With no pool configured this runs SYNTHETIC work at an inflated target, which
# is the Phase E bring-up mode: no RPC credentials have to reach the device (so
# no secret can end up in the deploy repo), and the metric is the
# verified-candidate rate -- each candidate the FPGA returns is recomputed in
# software and must match. That proves loader + UIO UART + framing + BLAKE2b end
# to end.
#
# It is NOT real mining: the deployed bitstream prefilters on digest word H[0]
# while Bitcoin's target convention needs H[3], so its candidates are not real
# solutions no matter where the work came from. Real getblocktemplate mining
# turns on once the RTL prefilter is fixed and the part resynthesized, at which
# point setting the pool field to host:port takes this branch instead.
echo "=== miner ==="
# setDracaenaMiner silently rejects a START whose pool or wallet field is empty
# -- it returns an empty body instead of {"result":"SUCCESS"} -- so "no pool" has
# to be spelled with a sentinel rather than left blank.
#
# "synthetic:N" also sets the target shift, which is worth being able to change
# from the web form because getting it wrong is not a subtle failure. The
# prefilter is a 64-bit compare, so the candidate rate is
# 250e6 * TargetTop64 / 2^64 per second, while the UART carries at most
# 115200/10/17 = 677 frames/s. The first bring-up ran at shift 64, which makes
# almost every nonce a candidate: the FPGA transmitted flat out at 10.3 kB/s
# (89% of line rate), the result stream never stopped long enough for the reader
# to find a frame boundary, and it logged overruns with frames_ok stuck at 0.
# Raising the shift makes the target EASIER, so bring-up needs a LOWER one than
# the real 22, not a higher one. 16 lands around a few tens of frames a second --
# fast enough to measure in seconds, a few percent of the link.
SHIFT=16
case "$POOL" in
    synthetic:*) SHIFT=${POOL#synthetic:}; POOL= ;;
    synthetic|none|-|'')                   POOL= ;;
esac
if [ -n "$POOL" ]; then
    RPC_HOST=${POOL%%:*}
    RPC_PORT=${POOL##*:}
    [ "$RPC_PORT" = "$POOL" ] && RPC_PORT=8332
    exec /opt/blake2b/blake2b \
        --uart /dev/uio8 \
        --rpc-host "$RPC_HOST" \
        --rpc-port "$RPC_PORT" \
        --status "$WEB/status.json" \
        --log "$WEB/miner.log"
else
    exec /opt/blake2b/blake2b \
        --uart /dev/uio8 \
        --synthetic-work \
        --target-shift "$SHIFT" \
        --status "$WEB/status.json" \
        --log "$WEB/miner.log"
fi
