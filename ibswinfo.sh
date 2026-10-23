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
MAX_JOBS=8


## -- functions ---------------------------------------------------------------

# display error and quit
err() {
    [[ "$*" != "" ]] && echo "error: $*" >&2
    exit 1
}

# display warning and continue
warn() {
    [[ ! -t 2 ]] || printf '\r\033[K' >&2
    [[ "$*" != "" ]] && echo "warning: $*" >&2
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
    [[ "$v" != "" ]] && \
        printf "%-*s %s %s\n" "${kv_width:-18}" "$k" "$s" "$v" || return 0
}

# Consume one line per finished query (an empty line means a skipped port).
# Keep progress on the terminal's stderr, never in the collected records.
gather_progress() {
    local label=$1 total=$2 completed=0 line
    [[ ! -t 2 ]] || printf '\r\033[K%s: %d/%d' "$label" 0 "$total" >&2
    while IFS= read -r line; do
        completed=$((completed+1))
        [[ ! -t 2 ]] || \
            printf '\r\033[K%s: %d/%d' "$label" "$completed" "$total" >&2
        [[ -z "$line" ]] || printf '%s\n' "$line"
    done
    [[ ! -t 2 ]] || printf '\n' >&2
}

# hex to dec
htod() {
    local d=${1:-0}
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
    local h=${1:-0}
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

# Emit a complete tab-separated row in one write, so workers do not mix.
cable_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

# decode one port's PDDR module page
cable_record() {
    local port=$1 field value type ident length
    local -A cable=()
    local -a identity=()
    local -a types=(unknown active optical passive unplugged twisted-pair
                    CPO OE ELS)
    local -a forms=(QSFP28 QSFP+ SFP28/SFP+ QSA backplane SFP-DD QSFP-DD
                    QSFP-CMIS OSFP C2C DSFP QSFP-split CPO OE ELS)

    while read -r field _ value; do
        [[ "$value" =~ ^0x[[:xdigit:]]{1,8}$ ]] || continue
        cable[$field]=$((value))
    done <<< "${reg[PDDR]}"

    type=${cable[cable_type]:-}
    [[ -n "$type" ]] || {
        cable_row "port$port" unavailable
        warn "port $port: PDDR did not return cable_type"
        return 0
    }
    if [[ "$type" == 4 ]]; then
        cable_row "port$port" unplugged
        return 0
    fi

    for field in vendor_name vendor_pn vendor_sn; do
        value=$(mstr_dec "^${field}[[]" PDDR)
        value=$(tr '\t\r\n' '   ' <<< "$value" | sed 's/[[:space:]]*$//')
        identity+=("${value:-unknown}")
    done

    ident=${cable[cable_identifier]:-}
    value=unknown
    [[ -n "$ident" ]] && value=${forms[$ident]:-unknown}
    identity+=("$value")

    length=${cable[cable_length]:-0}
    value=""
    if [[ "$length" -gt 0 && -n "$ident" && -n "${forms[$ident]:-}" ]]; then
        case $ident in
            5|6|7|8|10) # CMIS: low six bits * encoded multiplier
                case $((length >> 6)) in
                    0) printf -v value '%d.%d' "$((length % 64 / 10))" \
                                               "$((length % 64 % 10))" ;;
                    1) value=$((length % 64)) ;;
                    2) value=$((length % 64 * 10)) ;;
                    3) value=$((length % 64 * 100)) ;;
                esac
                [[ $((length % 64)) == 0 ]] && value=""
                ;;
            *) value=$length ;;
        esac
    fi
    cable_row "port$port" ok "${types[$type]:-unknown}" \
        "${identity[@]}" "$value"
}

