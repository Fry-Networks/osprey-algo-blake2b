#!/bin/bash
# Deploy driver for the BLAKE2b algo module.
#
# /opt/algorithm/algorithm_update clones the repo named by the web UI's gitlink
# field and then runs THIS file from the clone root with:
#     $1 = path to the clone
#     $2 = version string (the repo's latest git tag)
# The vendor's own repo has the same entrypoint, and its copy refuses to do
# anything when the version is shorter than 5 characters -- so an untagged repo
# deploys nothing, silently. The same guard is kept here so the failure mode is
# identical and visible in the log rather than half-applied.
#
# This is deliberately NOT the vendor's update.sh. That script copies a CGI
# binary, an apache dir.conf and the node webserver out of the repo -- none of
# which this repo ships -- and, more importantly, it records which miner
# services were running and RESTARTS them at the end. Here that would bring Tari
# straight back up to fight us for /dev/uio8 and reprogram the FPGA out from
# under the bitstream we just installed. So this copies what we ship, stops the
# other miners, and starts nothing.
#
# There is no SSH to this device, so everything goes to a log under the web root:
#     curl http://<device>/blake2b/update.log

WEB=/var/www/html/blake2b
sudo mkdir -p "$WEB"
sudo chmod 777 "$WEB"
LOG=$WEB/update.log

exec >>"$LOG" 2>&1
set -x

echo "=== blake2b update $(date -u +%Y-%m-%dT%H:%M:%SZ) path=$1 version=$2 ==="

if [ -z "$1" ]; then
    echo "FATAL: no clone path"
    exit 0
fi

if [ ${#2} -lt 5 ]; then
    echo "FATAL: version '$2' shorter than 5 chars -- refusing, same as vendor update.sh"
    exit 0
fi

ls -lR "$1" | head -60

# --- stop everything that could hold /dev/uio8 or reprogram the FPGA ---
# Not restarted afterwards, unlike the vendor script. tari_os is additionally
# disabled because setDracaenaMiner enables whichever algo it starts, so it
# would otherwise come back on its own at the next boot and fight us.
# Reversal: sudo systemctl enable tari_os.service
for svc in tari_os tari_aft astrix ironfish wala hoohash cryptix verus pyrin \
           nexell odo_os tari_anonymous ironfish_tari_os vecno_os \
           alephium_trm alephium_wf radiant; do
    sudo systemctl stop "$svc".service 2>/dev/null
done
sudo systemctl disable tari_os.service 2>/dev/null

# Our OWN modules have to stop too, and blake2b was missing from the list above
# once. The running miner IS /opt/<name>/<name>, so copying over it fails with
# "Text file busy" -- and cp reports that on stderr and keeps going, so the
# deploy still logs "update done" while silently leaving the OLD binary in
# place. Everything else updates, which makes it look like a successful deploy.
#
# Derived from the clone rather than hardcoded, so adding a third module cannot
# forget this step: MODULES is every modules/<name> except the unit-file dir.
MODULES=$(ls "$1"/modules 2>/dev/null | grep -v '^services$')
echo "modules in this clone: $MODULES"
for m in $MODULES; do
    sudo systemctl stop "$m".service 2>/dev/null
done

# The debug servers hold the JTAG cores the loader needs to drive.
sudo systemctl stop xvc_server_1 2>/dev/null
sudo systemctl stop xvc_server_2 2>/dev/null
sudo systemctl stop xvc_server_3 2>/dev/null

# --- install ---
# modules/<name> becomes /opt/<name>; the vendor start-script generator and the
# patched loader both hardcode that layout.
# Unlink the binary before copying. Stopping the service above should be
# enough, but unlink succeeds even against a busy inode -- any process still
# holding it keeps its own open file and the new one lands regardless. Without
# this the failure is silent and the deploy reports success.
for m in $MODULES; do
    sudo rm -f /opt/"$m"/"$m" 2>/dev/null
done
sudo cp -R "$1"/modules/* /opt/

# cp's failures go to stderr and do not stop the script, so prove each binary
# actually changed rather than trusting that the copy happened.
for m in $MODULES; do
    if ! cmp -s "$1"/modules/"$m"/"$m" /opt/"$m"/"$m"; then
        echo "FATAL: /opt/$m/$m does not match the clone -- install failed"
        ls -l "$1"/modules/"$m"/"$m" /opt/"$m"/"$m"
    fi
done
sudo cp -r "$1"/modules/services/* /etc/systemd/system/
for m in $MODULES; do
    sudo chmod 777 /opt/"$m"/* 2>/dev/null
    sudo chmod +x /opt/"$m"/"$m" /opt/"$m"/loadall"$m" \
                  /opt/"$m"/run.sh /opt/"$m"/start"$m".sh 2>/dev/null
done

# web/html/* lands on /var/www/html/. This is what puts the merged
# libraries.json in place -- without it the UI rejects the algo outright with
# "Error: Miner not found: blake2b".
sudo cp -R "$1"/web/html/* /var/www/html/
sudo chown -R www-data:www-data /var/www/html/
sudo chmod 777 "$WEB"

# /opt/modules/services would be a stray copy of the unit files created by the
# recursive modules copy above; the real ones are in /etc/systemd/system.
sudo rm -rf /opt/services 2>/dev/null

# cp -R only adds, so the CIV-named bitstream from the earlier wrong-device build
# survives every deploy: 22MB the loader will never open on this board, since it
# derives the filename from the IDCODE and this one reads as plain VU35P.
# Removed by name rather than by wildcard so a bitstream for some other board
# could not be swept up by accident.
for m in $MODULES; do
    sudo rm -f /opt/"$m"/bits/e335c_v3.bit /opt/"$m"/bits/e335c_v3.bit.md5sum 2>/dev/null
done

if [ ${#2} -ge 5 ]; then
    sudo mkdir -p /opt/algorithm
    echo "$2" | sudo tee /opt/algorithm/algorithm_version.txt
fi

sudo systemctl daemon-reload

# The long-running `webserver` process behind the CGI parses
# /var/www/html/libraries.json ONCE at startup into its g_minerListInfo global.
# Until it is restarted it keeps the old list, and setDracaenaMiner answers a
# START with an empty body -- its "Error: Miner not found: blake2b" path -- no
# matter how correct the file on disk is. The vendor's update.sh stops and kills
# webserver for exactly this reason; this is the minimal equivalent.
sudo systemctl restart webserver.service
sleep 3

# --- prove what landed, since this log is the only way to see it ---
# The BuildID in `file` output is the single most valuable line here: it is what
# distinguishes "the new binary installed" from "the copy failed and the old one
# is still running", which otherwise look identical in this log.
for m in $MODULES; do
    echo "=== installed: $m ==="
    ls -l /opt/"$m"/ /opt/"$m"/bits/
    # e335_v3.bit, not e335c_v3.bit: this board's IDCODE reads as a plain VU35P,
    # so that is the name the loader derives and the only bitstream we ship. The
    # CIV name is deleted above, so checking it here proved nothing at all.
    md5sum /opt/"$m"/bits/e335_v3.bit
    cat /opt/"$m"/bits/e335_v3.bit.md5sum
    file /opt/"$m"/"$m" 2>/dev/null
    grep -c "$m" /var/www/html/libraries.json
    systemctl cat "$m".service 2>&1 | head -12
done
systemctl is-enabled tari_os.service 2>&1

echo "=== blake2b update done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
exit 0
