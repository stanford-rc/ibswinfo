#!/usr/bin/env bash
# vim: set tabstop=4 expandtab shiftwidth=4:
# vim: set textwidth=80:
#
#==============================================================================
# ibswinfo
#
# Gather information from unmanaged Infiniband switches
#
# Requires  : NVIDIA Firmare Tools (MFT)
#
# Author    : Kilian Cavalotti <kilian@stanford.edu>
# Created   : 2020/04/20
# License   : GNU GPL v3
#
#==============================================================================

set -e      # stop on error
set -u      # stop on uninitialized variable

## -- constants ---------------------------------------------------------------

MFT_URL="https://www.mellanox.com/products/adapter-software/firmware-tools"
MAX_ND_LEN=64


## -- functions ---------------------------------------------------------------

# display error and quit
err() {
    [[ "$*" != "" ]] && echo "error: $*" >&2
    exit 1
}

# display separators
sep()    { echo "-------------------------------------------------" ;}
dblsep() { echo "=================================================" ;}

# display key-value
out_kv() {
    local k=$1
    local v=$2
    local s
    [[ "${out:-}" != "" ]] && s=":" || s="|"
    [[ "$v" != "" ]] && printf "%-18s %s %s\n" "$k" "$s" "$v" || return 0
}

# hex to dec
htod() {
    local d=$1
    echo $((16#${d//0x/}))
}

# hex to bin
# $1: hex value to convert
# $2: num bits to output
htob() {
    local v=$1
    local b=${2:-16}
    for ((i=b-1; i>=0; i--)); do
        printf "%d" $(( (v>>i)%2 ));
    done
    echo
}

# dec to hex
dtoh() {
    local h=$1
    printf "%x\n" "$h"
}

# hex to string
#  sample input:
#    0x73656372657420
#    0x6d657373616765
#  sample output:
#    secret message
htos() {
    local h=$*
    local s
    s=$(sed 's/0x\|[[:space:]]//g; s/\(..\)/\\x\1/g' <<< "$h")
    printf "%b\n" "$s" | tr -d \\0
}

# string to hex array (split and padded)
#  sample input:
#    secret message
#  sample output:
#    0x73656372
#    0x6574206d
#    0x65737361
#    0x67650000
stoh() {
    local str=$*
    local i chr hex
    local cks=8 # chunk size for splitting
    # convert
    for (( i=0; i<${#str}; i++ )); do
        chr="${str:$i:1}"
        hex+=$(printf "%x" "'${chr}")
    done
    # pad
    [[ $((${#hex}%cks)) != 0 ]] && \
        hex+=$(printf "%-$((cks-${#hex}%cks))s" "" | tr ' ' '0')
    # split
    for (( i=0; i<${#hex}; i+=cks )); do
        echo "0x${hex:$i:$cks}"
    done
}

# seconds to d-h:m:s
sec_to_dhms() {
    local s=$1
    printf '%dd-%02d:%02d:%02d\n' $((s/86400))  \
                                  $((s%86400/3600)) \
                                  $((s%3600/60)) \
                                  $((s%60))
}

# get register values
#  $1: reg name
#  $2: indexes (optional)
get_reg() {
    local reg=$1
    local idx=${2:+--indexes "$2"}
    # shellcheck disable=SC2086
    mlxreg_ext -d "$dev" --reg_name "$reg" --get $idx 2>&1
}

# show register definition
#  $1: reg name
show_reg() {
    local reg=$1
    mlxreg_ext -d "$dev" --show_reg "$reg" 2>&1
}

# decode multifield values from register
#  $1: field name (regex supported)
#  $2: reg name
mstr_dec() {
    local f=$1
    local r=$2
    # sort fields, and convert them, in one fell swoop
    htos "$(awk -v f="$f" '$0 ~ f {gsub(/\[|\]/," "); print}' \
            <<< "${reg[$r]}" | sort -k2n | awk '{printf $NF}')"
}


## -- arg handling ------------------------------------------------------------

usage() {
    cat << EOU
Usage: ${0##*/} -d <device> [-T] [-o <$outputs>] [-S <description>]

  global options:
    -d <device>             MST device path ("mst status" shows devices list)
                            or LID (eg. "-d lid-44")
  get info:
    -o <output_category>    Only display $outputs information
    -T                      get QSFP modules temperature

  set info:
    -S <description>        set device description ($MAX_ND_LEN char max.)

EOU
    return 0
}

# defaults
outputs="inventory|vitals|status"
out=""
dev=""
desc=""
opt_T=0
optspec="hd:To:S:"
while getopts "$optspec" optchar; do
    case "${optchar}" in
        h|\?)
            usage >&2
            exit 2
            ;;
        d)
            dev=${OPTARG}
            ;;
        T)
            opt_T=1
            ;;
        o)
            out=${OPTARG}
            [[ ! "$out" =~ ^($outputs)$ ]] && {
                err "unknown output requested, not in $outputs"
                exit 2
            }
            ;;
        S)
            desc=${OPTARG}
            [[ ${#desc} -gt $MAX_ND_LEN ]] && {
                err "description string > $MAX_ND_LEN characters"
                exit 2
        }
            ;;
    esac
done

# drop -T for inventory/status outputs
[[ "$out" =~ inventory|status ]] && opt_T=0

# check conflicting options
[[ -n "$desc" ]] && [[ -n "$out" || "$opt_T" -eq 1 ]] && {
    err "conflicting options, can't get and set info at the same time"
    exit 2
}


## -- checks ------------------------------------------------------------------

# id
[[ "$(id -u)" == 0 ]] || err "must run as root, aborting."

# tools and dependencies
declare -A tools
tools[awk]=""
tools[sed]=""
tools[tr]="coreutils"
tools[paste]="coreutils"
tools[mst]="MFT ($MFT_URL)"
tools[mlxreg]="MFT ($MFT_URL)"
tools[smpquery]="infiniband-diags"
for t in "${!tools[@]}"; do
    type $t &>/dev/null || \
        err "$t not found${tools[$t]:+, please install ${tools[$t]}}"
done

# MFT version
mft_cur=$(mst version | awk '{gsub(/,/,""); print $3}' | cut -d- -f1)
mft_req="4.18.0"
mft_req_desc="4.22.0" # minimum requirement to set device version
mft_cur=$(mst version | awk '{gsub(/,/,""); print $3}' | cut -d- -f1)
[[ ${mft_cur//./} -lt ${mft_req//./} ]] && \
    err "MFT version must be >= $mft_req (current version is $mft_cur)"
[[ "$desc" != "" ]] && [[ ${mft_cur//./} -lt ${mft_req_desc//./} ]] && \
    err "MFT >= $mft_req_desc required to set device description"

# device
[[ $dev == "" ]] && err "missing device argument"
[[ ${dev:0:4} != "lid-" ]] && {
    [[ ${dev:0:8} == '/dev/mst' ]] && dev=${dev/\/dev\/mst\//}
    [[ ${dev:0:3} == "SW_" ]] || err "$dev doesn't look like a switch device name"
    [[ -r /dev/mst/$dev ]] || err "$dev not found in /dev/mst, is mst started?"
}


## -- initiate registers ------------------------------------------------------

# PRM registers
# cf. mft/prm_dbs/switch/ext/register_access_table.adb
# and kernel:drivers/net/ethernet/mellanox/mlxsw/reg.h
#
# MGIR  -  Management General Information Register
# MGPIR -  Management General Peripheral Information Register
# MSGI  -  Misc System General Information Register
# MSPS  -  Misc System Power Supply Register
# MTMP  -  Management Temperature
# MTCAP -  Management Temperature Capabilities
# MFCR  -  Management Fan Control Register
# FORE  -  Fan Out of Range Event Register
# SPZR  -  ...? node description

# gather register values
declare -A reg
declare -A rid
# select register to read, depending on what output is required
case $out in
    inventory)
        reg_names="MGIR MSGI SPZR MSPS"
        ;;
    status)
        reg_names="MGIR MGPIR MSPS MTMP MTCAP MFCR FORE"
        ;;
    vitals)
        reg_names="MGIR MGPIR MSPS MTMP MTCAP MFCR"
        ;;
    *)
        reg_names="MGIR MGPIR MSGI MSPS SPZR MTMP MTCAP MFCR FORE"
        ;;
esac
# some registers need an index
# and that depends on the version of MFT we're using
[[ ${mft_cur//./} -gt 4150 ]] && add_idx="slot_index=0x0" || add_idx=""
[[ ${mft_cur//./} -gt 4190 && \
   ${mft_cur//./} -lt 4210 ]] && rid[MGIR]="module_base=0x0"
[[ ${mft_cur//./} -ge 4230 ]] && rid[SPZR]="router_entity=0x0,"
rid[SPZR]+="swid=0x0"
rid[MTMP]="sensor_index=0x0${add_idx:+,$add_idx}"
rid[MTCAP]="$add_idx"
# get registers
_regs=$(for r in $reg_names; do
            echo "$r" "$(get_reg "$r" "${rid[$r]:-}" |& paste -s -d '@')" &
        done)
# store them
while read -r r v; do
    o=${v//@/$'\n'}
    [[ "$o" =~ -E- ]] && [[ $r != MGPIR ]] && err "${o/-E-/}"
    reg[$r]=$o
done <<< "$_regs"


## -- node description mgmt ---------------------------------------------------

[[ -n "$desc" ]] && {
    # get current node description
    cur_nd=$(mstr_dec "node_description" SPZR)
    echo "Device: $dev"
    echo "  Current node description: $cur_nd"
    echo "  Set node description to : $desc"
    read -p ">> Confirm? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    echo -n "Setting new node description... "

    # convert string to hex array
    mapfile -t nd_arr < <(stoh "$desc")
    val="ndm=0x1"
    for e in "${!nd_arr[@]}"; do
        val+=",node_description[$e]=${nd_arr[$e]}"
    done
    # fill all remaining fields with 0s to make sure we override all of the
    # previous node description
    ((e+=1))
    while [[ $e -le 15 ]]; do
        val+=",node_description[$e]=0x00000000"
        ((e+=1))
    done
    mlxreg_out=$(mlxreg_ext -d "$dev" --reg_name SPZR --set "$val" \
                            --indexes "${rid[SPZR]}" --yes)
    ret=$?
    [[ "$ret" != 0 ]] && {
        err "$mlxreg_out"
        exit $ret
    }
    echo "done!"
    exit 0
}


## -- data gathering ----------------------------------------------------------

# extract data from register values
# inventory
[[ ! "$out" =~ status|vitals ]] && {
    # part/serial number
    pn=$(mstr_dec "part_number"   MSGI)
    sn=$(mstr_dec "serial_number" MSGI)
    cn=$(mstr_dec "roduct_name"   MSGI)
    rv=$(htos "$(awk '/revision/  {printf $NF}' <<< "${reg[MSGI]}")")

    # PSID
    psid=$(mstr_dec '^psid' MGIR)

    # FW version
    maj=$(htod "$(awk '/extended_major/ {printf $NF}' <<< "${reg[MGIR]}")")
    min=$(htod "$(awk '/extended_minor/ {printf $NF}' <<< "${reg[MGIR]}")")
    sub=$(htod "$(awk '/extended_sub_minor/ {printf $NF}' <<< "${reg[MGIR]}")")

    # node description
    #shellcheck disable=SC2046
    nd=$(mstr_dec "node_description" SPZR)
    guid=$(awk '/node_guid/ {gsub(/0x/,"",$NF); g=g$NF} END {print "0x"g}' \
          <<< "${reg[SPZR]}")
}

# status
[[ ! "$out" =~ inventory|vitals ]] && {
    # fan under/over limit alerts
    fu=$(htod "$(awk '/fan_under_limit/ {printf $NF}' <<< "${reg[FORE]}")")
    fo=$(htod "$(awk '/fan_over_limit/ {printf $NF}'  <<< "${reg[FORE]}")")
    # TODO break down FORE bitmasks to get alerted fan id
    [[ $((fo+fu)) == 0 ]] && fa="OK" || fa="ERROR"
}

# vitals and status
[[ ! $out =~ inventory ]] && {
    # number of ports
    _np=$(awk '/num_of_modules/ {printf $NF}' <<< "${reg[MGPIR]}")
    if [[ $_np =~ ^0x ]]; then
        np=$(htod "$_np")
    else # try to get that from the SM
        _s=$(smpquery NI -G "${guid:-}" | awk -F.  '/NumPorts/ {print $NF}')
        np=$((_s%2==0?_s:_s-1))
    fi

    # uptime
    h_uptime=$(awk '/uptime/ {print $NF}' <<< "${reg[MGIR]}")
    s_uptime=$(htod "$h_uptime")

    # temperatures
    _tp=$(htod "$(awk '/^temperature /    {printf $NF}' <<< "${reg[MTMP]}")")
    _mt=$(htod "$(awk '/max_temperature / {printf $NF}' <<< "${reg[MTMP]}")")
    tp=$((_tp/8))
    mt=$((_mt/8))

    # optionally get QSFP temperatures
    [[ "$opt_T" == "1" ]] && {
        _qtps=$(for q in $(seq 1 $np); do
                    i=$(dtoh $((q+63)))
                    echo "$q" "$(get_reg MTMP \
                                    "${add_idx:+$add_idx,}sensor_index=0x$i" |\
                                 awk '/^temperature / {print $NF}')" &
                done)
        while read -r q t; do
            qt[$q]=$(($(htod "$t")/8))
        done <<< "$_qtps"
    }

    # fan speeds
    # get active tachos
    at_bmsz=$(htod "$(awk '/tacho_active / {printf $(NF-2)}' \
                      < <(show_reg MFCR))")
    at_bmsk=$(htob "$(awk '/tacho_active / {printf $NF}' \
                      <<< "${reg[MFCR]}")" "$at_bmsz")
    # gather fan speeds for active tachos
    for (( i=${#at_bmsk}-1; i>0; i-- )); do
        [[ ${at_bmsk:$((i-1)):1} == 1 ]] && at_idxs+="$((at_bmsz-i)) "
    done
    _fsps=$(for t in ${at_idxs:-}; do
                echo "$t" "$(get_reg MFSM "tacho=0x$(dtoh "$t")" |&
                             awk '/^rpm/ {print $NF}')" &
             done)
    while read -r t s; do
        fs[$t]=$(htod "${s:-0}")
    done <<< "$_fsps"

}

# PSUs (inventory/status/vitals)
#shellcheck disable=SC2001
psu_idxs=$(sed 's/.*psu\([0-9]\).*/\1/;t;d' <<< "${reg[MSPS]}" | sort -u)
declare -A ps
for i in $psu_idxs; do
    # get PSU status bitmasks, a lot of guessing is taking place here
    for j in 0 1; do
        _bm[$j]=$(awk -v i="$i" -v j="$j" '$0 ~ "psu"i"\\["j"\\]" {
                    gsub(/0x/,""); print $NF}' <<< "${reg[MSPS]}")
    done
    _pr=${_bm[0]:0:1}   # PSU present
    _dc=${_bm[0]: -2:1} # PSU DC status, maybe?
    _fs=${_bm[1]: -1:1} # PSU fan status
    [[ "$_pr" == 5 ]] && ps[$i.pr]="OK" || ps[$i.pr]="ERROR"
    [[ "$_fs" == 2 ]] && ps[$i.fs]="OK" || ps[$i.fs]="ERROR"
    [[ "$_fs" == 3 ]] && ps[$i.fs]="" # probably a managed switch
    [[ "$_dc" == 1 ]] && ps[$i.dc]="OK" || ps[$i.dc]="ERROR"

    # serial number
    ps[$i.sn]=$(htos "$(awk -v i="$i" '$0 ~ "psu"i && /psu.\[[4-6]\]/ {
                                       printf $NF}' <<< "${reg[MSPS]}")")
    # part number
    ps[$i.pn]=$(htos "$(awk -v i="$i" '$0 ~ "psu"i && /psu.\[1[2-5]\]/ {
                                       printf $NF}' <<< "${reg[MSPS]}")")
    # power consumption, some guessing too
    ps[$i.wt]=$(htod "$(awk -v i="$i" '$0 ~ "psu"i && /psu.\[2\]/ {
                                       gsub(/0x8/,"")
                                       printf $NF}' <<< "${reg[MSPS]}")")
    [[ ${ps[$i.wt]} == 0 ]] && ps[$i.wt]=""
done


# TODO consider interfaces counters (tx/rx) in PPCNT

# TODO consider cable information in PDDR
# idx local_port=0x[portnum],pnat=0x0,page_select=0x3,group_opcode=0x0 for PHYs


## -- output ------------------------------------------------------------------

# targeted outputs
case $out in
    inventory)
        out_kv "node_desription" "$nd"
        out_kv "part_number" "$pn"
        out_kv "serial" "$sn"
        out_kv "product_name" "$cn"
        out_kv "revision" "$rv"
        out_kv "fw_version" "$(printf "%d.%04d.%04d" "$maj" "$min" "$sub")"
        [[ "${ps[${psu_idxs:0:1}.pr]}" != "" ]] && {
            for i in $psu_idxs; do
                out_kv "psu$i.part_number"   "${ps[$i.pn]}"
                out_kv "psu$i.serial" "${ps[$i.sn]}"
            done
        }
        exit 0
        ;;

    status)
        [[ "${ps[${psu_idxs:0:1}.pr]}" != "" ]] && {
            for i in $psu_idxs; do
                out_kv "psu$i.status"  "${ps[$i.pr]}"
                out_kv "psu$i.dc"      "${ps[$i.dc]}"
                out_kv "psu$i.fan"     "${ps[$i.fs]}"
            done
        }
        out_kv "fans" "$fa"
        exit 0
        ;;


    vitals)
        out_kv "uptime (sec)" "$s_uptime"
        [[ "${ps[${psu_idxs:0:1}.pr]}" != "" ]] && {
            for i in $psu_idxs; do
                out_kv "psu$i.power (W)" "${ps[$i.wt]}"
            done
        }
        out_kv "cur.temp (C)" "${tp}"
        out_kv "max.temp (C)" "${mt}"
        [[ "$opt_T" == "1" ]] && {
            for q in $(seq 1 $np); do
                out_kv "QSFP#$(printf "%02d" "$q").temp (C)" "${qt[$q]}"
            done
        }
        for t in ${at_idxs:-}; do
            s=${fs[$t]}
            out_kv "fan#$t.speed (rpm)" $((s>10000?s/2:s))
        done
        exit 0
        ;;
esac


## full (default) output
dblsep
echo "$nd"
dblsep
out_kv "part number" "$pn"
out_kv "serial number" "$sn"
out_kv "product name" "$cn"
out_kv "revision" "$rv"
out_kv "ports" "$np"
out_kv "PSID" "$psid"
out_kv "GUID" "$guid"
out_kv "firmware version" "$(printf "%d.%04d.%04d" "$maj" "$min" "$sub")"
sep
out_kv "uptime (d-h:m:s)" "$(sec_to_dhms "$s_uptime")"
sep
[[ "${ps[${psu_idxs:0:1}.pr]}" != "" ]] && {
    for i in $psu_idxs; do
        out_kv "PSU$i status"    "${ps[$i.pr]}"
        out_kv "     P/N"        "${ps[$i.pn]}"
        out_kv "     S/N"        "${ps[$i.sn]}"
        out_kv "     DC power"   "${ps[$i.dc]}"
        out_kv "     fan status" "${ps[$i.fs]}"
        out_kv "     power (W)"  "${ps[$i.wt]}"
    done
    sep
}
out_kv "temperature (C)" "${tp}"
out_kv "max temp (C)" "${mt}"
[[ "$opt_T" == "1" ]] && {
    for q in $(seq 1 $np); do
        out_kv "QSFP#$(printf "%02d" "$q") (C) " "${qt[$q]}"
    done
}
sep

# fan status
out_kv "fan status" "$fa"
for t in ${at_idxs:-}; do
    s=${fs[$t]}
    out_kv "fan#$t (rpm)" $((s>10000?s/2:s))
done
[[ ${at_idxs:-} != "" ]] && sep

