#!/usr/bin/env bash
# Capture the ETF 4KB trace buffer in circular mode via RRD.
{
  echo "halt"; sleep 0.3
  echo "mww 0x5C014020 0x00000000"; sleep 0.2
  echo "mww 0x5C014FB0 0xC5ACCE55"; sleep 0.2
  echo "mww 0x5C014028 0x00000000"; sleep 0.2
  echo "mww 0x5C014304 0x00000001"; sleep 0.2
  echo "mww 0x5C014020 0x00000001"; sleep 0.2
  echo "resume"; sleep 1.2; echo "halt"; sleep 0.3
  echo "mww 0x5C014020 0x00000000"; sleep 0.4
  echo "mww 0x5C014014 0x00000000"; sleep 0.2
  for i in $(seq 0 127); do echo "mdw 0x5C014010 8"; sleep 0.03; done
  echo "resume"; sleep 0.2
  echo "exit"
} | timeout 60 telnet 127.0.0.1 4444 2>&1 | strings | grep -iE "0x5c014010:"
