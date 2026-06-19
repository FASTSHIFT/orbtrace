set pagination off
set confirm off
target extended-remote localhost:2331
file ../proj_add.axf
monitor reset
monitor go
shell sleep 1
monitor halt
source ../orbuculum/Support/gdbtrace.init
enableSTM32SWO 4
prepareSWO 168000000 2000000 1 0
# More frequent sync: dwtSyncTap 1 = CYCCNT[24] (frequent)
dwtSyncTap 1
dwtCycEna 1
startETM 1 0
echo \n=== ETM with frequent sync, holding ===\n
continue
