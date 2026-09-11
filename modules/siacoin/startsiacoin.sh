#!/bin/bash
# Fallback entrypoint for siacoin.service.
#
# THIS FILE IS EXPECTED TO BE OVERWRITTEN. Pressing "START" in the web UI
# (Page=setDracaenaMiner) regenerates /opt/siacoin/startsiacoin.sh from the
# vendor's template, which stops the xvc_server JTAG holders, runs
# `sudo /opt/siacoin/loadallsiacoin`, then invokes the `run_command` from
# /var/www/html/libraries.json -- which points at run.sh. It also appends the
# `#{...}` config comment that getDracaMinerStatus reads back with
# `cat /opt/siacoin/startsiacoin.sh | grep "#{"`.
#
# So this version only matters in the window before the first START press, or if
# the unit is started directly. It reproduces the same two steps the generated
# script would do -- program the FPGA, then hand off to run.sh -- so that path
# behaves identically instead of silently doing nothing.

set -x

# The JTAG cores cannot be held by the debug servers while the loader drives them.
systemctl stop xvc_server_1 2>/dev/null
systemctl stop xvc_server_2 2>/dev/null
systemctl stop xvc_server_3 2>/dev/null

chmod +x /opt/siacoin/loadallsiacoin /opt/siacoin/run.sh /opt/siacoin/siacoin 2>/dev/null

/opt/siacoin/loadallsiacoin

# Siacoin is pool-only; with no pool configured run.sh exits with a clear
# FATAL rather than pretending to mine.
exec /opt/siacoin/run.sh --pool= --wallet= --worker=bringup --clk=800
