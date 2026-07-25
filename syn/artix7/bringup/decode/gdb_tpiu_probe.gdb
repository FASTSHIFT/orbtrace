# Dump every stream-2 ETM byte orbetto's TPIU deframer delivers, so it can be
# diffed byte-for-byte against our Python port (tpiu_official.py) to find the
# first point of divergence (orbetto yields 11825 bytes vs our 11816).
set pagination off
set confirm off
set print elements 0

# orbetto.cpp:981 is the _pumpETMProcessGeneric() call for a stream-2 byte
# (decode pass only; the preprocess pass takes the else branch).
break orbetto.cpp:981
commands
  silent
  printf "ETMBYTE %02x\n", _r.p.packet[g].d
  continue
end

run -C 300000 -t 1 -f /tmp/bb0cache.bin.aligned.bin -e /tmp/rt300_2b.elf
quit
