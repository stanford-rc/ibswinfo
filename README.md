# ibswinfo
Get information from unmanaged Infiniband switches


## Description
 `ibswinfo` is a simple script to get information from unmanaged Infiniband switches.

Mellanox Infiniband switches come in two flavors:
* managed switches have their own management controller, which allow monitoring fan speeds and temperatures, getting serial numbers and updating formwares over a variety of protocols (SSH, SNMP, HTTPs...)
* unmanaged switches are just that: unmanaged. Their firmware can be upgraded in-band, but the only way to monitor their status is to take a direct look at their PSU and fan LEDs. They're either green, or red.

`ibswinfo` leverages [Mellanox Firmware Tools (MFT)](https://www.mellanox.com/products/adapter-software/firmware-tools) to allow sysadmins to get more information about their unmanaged Infinibad switches. It can be used to gather vitals such as fan speeds or temperatures, and monitor the switches more closely.



## Dependencies

* [Mellanox Firmware Tools (MFT)](https://www.mellanox.com/products/adapter-software/firmware-tools) >= 4.14.0
* [`infiniband-diags`](https://github.com/linux-rdma/rdma-core)
* `bash`, `coreutils`, `awk`, `sed`


## Supported information

| inventory  | status | vitals       |
| ---------- | ------ | ------------ |
| model P/N  | fans   | uptime       |
| S/N        | PSU    | temperatures |
| PSID       |        | fan speeds   |
| PSU info   |        |              |
| FW version |        |              |



## Installation

It's a shell script, so....


## Example output

```
# ./ibswinfo.sh -d /dev/mst/<device>
-----------------------------------------------
node description | <device>
-----------------------------------------------
P/N              | MQM8790-HS2F
S/N              | <redacted>
hw rev.          | AC
codename         | Jaguar Unmng IB 200
-----------------------------------------------
PSID             | MT_0000000063
fw version       | 27.2000.1886
uptime [h:m:s]   | 174:31:45
-----------------------------------------------
PSU0 P/N         | MTEF-PSF-AC-C
PSU0 S/N         | <redacted>
PSU0 DC power    | OK
PSU0 fan status  | OK

PSU1 P/N         | MTEF-PSF-AC-C
PSU1 S/N         | <redacted>
PSU1 DC power    | OK
PSU1 fan status  | OK
-----------------------------------------------
ASIC temp [C]    | 33
ASIC max  [C]    | 41
-----------------------------------------------

```
