#!/bin/bash
# Osprey BLAKE2b algo entrypoint.
#
# There is no SSH to this device, so this script is the only thing that can
# report a failure happening BEFORE the miner's main() runs — a missing file, a
# bad bitstream md5, or an "Exec format error" from a wrong-architecture build.
# Everything it does goes to a file under the web root, fetchable over HTTP:
#
#   curl http://<device>/blake2b/boot.log
#   curl http://<device>/blake2b/status.json

WEB=/var/www/html/blake2b
LOG=$WEB/boot.log

mkdir -p "$WEB"
chmod 777 "$WEB" 2>/dev/null

exec >"$LOG" 2>&1
set -x

echo "=== blake2b start $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
uname -a
cat /proc/device-tree/model 2>/dev/null; echo

# --- what we shipped ---
ls -l /opt/blake2b/ /opt/blake2b/bits/ 2>&1
md5sum /opt/blake2b/bits/e335c_v3.bit 2>&1
cat /opt/blake2b/bits/e335c_v3.bit.md5sum 2>&1

# --- the UIO devices we depend on ---
# uio8 is the AXI UartLite for FPGA board 0 (serial@42c00000); uio1-3 are the
# axi_jtag cores the loader bit-bangs.
ls -l /dev/uio* 2>&1
for u in /sys/class/uio/uio*/name; do echo "$u = $(cat "$u" 2>/dev/null)"; done 2>&1
for u in /sys/class/uio/uio*/maps/map0/addr; do echo "$u = $(cat "$u" 2>/dev/null)"; done 2>&1

# --- nothing else may hold the UART or reprogram the FPGA underneath us ---
for svc in tari_os tari_aft astrix ironfish wala hoohash cryptix verus pyrin \
           nexell odo_os tari_anonymous ironfish_tari_os vecno_os; do
    systemctl stop "$svc".service 2>/dev/null
done
sleep 2
fuser -v /dev/uio8 2>&1

chmod +x /opt/blake2b/loadallblake2b /opt/blake2b/blake2b 2>/dev/null

# --- program the FPGA (patched vendor loader, reads /opt/blake2b/bits/) ---
echo "=== loader ==="
/opt/blake2b/loadallblake2b
echo "loader exit=$?"

# --- prove the binary runs at all before trusting the mining loop ---
echo "=== selftest vectors ==="
/opt/blake2b/blake2b --selftest vectors --status "$WEB/status.json" --log "$WEB/miner.log"
echo "vectors exit=$?"

echo "=== selftest uart ==="
/opt/blake2b/blake2b --selftest uart --status "$WEB/status.json" --log "$WEB/miner.log"
echo "uart exit=$?"

chmod 666 "$WEB"/* 2>/dev/null

# --- mine ---
# Bring-up runs on SYNTHETIC work at an inflated target (--target-shift), for two
# reasons. First, no RPC credentials then have to be shipped to the device, so no
# secret ends up in the deploy repo. Second, the deployed bitstream prefilters on
# digest word H[0] while Bitcoin's target convention needs H[3], so its candidates
# are NOT real solutions regardless of where the work came from. The metric here is
# the verified-candidate rate, which proves loader + UART + framing + BLAKE2b end
# to end. Real getblocktemplate mining comes after the RTL prefilter fix.
echo "=== miner ==="
exec /opt/blake2b/blake2b \
    --uart /dev/uio8 \
    --synthetic-work \
    --target-shift "${BLAKE2B_TARGET_SHIFT:-64}" \
    --status "$WEB/status.json" \
    --log "$WEB/miner.log"
