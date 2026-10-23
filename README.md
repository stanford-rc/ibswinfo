# ibswinfo

Get information from unmanaged NVIDIA Infiniband switches.

## Description

`ibswinfo` is a simple script to get status and monitoring information from
unmanaged NVIDIA Infiniband switches.

NVIDIA Infiniband switches come in two flavors:

* managed switches have their own management controller, which allows
  monitoring fan speeds and temperatures, getting serial numbers, or updating
  firmwares over a variety of protocols (SSH, SNMP, HTTPs...)

* unmanaged switches are just that: unmanaged.

Some in-band management is possible for unmanaged switches with NVIDIA firmware
tools, but the only way to get their status is via the LEDs on their chassis:
they're either green (that's good), or red (that's bad). But you won't know
unless you physically take a look at them, which makes it difficult to get
notifications and alerts when problems occur.

`ibswinfo` helps solve this problem, by leveraging [NVIDIA Firmware Tools
(MFT)](https://network.nvidia.com/products/adapter-software/firmware-tools/) to
allow sysadmins to get more information about their unmanaged Infiniband
switches, and monitor them more closely. It can be used to:

* gather hardware vitals, such as fan speeds, temperatures or power supply
  status, and report fans that are out of range,
* get per-port traffic counters, as cumulative totals or current rates,
* list the cables and transceivers plugged in each port,
* set a user-friendly name (node description) for each switch: no more endless
  lists of identical and unhelpful switch names like "SwitchX - NVIDIA
  Networking", sysadmins can customize each switch with a descriptive name
  (model, physical location, cluster name, etc.) and make it more easily
  identifiable.

## Installation

### Dependencies

* [NVIDIA Firmware Tools
  (MFT)](https://network.nvidia.com/products/adapter-software/firmware-tools/)

    \>= 4.18.0 for information queries. Setting a switch name does not require MFT.

* [`infiniband-diags`](https://github.com/linux-rdma/rdma-core)
* `bash` (4.2 or later), `coreutils`, `awk` and `sed`

For setting switch names, build the `ibsetnd` helper with a C compiler, `make`,
and the libibmad/libibumad development packages from rdma-core (or OFED).
On Debian/Ubuntu these are `libibmad-dev` and `libibumad-dev`; on RHEL-family
systems they are typically `libibmad-devel` and `libibumad-devel`.
The corresponding runtime libraries must also be installed.

### Build

``` shell
$ make
```

This builds `ibsetnd` alongside `ibswinfo.sh`. Run `./ibswinfo.sh` directly
from the checkout; no installation step is needed. If you copy the script
elsewhere, copy the helper alongside it. Information queries do not need
the helper.

### Preparation

`ibswinfo` can address switches by using the virtual devices created by MST,
the NVIDIA Software Tools service, or by LID.

* to use the MST virtual devices, you can start the `mst` service and populate
  entries in `/dev/mst` with:

    ``` shell
    # mst start
    # mst ib add
    ```

    Check that `/dev/mst` contains entries for your unmanaged switches (they
    should look like `/dev/mst/SW_*`), and you can run `ibswinfo` like this:

    ``` shell
    # ./ibswinfo.sh -d /dev/mst/SW_model_node-desc_lid-0x0001
    ```

    or without the `/dev/mst` prefix, using the virtual device name directly:

    ```shell
    # ./ibswinfo.sh -d SW_model_node-desc_lid-0x0001
    ```

* to address switches by LID, starting the `mst` service is not required. You
  can get currently assigned LIDs with `ibswitches`, and run `ibswinfo`
  directly like this: `./ibswinfo.sh -d lid-16`

## Supported hardware

`ibswinfo` has been tested with the following unmanaged Infiniband switches:

* SB7790 Switch-IB (EDR) (_known limitation: QSFP module temperatures reported
  as 0_)
* SB7890 Switch-IB2 (EDR)
* QM8790 Quantum (HDR)

Limited support is also available for the managed version of those switches:

* SB7800 Switch-IB2 (EDR)
* QM8700 Quantum (HDR)

> [!NOTE]
> If you find other working models, please feel free to open an
[issue](https://github.com/stanford-rc/ibswinfo/issues/new) and
we'll complete the list.

### Available information

* Node description (switch name)
* Part number, serial number
* PSID, GUID, firmware version
* Uptime
* Power supply information (status, consumption, part and serial numbers)
* Temperatures (including QSFP modules temp.)
* Fan speeds and status (including out of range readings)
* Cable inventory (vendor, part number, serial number, length and type)
* Port traffic counters (cumulative bytes/packets totals, or current rates)

## Usage

```none
Usage: ibswinfo.sh -d <device> [-T] [-C] [-P] [-o <inventory|vitals|status>] [-S <description>]

  global options:
    -d <device>             MST device path ("mst status" shows devices list)
                            or LID (eg. "-d lid-44")
  get info:
    -o <output_category>    Only display inventory|vitals|status information
    -T                      get transceiver modules temperature
    -C                      get cable information
    -P                      get port traffic counters

  set info:
    -S <description>        set device description (64 bytes max.)
    -y                      skip confirmation

```

### Default output

By default, `ibswinfo` presents all the available information for a switch in a
table-like output:

```none
# ./ibswinfo.sh -d <device>
=================================================
<node description>
=================================================
part number        | MQM8790-HS2F
serial number      | <redacted>
product name       | Jaguar Unmng IB 200
revision           | AC
modules            | 40
max ports          | 40
PSID               | MT_0000000063
GUID               | <redacted>
firmware version   | 27.2000.1886
CPLD               | 3
-------------------------------------------------
uptime (d-h:m:s)   | 196d-07:05:40
-------------------------------------------------
PSU0 status        | OK
     P/N           | MTEF-PSF-AC-C
     S/N           | <redacted>
     DC power      | OK
     fan status    | OK
     power (W)     | 64
PSU1 status        | OK
     P/N           | MTEF-PSF-AC-C
     S/N           | <redacted>
     DC power      | OK
     fan status    | OK
     power (W)     | 47
-------------------------------------------------
temperature (C)    | 34
max temp (C)       | 41
warn threshold (C) | 95/105 (low/high)
-------------------------------------------------
fan status         | OK
fan#1 (rpm)        | 5426
fan#2 (rpm)        | 4746
fan#3 (rpm)        | 5426
fan#4 (rpm)        | 4798
fan#5 (rpm)        | 5426
fan#6 (rpm)        | 4815
fan#7 (rpm)        | 5382
fan#8 (rpm)        | 4868
fan#9 (rpm)        | 5471
-------------------------------------------------
```

### Cable inventory

Add `-C` to append cable information to the default output. For example (excerpt,
with serial numbers redacted):

```none
# ./ibswinfo.sh -d <device> -C
...
-------------------------------------------------
port#1 cable       | Mellanox MFS1200-E003 (<redacted>) 3m  QSFP+ active
port#7 cable       | Mellanox MFA1A00-E010 (<redacted>) 10m QSFP+ active
[...]
port#17 cable      | Mellanox 0684G2       (<redacted>) 10m QSFP+ active
-------------------------------------------------
```

Ports use IB numbering. Unknown cable lengths are omitted, and unplugged ports
are marked `unplugged`. Use `-o inventory -C` for key/value output.

### Port traffic counters

`ibswinfo` can also report per-port traffic, using the extended 64-bit counters
that `perfquery -x` (from `infiniband-diags`) reads from the switch (counters
are never reset).

With `-o vitals`, `-P` adds the cumulative TX/RX bytes and packets totals for
each IB port to the hardware vitals:

```
# ./ibswinfo.sh -d lid-14 -o vitals -P
[...]
fan#8.speed (rpm)  : 5421
port1.tx_bytes     : 3299135337352
port1.rx_bytes     : 106268438855896
port1.tx_packets   : 879938006
port1.rx_packets   : 27190158432
port2.tx_bytes     : 4536076770588
port2.rx_bytes     : 7195872703540
port2.tx_packets   : 1448508819
port2.rx_packets   : 3243159117
[...]
```

In the default output, `-P` appends the current traffic rates instead:

```
# ./ibswinfo.sh -d lid-14 -P
[...]
-------------------------------------------------
port#1 traffic     | TX  27.6  B/s   1.0  pps
                   | RX   0.0  B/s   0.0  pps
[...]
port#61 traffic    | TX 109.9 MB/s  94.8 kpps
                   | RX 337.7 MB/s  84.6 kpps
port#62 traffic    | TX 107.8 MB/s  94.1 kpps
                   | RX  88.2 MB/s  22.6 kpps
port#63 traffic    | TX   0.0  B/s   0.0  pps
                   | RX 264.0 MB/s 129.2 kpps
port#64 traffic    | TX 558.1 kB/s 258.7  pps
                   | RX 542.2 MB/s 189.2 kpps
-------------------------------------------------
```

To send the queries through a specific local HCA port, rather than the one
`perfquery` and MFT would pick on their own, append it to the LID, like
`-d lid-14,mlx5_0,1`. This `,CA,port` suffix only works when addressing switches
by LID, not with `SW_*` MST device names.

### Targeted outputs

Specific information can be targeted by choosing the appropriate output type:
`inventory`, `status` or `vitals`.

This can be particularly useful to quickly get a switch's serial number, check
its status to create alerts, or feed hardware metrics to a monitoring system.
Targeted outputs are designed to be parsed for input to other tools.

For instance, to only get hardware vitals, including QSFP temperatures:

``` shell
# ./ibswinfo.sh -d <device> -o vitals -T
uptime (sec)       : 16982312
psu0.power (W)     : 92
psu1.power (W)     : 102
cur.temp (C)       : 73
max.temp (C)       : 80
module#01.temp (C)   : 44
module#02.temp (C)   : 43
module#03.temp (C)   : 43
module#04.temp (C)   : 47
module#05.temp (C)   : 42
module#06.temp (C)   : 46
module#07.temp (C)   : 44
[...]
module#32.temp (C)   : 45
module#33.temp (C)   : 39
module#34.temp (C)   : 44
module#35.temp (C)   : 37
module#36.temp (C)   : 39
fan#1.speed (rpm)  : 6355
fan#2.speed (rpm)  : 5421
fan#3.speed (rpm)  : 6570
fan#4.speed (rpm)  : 5508
fan#5.speed (rpm)  : 6415
fan#6.speed (rpm)  : 5486
fan#7.speed (rpm)  : 6268
fan#8.speed (rpm)  : 5421
```

Or, to only get fans and power supplies' status:

``` shell
# ./ibswinfo.sh -d <device> -o status
psu0.status        : OK
psu0.dc            : OK
psu0.fan           : OK
psu1.status        : OK
psu1.dc            : OK
psu1.fan           : OK
fans               : OK
```

### Setting switch names

_requires the built `ibsetnd` helper and libibmad/libibumad runtime libraries_

Unmanaged switches' node descriptions can be customized, for easier management
and better switch identification.

To update a switch's name to `<new_node description>`:

``` shell
# ./ibswinfo.sh -d <device> -S <new_node_description>
Device: <device>
  Current node description: <old_node_description>
  Set node description to : <new_node_description>
>> Confirm? (y/N) y
Setting new node description... done!
```

By default, unmanaged Infiniband switches all come with the same node
description, based on their model, and it can quickly become cumbersome to
determine which is which. Setting customized and descriptive switch names can
help solve that problem and allow better identification of switches in the
datacenter.

Before:

``` shell
# ibswitches
Switch  : 0xXXXXXXXXXXXXXXXa ports 37 "SwitchX - Mellanox Technologies" base port 0 lid 1 lmc 0
Switch  : 0xXXXXXXXXXXXXXXXb ports 37 "SwitchX - Mellanox Technologies" base port 0 lid 2 lmc 0
Switch  : 0xXXXXXXXXXXXXXXXc ports 37 "SwitchX - Mellanox Technologies" base port 0 lid 3 lmc 0
Switch  : 0xXXXXXXXXXXXXXXXd ports 37 "SwitchX - Mellanox Technologies" base port 0 lid 4 lmc 0
```

After:

``` shell
# ibswitches
Switch  : 0xXXXXXXXXXXXXXXXa ports 37 "switch1 in rack1 U1" base port 0 lid 1 lmc 0
Switch  : 0xXXXXXXXXXXXXXXXb ports 37 "switch2 in rack1 U3" base port 0 lid 2 lmc 0
Switch  : 0xXXXXXXXXXXXXXXXc ports 37 "switch3 in rack1 U5" base port 0 lid 3 lmc 0
Switch  : 0xXXXXXXXXXXXXXXXd ports 37 "switch4 in rack1 U7" base port 0 lid 4 lmc 0
```
