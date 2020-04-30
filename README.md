# ibswinfo
Display information from unmanaged Mellanox Infiniband switches.


## Description

`ibswinfo` is a simple script to get status and monitoring information 
from unmanaged Mellanox Infiniband switches.

Mellanox Infiniband switches come in two flavors:

* managed switches have their own management controller, which allows
  monitoring fan speeds and temperatures, getting serial numbers and updating
  firmwares over a variety of protocols (SSH, SNMP, HTTPs...)

* unmanaged switches are just that: unmanaged. Their firmware can be updated
  in-band with MFT, but the only way to get their status is through their PSU
  and fan LEDs: they're either green and that's good, or they're red and you're
  toast. But you won't know unless you physically take a look at them.


`ibswinfo` leverages [Mellanox Firmware Tools
(MFT)](https://www.mellanox.com/products/adapter-software/firmware-tools) to
allow sysadmins to get more information about their unmanaged Infiniband
switches.

It can be used to gather vitals such as fan speeds or temperatures,
and monitor the switches more closely.


## Dependencies

* [Mellanox Firmware Tools
  (MFT)](https://www.mellanox.com/products/adapter-software/firmware-tools) >=
  4.14.0
* [`infiniband-diags`](https://github.com/linux-rdma/rdma-core)
* `bash`, `coreutils`, `awk` and `sed`

## Installation

It's a shell script, so, it's pretty much:
1. download
2. run

### Preparation

`ibswinfo` operates on virtual devices created by MST, the Mellanox Software Tools service.
You can start the `mst` service and populate entries in `/dev/mst` with:

```
# mst start
# mst ib add
```

Check that `/dev/mst` contains entries for your unmanaged switches (they should
look like `/dev/mst/SW_*`).


## Supported hardware

`ibswinfo` has been tested with the following unmanaged Infiniband switches:
* SB7890 Switch-IB2 EDR
* QM8790 Quantum HDR

Limited support is also available for the managed version of those switches:
* SB7800 Switch-IB2 EDR
* QM8700 Quantum HDR


## Supported information

* Part number, serial number
* PSID, GUID, firmware version
* Uptime
* Power supply information (status, consumption, inventory)
* Temperatures (including QSFP modules temp.)
* Fan speeds and status


## Usage

```
#  ./ibswinfo/ibswinfo.sh -h
Usage: ibswinfo.sh -d <device> [-T] [-o <inventory|vitals|status>]

    -d <device>             MST device name.
                            Run "mst status" to get the devices list
    -o <output_category>    Only display inventory|vitals|status information
    -T                      get QSFP modules temperature
    
```

### Default output

By default, `ibswinfo` presents all the available information for a switch in a
table-like output:

```
# ./ibswinfo.sh -d /dev/mst/<device>
=================================================
<node description>
=================================================
part number        | MQM8790-HS2F
serial number      | <redacted>
product name       | Jaguar Unmng IB 200
revision           | AC
ports              | 40
PSID               | MT_0000000063
GUID               | <redacted>
firmware version   | 27.2000.1886
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

### Targeted outputs

Only specific values can be displayed by chossing the appropriate output type: `inventory`, `status` or `vitals`
, to quickly get serial numbers, or feed
vitals metrics to a monitoring system. 

For instance, to only get a switch's vitals, including QSFP temperatures:

```
# ./ibswinfo -d /dev/mst/device -o vitals -T
uptime (sec)       : 16982312
psu0.power (W)     : 92
psu1.power (W)     : 102
cur.temp (C)       : 73
max.temp (C)       : 80
QSFP#01.temp (C)   : 44
QSFP#02.temp (C)   : 43
QSFP#03.temp (C)   : 43
QSFP#04.temp (C)   : 47
QSFP#05.temp (C)   : 42
QSFP#06.temp (C)   : 46
QSFP#07.temp (C)   : 44
QSFP#08.temp (C)   : 46
QSFP#09.temp (C)   : 44
QSFP#10.temp (C)   : 45
QSFP#11.temp (C)   : 44
QSFP#12.temp (C)   : 44
QSFP#13.temp (C)   : 48
QSFP#14.temp (C)   : 47
QSFP#15.temp (C)   : 51
QSFP#16.temp (C)   : 49
QSFP#17.temp (C)   : 53
QSFP#18.temp (C)   : 50
QSFP#19.temp (C)   : 52
QSFP#20.temp (C)   : 50
QSFP#21.temp (C)   : 51
QSFP#22.temp (C)   : 49
QSFP#23.temp (C)   : 47
QSFP#24.temp (C)   : 47
QSFP#25.temp (C)   : 44
QSFP#26.temp (C)   : 44
QSFP#27.temp (C)   : 42
QSFP#28.temp (C)   : 46
QSFP#29.temp (C)   : 41
QSFP#30.temp (C)   : 45
QSFP#31.temp (C)   : 40
QSFP#32.temp (C)   : 45
QSFP#33.temp (C)   : 39
QSFP#34.temp (C)   : 44
QSFP#35.temp (C)   : 37
QSFP#36.temp (C)   : 39
fan#1.speed (rpm)  : 6355
fan#2.speed (rpm)  : 5421
fan#3.speed (rpm)  : 6570
fan#4.speed (rpm)  : 5508
fan#5.speed (rpm)  : 6415
fan#6.speed (rpm)  : 5486
fan#7.speed (rpm)  : 6268
fan#8.speed (rpm)  : 5421
```