# One local-port worker; register buffers are private to the subshell.
get_cable() (
    local local_port=$1 port idx width r
    local -A reg=()
    idx="local_port=0x$(dtoh "$local_port")"
    for r in PMLP PLIB; do
        if ! reg[$r]=$(get_reg "$r" "$idx") || [[ "${reg[$r]}" =~ -E- ]]; then
            cable_row "local_port$local_port" unavailable
            warn "local port $local_port: ${reg[$r]}"
            return 0
        fi
        if [[ "$r" == PMLP ]]; then
            width=$(awk '$1 == "width" {print $NF}' <<< "${reg[PMLP]}")
            [[ "$width" =~ ^0x[[:xdigit:]]{1,8}$ ]] || {
                cable_row "local_port$local_port" unavailable
                warn "local port $local_port: missing PMLP width"
                return 0
            }
            [[ $((width)) == 0 ]] && { echo; return 0; }
        fi
    done

    port=$(awk '$1 == "ib_port" {print $NF}' <<< "${reg[PLIB]}")
    if [[ ! "$port" =~ ^0x[[:xdigit:]]{1,8}$ ]] || \
       [[ $((port)) -lt 1 || $((port)) -gt 255 ]]; then
        cable_row "local_port$local_port" unavailable
        warn "local port $local_port: invalid IB port mapping"
        return 0
    fi
    port=$((port))
    idx="local_port=0x$(dtoh "$port"),pnat=0x1,page_select=0x3"
    if reg[PDDR]=$(get_reg PDDR "$idx") && [[ ! "${reg[PDDR]}" =~ -E- ]]; then
        cable_record "$port"
    else
        cable_row "port$port" unavailable
        warn "port $port: ${reg[PDDR]}"
    fi
)

