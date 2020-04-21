#!/usr/bin/env bash
# vim: set tabstop=4 expandtab shiftwidth=4 bg=dark:
# vim: set textwidth=80:
#
#==============================================================================
# ibswinfo
#
# Gather information from unmanaged Infiniband switches
#
# Depends on: Mellanox Firmare Tools (MFT)
#             https://www.mellanox.com/products/adapter-software/firmware-tools
#
# Author    : Kilian Cavalotti <kilian@stanford.edu>
# Created   : 2020/04/20
#==============================================================================

set -e      # stop on error
set -u      # stop on uninitialized variable

## -- constants ---------------------------------------------------------------

MFT_URL="https://www.mellanox.com/products/adapter-software/firmware-tools"

# TODO; determine that
num_fans=8

## -- functions ---------------------------------------------------------------

# display error and quit
err() {
    [[ "$@" != "" ]] && echo "error: $@" >&2
    exit 1
}

# display separator
sep() {
    echo "-----------------------------------------------"
}

# display key-value
out_kv() {
    local k=$1
    local v=$2
    [[ "$v" != "" ]] && printf "%-16s | %s\n" "$k" "$v" || return 0
}

# hex to dec
htod() {
    local d=$1
    local h=$(sed 's/0x0*//' <<< $d)
    echo $((16#$h))
}

# dec to hex
dtoh() {
    local h=$1
    printf "%x\n" $h
}

# hex to string
# input:
#  0x73656372657420
#  0x6d657373616765
htos() {
    local h=$@
    local s=$(sed 's/0x\|[[:space:]]//g; s/\(..\)/\\x\1/g' <<< "$h")
    printf "%b\n" $s | tr -d \\0
}

# seconds to h:m:s
sec_to_hms() {
    local s=$1
    printf '%02d:%02d:%02d\n' $(($s/3600)) $(($s%3600/60)) $(($s%60))
}

# get register
#  $1: reg name
#  $2: indexes (optional)
get_reg() {
    local reg=$1
    local idx=${2:+--indexes "$2"}
    mlxreg -d $dev --reg_name $reg --get $idx
}


## -- arg handling ------------------------------------------------------------

## TODO separate inventory, status and vitals
## provide option to display all


## TODO set node description
## mlxreg -d $dev --reg_name SPZR --set "ndm=0x1,node_description[0]=0x666f6f6f" --indexes "swid=0x0"
## but there seems to be register size issues right now (https://github.com/Mellanox/mstflint/issues/329)

usage() {
    cat << EOU
Usage: ${0##*/} -d <device> [-T]
    -d <device>     MST device name. Run "mst status" to get the devices list
    -T              get QSFP modules temperature

EOU
    return 0
}

# defaults
dev=""
opt_T=0
optspec="hd:T"
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
    esac
done



## -- checks ------------------------------------------------------------------

# id
[ `id -u` = 0 ] || err "must run as root, aborting."

# tools
declare -A tools
tools[awk]=""
tools[sed]=""
tools[tr]=""
tools[mst]="MFT ($MFT_URL)"
tools[mlxreg]="MFT ($MFT_URL)"
tools[smpquery]="infiniband-diags"
for t in ${!tools[@]}; do
    type $t &>/dev/null || \
        err "$t not found${tools[$t]:+, please install ${tools[$t]}}"
done

# MFT version
cur=$(mst version | awk '{gsub(/,/,""); print $3}')
req="4.14.0"
[[ "$(printf '%s\n' "$req" "$cur" | sort -V | head -n1)" = "$req" ]] || \
    err "MFT version must be >= $req (current version is $cur)"


# device
[[ $dev == "" ]] && err "missing device argument"
[[ ${dev:0:8} == '/dev/mst' ]] && dev=${dev/\/dev\/mst\//}
[[ ${dev:0:3} == "SW_" ]] || err "$dev doesn't look like a switch device name"
[[ -r /dev/mst/$dev ]] || err "$dev not found in /dev/mst, is mst started?"


## -- data --------------------------------------------------------------------

# PRM registers
# cf. /usr/share/mft/prm_dbs/switch/ext/register_access_table.adb and
# https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/mellanox/mlxsw/reg.h
#
# MGIR  -  Management General Information Register
# MGPIR -  Management General Peripheral Information Register
# SPZR  -  ... node description
# MSGI  -  ... product information
# MSPS  -  ... power supplies
# MTMP  -  Management Temperature
# MTCAP -  Management Temperature Capabilities

declare -A reg
declare -A rid
reg_names="MGIR MGPIR MSGI MSPS SPZR MTMP MTCAP"
rid[SPZR]="swid=0x0"
rid[MTMP]="sensor_index=0x0"
# gather register values in parallel
_regs=$(for r in $reg_names; do
            echo $r $(get_reg $r ${rid[$r]:-} |& paste -s -d '@') &
        done)
while read -r r v; do
    o=${v//@/$'\n'}
    [[ "$o" =~ ^-E- ]] && err "${o/-E-/}"
    reg[$r]=$o
done <<< "$_regs"

# uptime
h_uptime=$(awk '/uptime/ {print $NF}' <<< "${reg[MGIR]}")
s_uptime=$(htod $h_uptime)

# part/serial number
pn=$(htos $(awk '/part_number/   {printf $NF}' <<< "${reg[MSGI]}"))
sn=$(htos $(awk '/serial_number/ {printf $NF}' <<< "${reg[MSGI]}"))
cn=$(htos $(awk '/product_name/  {printf $NF}' <<< "${reg[MSGI]}"))
rv=$(htos $(awk '/revision/      {printf $NF}' <<< "${reg[MSGI]}"))

# PSID
psid=$(htos $(awk '/^psid/       {printf $NF}' <<< "${reg[MGIR]}"))

# version
maj=$(htod $(awk '/extended_major/ {printf $NF}' <<< "${reg[MGIR]}"))
min=$(htod $(awk '/extended_minor/ {printf $NF}' <<< "${reg[MGIR]}"))
sub=$(htod $(awk '/extended_sub_minor/ {printf $NF}' <<< "${reg[MGIR]}"))

# node description
nd=$(htos $(awk '/node_description/ {print $NF}' <<< "${reg[SPZR]}"))
guid=$(awk '/node_guid/ {gsub(/0x/,"",$NF); g=g$NF} END {print "0x"g}' \
      <<< "${reg[SPZR]}")

# get number of ports
_nm=$(awk '/num_of_modules/ {printf $NF}' <<< "${reg[MGPIR]}")
if [[ $_nm =~ ^0x ]]; then
    nm=$(htod $_nm)
else # try to get that from the SM
    _s=$(smpquery NI -G $guid | awk -F.  '/NumPorts/ {print $NF}')
    nm=$((_s-1))
fi


# PSUs
psu_idx=$(grep "psu" <<< "${reg[MSPS]}" | sed 's/.*psu\([0-9]\).*/\1/' | sort -u)
declare -A ps
# TODO actually check status bits
for i in $psu_idx; do
    #_ac=$(awk -v i=$i '$0 ~ "psu"i && /psu.\[0\]/ {
    #                        printf substr($NF,length($NF),1)
    #                   }' <<< "${reg[MSPS]}")
    #[[ "$_ac" == 0 ]] && ps[$i.ac]="OK" || ps[$i.ac]="ERR"
    _dc=$(awk -v i=$i '$0 ~ "psu"i && /psu.\[0\]/ {
                            printf substr($NF,length($NF)-1,1)
                       }' <<< "${reg[MSPS]}")
    [[ "$_dc" == 1 ]] && ps[$i.dc]="OK" || ps[$i.dc]="ERR"
    _fs=$(awk -v i=$i '$0 ~ "psu"i && /psu.\[1\]/ {
                            printf substr($NF,length($NF),1)
                       }' <<< "${reg[MSPS]}")
    [[ "$_fs" == 2 ]] && ps[$i.fs]="OK" || ps[$i.fs]="ERR"
    ps[$i.sn]=$(htos $(awk -v i=$i '$0 ~ "psu"i && /psu.\[[4-6]\]/ {
                                    printf $NF}' <<< "${reg[MSPS]}"))
    ps[$i.pn]=$(htos $(awk -v i=$i '$0 ~ "psu"i && /psu.\[1[2-5]\]/ {
                                    printf $NF}' <<< "${reg[MSPS]}"))
done


# temperatures
_tp=$(htod $(awk '/^temperature /    {printf $NF}' <<< "${reg[MTMP]}"))
_mt=$(htod $(awk '/max_temperature / {printf $NF}' <<< "${reg[MTMP]}"))
tp=$((_tp/8))
mt=$((_mt/8))

# optionally get QSFP temperatures
[[ "$opt_T" == "1" ]] && {
    # gather module temperatures in parallel
    _mtps=$(for m in $(seq 1 $nm); do
                echo $m $(get_reg MTMP "sensor_index=0x$(dtoh $((m+63)))" |\
                          awk '/^temperature / {print $NF}') &
            done)
    while read -r m t; do
        mt[$m]=$(($(htod $t)/8))
    done <<< "$_mtps"
}


# fans
# gather fan speeds in parallel
_fsps=$(for t in $(seq 1 $num_fans); do
            echo $t $(get_reg MFSM "tacho=0x$(dtoh $t)" |
                awk '/^rpm/ {print $NF}') &
         done)
while read -r t s; do
    fs[$t]=$(htod $s)
done <<< "$_fsps"



# alerts over/under limit #FORE
# speeds #MFSM

# ? interfaces (tx/rx) #PPCNT

# ? cables #PDDR
# idx local_port=0x[portnum],pnat=0x0,page_select=0x3,group_opcode=0x0 for PHYs


## -- display -----------------------------------------------------------------
sep
out_kv "node description" "$nd"
sep
out_kv "P/N" "$pn"
out_kv "S/N" "$sn"
out_kv "codename (rev)" "$cn ($rv)"
out_kv "ports" "$nm"
out_kv "PSID" "$psid"
out_kv "GUID" "$guid"
out_kv "fw version" "$(printf "%d.%04d.%04d" $maj $min $sub)"
sep
out_kv "uptime [h:m:s]" "$(sec_to_hms $s_uptime)"
sep
[[ "${ps[${psu_idx:0:1}.pn]}" != "" ]] && {
    for i in $psu_idx; do
        [[ "$i" != "${psu_idx:0:1}" ]] && echo
        out_kv "PSU$i P/N" "${ps[$i.pn]}"
        out_kv "PSU$i S/N" "${ps[$i.sn]}"
        #out_kv "PSU$i AC power" "${ps[$i.ac]}"
        out_kv "PSU$i DC power" "${ps[$i.dc]}"
        out_kv "PSU$i fan status" "${ps[$i.fs]}"
    done
    sep
}
out_kv "ASIC temp [C]" "${tp}"
out_kv "ASIC max temp" "${mt}"
[[ "$opt_T" == "1" ]] && {
    for m in $(seq 1 $nm); do
        out_kv "Port$(printf "%02d" $m) temp" "${mt[$m]}"
    done
}
sep
for t in $(seq 1 $num_fans); do
    out_kv "FAN#$(printf "%02d" $t) speed" "${fs[$t]}"
done
sep