# The same collected rows feed targeted output and single-line cable summaries.
show_cables() {
    local port status type vendor pn sn form length field value length_column
    local -A widths=([vendor]=0 [pn]=0 [sn]=0 [length]=0 [form]=0)
    while IFS=$'\t' read -r port status type vendor pn sn form length; do
        [[ "$status" == ok ]] || continue
        length+=${length:+m}
        sn="($sn)"
        for field in vendor pn sn length form; do
            value=${!field}
            (( ${#value} <= widths[$field] )) || widths[$field]=${#value}
        done
    done <<< "$_cables"
    while IFS=$'\t' read -r port status type vendor pn sn form length; do
        [[ -n "$port" ]] || continue
        if [[ -n "$out" ]]; then
            if [[ "$status" != ok ]]; then
                out_kv "$port.cable.status" "$status"
                continue
            fi
            out_kv "$port.cable.type"        "$type"
            out_kv "$port.cable.vendor"      "$vendor"
            out_kv "$port.cable.part_number" "$pn"
            out_kv "$port.cable.serial"      "$sn"
            out_kv "$port.cable.form_factor" "$form"
            out_kv "$port.cable.length_m" "$length"
        else
            if [[ "$port" == local_port* ]]; then
                out_kv "local#${port#local_port} cable" "$status"
            elif [[ "$status" != ok ]]; then
                out_kv "port#${port#port} cable" "$status"
            else
                length+=${length:+m}
                length_column=""
                [[ "${widths[length]}" == 0 ]] || printf -v length_column \
                    '%-*s ' "${widths[length]}" "$length"
                printf -v value '%-*s %-*s %-*s %s%-*s %s' \
                    "${widths[vendor]}" "$vendor" "${widths[pn]}" "$pn" \
                    "${widths[sn]}" "($sn)" "$length_column" \
                    "${widths[form]}" "$form" "$type"
                out_kv "port#${port#port} cable" "$value"
            fi
        fi
    done <<< "$_cables"
}

# Module temperature worker, using the same sensor indexes as -T.
get_module_temp() {
    local q=$1 data value idx
    idx="sensor_index=0x$(dtoh "$((q+63))")${add_idx:+,$add_idx}"
    idx+=${add_tmp_idx:+,$add_tmp_idx}
    value=unknown
    if data=$(get_reg MTMP "$idx") && [[ ! "$data" =~ -E- ]]; then
        value=$(awk '$1 == "temperature" {print $NF}' <<< "$data")
        if [[ "$value" =~ ^0x[[:xdigit:]]{1,8}$ ]] && \
           [[ $((value)) -le 65535 ]]; then
            value=$((value))
            [[ $value -ge 32768 ]] && value=$((value-65536))
            value=$((value/8))
        else
            value=unknown
        fi
    fi
    [[ "$value" == unknown ]] && warn "module $q: temperature unavailable"
    printf '%s %s\n' "$q" "$value"
}


# Convert IB data units (four octets) without overflowing Bash's signed integer
# or rounding through awk's floating point. Only single digits enter arithmetic.
data_to_bytes() {
    local value=$1 result="" carry=0 i digit
    for (( i=${#value}-1; i>=0; i-- )); do
        digit=$(( ${value:i:1} * 4 + carry ))
        result="$((digit % 10))$result"
        carry=$((digit / 10))
    done
    printf '%s%s\n' "${carry/#0/}" "$result"
}

# Subtract decimal strings before converting the small delta to a rate.
decimal_delta() {
    local a=$1 b=$2 result="" borrow=0 i digit
    local LC_ALL=C
    while (( ${#b} < ${#a} )); do b="0$b"; done
    (( ${#a} == ${#b} )) && [[ "$a" > "$b" || "$a" == "$b" ]] || return 1
    for (( i=${#a}-1; i>=0; i-- )); do
        digit=$(( ${a:i:1} - ${b:i:1} - borrow ))
        borrow=0
        (( digit >= 0 )) || { digit=$((digit+10)); borrow=1; }
        result="$digit$result"
    done
    result=${result#"${result%%[!0]*}"}
    printf '%s\n' "${result:-0}"
}

counter_rates() {
    local first=$1 second=$2 elapsed=$3 port status i delta unit
    local -a before after rates
    read -r port status before[0] before[1] before[2] before[3] <<< "$first"
    read -r port status after[0] after[1] after[2] after[3] <<< "$second"
    for i in 0 1 2 3; do
        delta=$(decimal_delta "${after[i]}" "${before[i]}") || return 1
        [[ $i -lt 2 ]] && unit=B/s || unit=pkts/s
        rates[i]=$(LC_ALL=C awk -v d="$delta" -v ns="$elapsed" \
                                -v u="$unit" 'BEGIN {
            split("k M G T P E Z", prefix, " "); v=d*1e9/ns; n=0
            while (v>=999.95 && n<7) {v/=1000; n++}
            printf "%.1f %*s", v, length(u)+1, (n ? prefix[n] : "") u
        }')
    done
    printf '%s\tok\t%s\t%s\t%s\t%s\n' "$port" "${rates[@]}"
}

# Read just the four extended traffic counters as decimal strings.
counter_record() {
    local port=$1 data=$2 field value
    local LC_ALL=C
    local -A values=()
    [[ "$data" == *'# Port extended counters:'* ]] || return 1
    while IFS=: read -r field value; do
        case $field in
            PortXmitData|PortRcvData|PortXmitPkts|PortRcvPkts)
                value=${value//./}
                value=${value//[[:space:]]/}
                [[ "$value" =~ ^(0|[1-9][0-9]{0,19})$ ]] || return 1
                if [[ ${#value} == 20 && \
                      "$value" > 18446744073709551615 ]]; then
                    return 1
                fi
                [[ -z "${values[$field]+x}" ]] || return 1
                values[$field]=$value
                ;;
        esac
    done <<< "$data"
    [[ ${#values[@]} == 4 ]] || return 1
    printf 'port%s\tok\t%s\t%s\t%s\t%s\n' "$port" \
        "$(data_to_bytes "${values[PortXmitData]}")" \
        "$(data_to_bytes "${values[PortRcvData]}")" \
        "${values[PortXmitPkts]}" "${values[PortRcvPkts]}"
}

# A mapped local port may have a different IB port number, or be unmapped.
get_port_counters() {
    local p=$1 idx data width port first second start end elapsed
    idx="local_port=0x$(dtoh "$p")"
    data=$(get_reg PMLP "$idx") && [[ "$data" != *-E-* ]] || {
        warn "local port $p: PMLP unavailable: $data"; return 1;
    }
    width=$(awk '$1 == "width" {print $NF}' <<< "$data")
    [[ "$width" =~ ^0x[[:xdigit:]]{1,8}$ ]] || return 1
    [[ $((width)) == 0 ]] && return 0
    data=$(get_reg PLIB "$idx") && [[ "$data" != *-E-* ]] || {
        warn "local port $p: PLIB unavailable: $data"; return 1;
    }
    port=$(awk '$1 == "ib_port" {print $NF}' <<< "$data")
    [[ "$port" =~ ^0x[[:xdigit:]]{1,8}$ ]] || return 1
    port=$((port))
    [[ "$port" -ge 1 && "$port" -le 254 ]] || return 1
    start=$(date +%s%N)
    if data=$(LC_ALL=C perfquery ${counter_route[@]+"${counter_route[@]}"} \
                               -x "$counter_lid" "$port" 2>&1) && \
       first=$(counter_record "$port" "$data"); then
        if [[ "$out" == vitals ]]; then
            printf '%s\n' "$first"
            return 0
        fi
        end=$(date +%s%N)
        start=$(((start+end)/2))
        sleep 1
        end=$(date +%s%N)
        if data=$(LC_ALL=C perfquery ${counter_route[@]+"${counter_route[@]}"} \
                                   -x "$counter_lid" "$port" 2>&1) && \
           second=$(counter_record "$port" "$data"); then
            elapsed=$(((end+$(date +%s%N))/2-start))
            if (( elapsed > 0 )) && \
               counter_rates "$first" "$second" "$elapsed"; then
                return 0
            fi
            data="counter decreased or invalid sampling interval"
        fi
    fi
    warn "IB port $port: extended counters unavailable: ${data##*$'\n'}"
    printf 'port%s\tunavailable\t-\t-\t-\t-\n' "$port"
}

show_counters() {
    local port status tx rx txp rxp label
    while IFS=$'\t' read -r port status tx rx txp rxp; do
        [[ -n "$port" ]] || continue
        label="port#${port#port} traffic"
        [[ "$port" != local_port* ]] || label="local port#${port#local_port}"
        if [[ -n "$out" ]]; then
            if [[ "$status" != ok ]]; then
                out_kv "$port.status" "$status"
            else
                out_kv "$port.tx_bytes" "$tx"
                out_kv "$port.rx_bytes" "$rx"
                out_kv "$port.tx_packets" "$txp"
                out_kv "$port.rx_packets" "$rxp"
            fi
        elif [[ "$status" != ok ]]; then
            out_kv "$label" "$status"
        else
            tx=$(printf 'TX %11s %14s' "$tx" "$txp")
            rx=$(printf 'RX %11s %14s' "$rx" "$rxp")
            out_kv "$label" "$tx"
            out_kv ""       "$rx"
        fi
    done <<< "$_counters"
}

## -- arg handling ------------------------------------------------------------

usage() {
    cat << EOU
Usage: ${0##*/} -d <device> [-T] [-C] [-P] [-o <$outputs>] [-S <description>]

  global options:
    -d <device>             MST device path ("mst status" shows devices list)
                            or LID (eg. "-d lid-44")
  get info:
    -o <output_category>    Only display $outputs information
    -T                      get transceiver modules temperature
    -C                      get cable information
    -P                      get port traffic counters

  set info:
    -S <description>        set device description ($MAX_ND_LEN bytes max.)
    -y                      skip confirmation

EOU
    return 0
}

# defaults
outputs="inventory|vitals|status"
out=""
dev=""
desc=""
opt_S=0
opt_T=0
opt_C=0
opt_P=0
opt_y=0
query_ret=0
optspec="hd:TCPo:S:y"
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
        C)
            opt_C=1
            ;;
        P)
            opt_P=1
            ;;
        o)
            out=${OPTARG}
            [[ ! "$out" =~ ^($outputs)$ ]] && {
                err "unknown output requested, not in $outputs"
            }
            ;;
        S)
            desc=${OPTARG}
            # Count bytes, not locale-dependent characters.
            desc_len=$(LC_ALL=C printf '%s' "$desc" | wc -c)
            [[ "$desc_len" -gt "$MAX_ND_LEN" ]] && {
                err "description string > $MAX_ND_LEN bytes"
            }
            opt_S=1
            ;;
	y)
            opt_y=1
	    ;;
    esac
done

# drop -T/-P for inventory/status outputs, -C for vitals/status outputs
[[ "$out" =~ inventory|status ]] && opt_T=0 opt_P=0
[[ "$out" =~ vitals|status ]] && opt_C=0

# check conflicting options
[[ "$opt_S" == 1 ]] && \
    [[ -n "$out" || "$opt_T" -eq 1 || "$opt_C" -eq 1 || "$opt_P" -eq 1 ]] && {
    err "conflicting options, can't get and set info at the same time"
}


## -- checks ------------------------------------------------------------------

# id
[[ "$(id -u)" == 0 ]] || err "must run as root, aborting."

[[ -n "$dev" ]] || err "missing device argument"


## -- node description mgmt ---------------------------------------------------

# Use SMP independently of MFT register access. An empty name clears the field.
[[ "$opt_S" == 1 ]] && {
    # locate the helper alongside this script
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    helper="$script_dir/ibsetnd"
    [[ -x "$helper" ]] || \
        err "ibsetnd not found next to ibswinfo.sh; build it with make"

    # get current node description
    cur_nd=$("$helper" "$dev") || \
        err "could not read current node description"

    printf 'Device: %s\n'                       "$dev"
    printf '  Current node description: %s\n'  "$cur_nd"
    printf '  Set node description to : %s\n'  "$desc"

    [[ "$opt_y" == 0 ]] && {
        read -p ">> Confirm? (y/N) " -n 1 -r || exit 1
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    }

    # set and verify the new description
    printf 'Setting new node description... '
    "$helper" "$dev" "$desc" >/dev/null || \
        err "node description update failed"

    echo "done!"
    exit 0
}


## -- information query checks -----------------------------------------------

# tools and dependencies
declare -A tools
tools[awk]=""
tools[sed]=""
tools[tr]="coreutils"
tools[paste]="coreutils"
tools[mst]="MFT ($MFT_URL)"
tools[mlxreg]="MFT ($MFT_URL)"
tools[smpquery]="infiniband-diags"
[[ "$opt_P" == 1 ]] && tools[perfquery]="infiniband-diags"
for t in "${!tools[@]}"; do
    type "$t" &>/dev/null || \
        err "$t not found${tools[$t]:+, please install ${tools[$t]}}"
done

# MFT version
mft_cur=$(mst version | awk '{gsub(/,/,""); print $3}' | cut -d- -f1)
mft_req="4.18.0"      # minimum required MFT version
mft_max="4.31.0"      # highest MFT version tested
mft_cur=$(mst version | awk '{gsub(/,/,""); print $3}' | cut -d- -f1)
[[ ${mft_cur//./} -lt ${mft_req//./} ]] && \
    err "MFT version must be >= $mft_req (current version is $mft_cur)"
[[ ${mft_cur//./} -gt ${mft_max//./} ]] && \
    warn "Not tested with MFT version $mft_cur, YMMV"


# device
[[ $dev == "" ]] && err "missing device argument"
[[ ${dev:0:4} != "lid-" ]] && {
    [[ ${dev:0:8} == '/dev/mst' ]] && dev=${dev/\/dev\/mst\//}
    [[ ${dev:0:3} == "SW_" ]] || err "$dev doesn't look like a switch device name"
    [[ -r /dev/mst/$dev ]] || err "$dev not found in /dev/mst, is mst started?"
}


# Preserve the optional MFT ,CA,port route when calling perfquery.
[[ "$opt_P" == 1 ]] && {
    counter_target=${dev%%,*}
    counter_target=${counter_target#SW_}
    counter_target=${counter_target#*_lid-}
    counter_target=${counter_target#lid-}
    [[ "$counter_target" =~ ^(0x[[:xdigit:]]{1,4}|[0-9]{1,5})$ ]] || \
        err "counters require lid-N or SW_..._lid-N, optionally with ,CA,port"
    if [[ "$counter_target" == 0x* ]]; then
        counter_lid=$((counter_target))
    else
        counter_lid=$((10#$counter_target))
    fi
    [[ "$counter_lid" -ge 1 && "$counter_lid" -le 49151 ]] || \
        err "invalid counter LID"
    counter_route=()
    if [[ "$dev" == *,* ]]; then
        route=${dev#*,}
        ca=${route%%,*}
        [[ "$ca" =~ ^[a-zA-Z0-9_.-]+$ ]] || err "invalid counter CA"
        counter_route+=(-C "$ca")
        if [[ "$route" == *,* ]]; then
            ca_port=${route#*,}
            [[ "$ca_port" =~ ^[0-9]{1,3}$ ]] || err "invalid counter CA port"
            ca_port=$((10#$ca_port))
            [[ "$ca_port" -ge 1 && "$ca_port" -le 255 ]] || \
                err "invalid counter CA port"
            counter_route+=(-P "$ca_port")
        fi
    fi
}


## -- initiate registers ------------------------------------------------------

# PRM registers
# cf. mft/prm_dbs/switch/ext/register_access_table.adb
# and kernel:drivers/net/ethernet/mellanox/mlxsw/reg.h
#
# MGIR  -  Management General Information Register
# MGPIR -  Management General Peripheral Information Register
# MSGI  -  Misc System General Information Register
# MSCI  -  ...? CPLD information
# MSPS  -  Misc System Power Supply Register
# MTMP  -  Management Temperature
# MTCAP -  Management Temperature Capabilities
# MFCR  -  Management Fan Control Register
# FORE  -  Fan Out of Range Event Register
# SPZR  -  ...? node description
# PMLP  -  Ports Module to Local Port Register
# PLIB  -  ...? local to IB port mapping
# PDDR  -  Port Diagnostics Database Register

# gather register values
declare -A reg
declare -A rid
# select register to read, depending on what output is required
case $out in
    inventory)
        reg_names="MGIR MSGI MSCI SPZR MSPS"
        ;;
    status)
        reg_names="MGIR MGPIR MSPS MTMP MTCAP MFCR FORE"
        ;;
    vitals)
        reg_names="MGIR MGPIR MSPS MTMP MTCAP MFCR"
        ;;
    *)
        reg_names="MGIR MGPIR MSGI MSCI MSPS SPZR MTMP MTCAP MFCR FORE"
        ;;
esac
# some registers need an index
# and that depends on the version of MFT we're using
add_idx="" add_tmp_idx=""
[[ ${mft_cur//./} -gt 4150 ]] && add_idx="slot_index=0x0"
[[ ${mft_cur//./} -gt 4190 && \
   ${mft_cur//./} -lt 4210 ]] && rid[MGIR]="module_base=0x0"
[[ ${mft_cur//./} -ge 4230 ]] && rid[SPZR]="router_entity=0x0,"
[[ ${mft_cur//./} -ge 4301 ]] && add_tmp_idx="asic_index=0x0,ig=0x0,i=0x0,"
rid[MGPIR]+="slot_index=0x0"
rid[MSCI]+="index=0x0" # handle main CPLD only
rid[SPZR]+="swid=0x0"
rid[MTMP]+="sensor_index=0x0${add_idx:+,$add_idx}${add_tmp_idx:+,$add_tmp_idx}"
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


## -- local ports ------------------------------------------------------------

# MGIR is the local-port capacity; PMLP identifies mapped ports.
[[ "$opt_C" == 1 || "$opt_P" == 1 ]] && {
    ports=$(awk '$1 == "num_ports" {print $NF}' <<< "${reg[MGIR]}")
    [[ "$ports" =~ ^0x[[:xdigit:]]{1,8}$ ]] || \
        err "could not determine local-port capacity"
    ports=$((ports))
    [[ "$ports" -ge 1 && "$ports" -le 255 ]] || \
        err "unsupported local-port capacity: $ports"
}


## -- cable inventory --------------------------------------------------------

[[ "$opt_C" == 1 ]] && {
    # Batch workers to overlap MAD requests, without querying all ports at once.
    _cables=$({ for (( p=1; p<=ports; p++ )); do
                  get_cable "$p" &
                  (( p % MAX_JOBS == 0 )) && wait
              done
               wait; } | gather_progress "Reading cables" "$ports")
    _cables=$(sort -t $'\t' -k1,1V <<< "$_cables")
    [[ "$_cables" == *$'\tunavailable\t'* ]] && query_ret=1
}


## -- port counters ----------------------------------------------------------

[[ "$opt_P" == 1 ]] && {
    _counters=$({ for (( p=1; p<=ports; p++ )); do
                    (
                        if row=$(get_port_counters "$p"); then
                            printf '%s\n' "$row"
                        else
                            warn "local port $p: counters unavailable"
                            printf 'local_port%s\tunavailable\t-\t-\t-\t-\n' \
                                "$p"
                        fi
                    ) &
                    (( p % MAX_JOBS == 0 )) && wait
                done
                  wait; } | gather_progress "Counters (local ports)" "$ports")
    [[ -n "$_counters" ]] || \
        { warn "no mapped counter ports found"; query_ret=1; }
    _counters=$(sort -t $'\t' -k1,1V <<< "$_counters")
    duplicates=$(awk -F '\t' 'seen[$1]++ {print $1}' <<< "$_counters")
    [[ -z "$duplicates" ]] || err "duplicate counter port mappings: $duplicates"
    [[ "$_counters" != *$'\tunavailable\t'* ]] || query_ret=1
}


## -- data gathering ----------------------------------------------------------

# extract data from register values
# inventory
[[ ! "$out" =~ status|vitals ]] && {
    # part/serial number
    pn=$(mstr_dec "part_number"   MSGI)
    sn=$(mstr_dec "serial_number" MSGI)
    cn=$(mstr_dec "roduct_name"   MSGI)
    rv=$(htos "$(awk '/^revision /  {printf $NF}' <<< "${reg[MSGI]}")")

    # PSID
    psid=$(mstr_dec '^psid' MGIR)

    # FW version
    maj=$(htod "$(awk '/^extended_major / {printf $NF}' <<< "${reg[MGIR]}")")
    min=$(htod "$(awk '/^extended_minor / {printf $NF}' <<< "${reg[MGIR]}")")
    sub=$(htod "$(awk '/^extended_sub_minor / {printf $NF}' <<< "${reg[MGIR]}")")

    # CPLD version
    cpld=$(htod "$(awk '/^version / {printf $NF}' <<< "${reg[MSCI]}")")

    # node description
    #shellcheck disable=SC2046
    nd=$(mstr_dec "node_description" SPZR)
    guid=$(awk '/^node_guid/ {gsub(/0x/,"",$NF); g=g$NF} END {print "0x"g}' \
          <<< "${reg[SPZR]}")
}

# status
[[ ! "$out" =~ inventory|vitals ]] && {
    # fan under/over limit alerts
    fu=$(htod "$(awk '/^fan_under_limit / {printf $NF}' <<< "${reg[FORE]}")")
    fo=$(htod "$(awk '/^fan_over_limit / {printf $NF}'  <<< "${reg[FORE]}")")
    # extension bitmasks (msb) for the tachos beyond the first bitmask width
    f_bmsz=$(awk '/^fan_under_limit / {printf $(NF-2)}' < <(show_reg FORE))
    fu_msb=$(htod "$(awk '/^fan_under_limit_msb / {printf $NF}' <<< "${reg[FORE]}")")
    fo_msb=$(htod "$(awk '/^fan_over_limit_msb / {printf $NF}' <<< "${reg[FORE]}")")
    fu=$((fu | (fu_msb << f_bmsz)))
    fo=$((fo | (fo_msb << f_bmsz)))
    [[ $((fo+fu)) == 0 ]] && fa="OK" || fa="ERROR"
    # out of range tachos, same ids as fan speeds
    fst=() fal=""
    for (( t=0; (fu|fo) >> t; t++ )); do
        (( (fu >> t) & 1 )) && fst[t]="under limit"
        (( (fo >> t) & 1 )) && fst[t]+="${fst[t]:+ and }over limit"
    done
    for t in ${fst[@]+"${!fst[@]}"}; do
        fal+="${fal:+, }fan#$t ${fst[t]}"
    done
}

# vitals and status
[[ ! $out =~ inventory ]] && {
    # number of modules
    nm=$(htod "$(awk '/num_of_modules_per_system / {printf $NF}' <<< "${reg[MGPIR]}")")
    [[ $nm == 0 ]] && \
        nm=$(htod "$(awk '/num_of_modules / {printf $NF}' <<< "${reg[MGPIR]}")")
    # max number of ports
    np=$(htod "$(awk '/num_ports / {printf $NF}' <<< "${reg[MGIR]}")")

    # uptime
    h_uptime=$(awk '/^uptime / {print $NF}' <<< "${reg[MGIR]}")
    s_uptime=$(htod "$h_uptime")

    # temperatures
    _tp=$(htod "$(awk '/^temperature /    {printf $NF}' <<< "${reg[MTMP]}")")
    _mt=$(htod "$(awk '/^max_temperature / {printf $NF}' <<< "${reg[MTMP]}")")
    _twl=$(htod "$(awk '/^temperature_threshold_lo / {printf $NF}' <<< "${reg[MTMP]}")")
    _twh=$(htod "$(awk '/^temperature_threshold_hi / {printf $NF}' <<< "${reg[MTMP]}")")
    tp=$((_tp/8))
    mt=$((_mt/8))
    twl=$((_twl/8)) twh=$((_twh/8))

    # optionally get modules temperature
    [[ "$opt_T" == "1" ]] && {
        [[ "$nm" -ge 0 && "$nm" -le 255 ]] || \
            err "could not determine module count"
        _qtps=$({ for q in $(seq 1 "$nm"); do
                    get_module_temp "$q" &
                    (( q % MAX_JOBS == 0 )) && wait
                done
                 wait; } | gather_progress "Module temperatures" "$nm")
        while read -r q t; do
            qt[q]=$t
            [[ "$t" == unknown ]] && query_ret=1
        done <<< "$_qtps"
    }

    # fan speeds
    # first tachos bitmask (lsb)
    atlsb_bmsz=$(awk '/^tacho_active / {printf $(NF-2)}' < <(show_reg MFCR))
    atlsb_bmsk=$(htob "$(awk '/^tacho_active / {printf $NF}' \
                         <<< "${reg[MFCR]}")" "$atlsb_bmsz")
    # second tachos bitmask (msb)
    atmsb_bmsz=$(awk '/^tacho_active_msb / {printf $(NF-2)}' < <(show_reg MFCR))
    atmsb_bmsk=$(htob "$(awk '/^tacho_active_msb / {printf $NF}' \
                         <<< "${reg[MFCR]}")" "$atmsb_bmsz")
    at_bmsz=$((atlsb_bmsz+atmsb_bmsz))
    at_bmsk="${atmsb_bmsk}${atlsb_bmsk}"

    # gather fan speeds for active tachos
    for (( i=${#at_bmsk}-1; i>0; i-- )); do
        [[ ${at_bmsk:$((i-1)):1} == 1 ]] && at_idxs+="$((at_bmsz-i)) "
    done
    _fsps=$(for t in ${at_idxs:-}; do
                echo "$t" "$(get_reg MFSM "tacho=0x$(dtoh "$t")" |&
                             awk '/^rpm / {print $NF}')" &
             done)
    while read -r t s; do
        fs[t]=$(htod "${s:-0}")
    done <<< "$_fsps"
}

# PSUs (inventory/status/vitals)
#shellcheck disable=SC2001
psu_idxs=$(sed 's/.*psu\([0-9]\).*/\1/;t;d' <<< "${reg[MSPS]}" | sort -u)
declare -A ps
for i in $psu_idxs; do
    # get PSU status bitmasks, a lot of guessing is taking place here
    for j in 0 1; do
        _bm[j]=$(awk -v i="$i" -v j="$j" '$0 ~ "psu"i"\\["j"\\]" {
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


# Traffic counters use perfquery: PPCNT's extended group can return all zeros.


## -- output ------------------------------------------------------------------

# targeted outputs
case $out in
    inventory)
        [[ "$opt_C" == 1 ]] && kv_width=32
        out_kv "node_description" "$nd"
        out_kv "part_number" "$pn"
        out_kv "serial" "$sn"
        out_kv "product_name" "$cn"
        out_kv "revision" "$rv"
        out_kv "fw_version" "$(printf "%d.%04d.%04d" "$maj" "$min" "$sub")"
        out_kv "cpld" "$cpld"
        [[ "${ps[${psu_idxs:0:1}.pr]}" != "" ]] && {
            for i in $psu_idxs; do
                out_kv "psu$i.part_number"   "${ps[$i.pn]}"
                out_kv "psu$i.serial" "${ps[$i.sn]}"
            done
        }
        [[ "$opt_C" == 1 ]] && show_cables
        exit "$query_ret"
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
        for t in ${fst[@]+"${!fst[@]}"}; do
            out_kv "fan#$t.status" "${fst[t]}"
        done
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
            for q in $(seq 1 "$nm"); do
                out_kv "module#$(printf "%02d" "$q").temp (C)" "${qt[$q]}"
            done
        }
        for t in ${at_idxs:-}; do
            out_kv "fan#$t.speed (rpm)" "${fs[$t]}"
        done
        [[ "$opt_P" == 1 && -n "$_counters" ]] && show_counters
        exit "$query_ret"
        ;;
esac


## full (default) output
dblsep
echo " $nd"
dblsep
out_kv "part number" "$pn"
out_kv "serial number" "$sn"
out_kv "product name" "$cn"
out_kv "revision" "$rv"
out_kv "modules" "$nm"
out_kv "max ports" "$np"
out_kv "PSID" "$psid"
out_kv "GUID" "$guid"
out_kv "firmware version" "$(printf "%d.%04d.%04d" "$maj" "$min" "$sub")"
out_kv "CPLD" "$cpld"
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
out_kv "warn threshold (C)" "$twl/$twh (low/high)"
[[ "$opt_T" == "1" ]] && {
    for q in $(seq 1 "$nm"); do
        out_kv "module#$(printf "%02d" "$q") (C) " "${qt[$q]}"
    done
}
sep

# fan status
out_kv "fan status" "$fa${fal:+ ($fal)}"
for t in ${at_idxs:-}; do
    out_kv "fan#$t (rpm)" "${fs[$t]}"
done
sep

[[ "$opt_C" == 1 ]] && {
    show_cables
    sep
}
[[ "$opt_P" == 1 && -n "$_counters" ]] && {
    show_counters
    sep
}
exit "$query_ret"
