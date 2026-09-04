# Arm the ILA and capture one bad-byte event.

if {$argc < 1} {
    puts "usage: vivado -mode batch -source arm_ila_and_capture.tcl -tclargs <ltx>"
    exit 1
}
set ltx_file [lindex $argv 0]
set csv_out  "ila_capture.csv"
if {$argc >= 2} { set csv_out [lindex $argv 1] }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
current_hw_device [lindex [get_hw_devices xc7a35t*] 0]
set_property PROBES.FILE $ltx_file [current_hw_device]
set_property FULL_PROBES.FILE $ltx_file [current_hw_device]
refresh_hw_device [current_hw_device]

set ila [get_hw_ilas -of_objects [current_hw_device]]
puts "ILA cores found: $ila"

set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 1024 $ila
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila

# List probes
puts "==== Available probes ===="
foreach p [get_hw_probes -of_objects $ila] {
    puts "  [get_property NAME $p]  width=[get_property WIDTH $p]"
}

# NOTE: 32-bit / 16-bit vector nets got split by Vivado's debug-hub optimizer
# into multiple named sub-probes (pkt_seq / pkt_seq_1 / pkt_seq_2 / ... / _6).
# That's harmless for reading — we still see all bits — but trigger uses only
# what we set below.

proc find_probe {ila name} {
    set p [get_hw_probes -of_objects $ila -filter "NAME == $name"]
    if {[llength $p] == 0} {
        error "probe '$name' not found"
    }
    return $p
}

set p_stream_tdata  [find_probe $ila stream_tdata]
set p_stream_tvalid [find_probe $ila stream_tvalid]
set p_src_fixed     [find_probe $ila src_fixed_125]

# --- DIAG STEP 1 --- trigger on the EXPECTED value to prove the probes work.
# stream_tdata == 0x42 && stream_tvalid == 1 should be extremely common
# (millions of matches per second). If this doesn't trigger either, the
# probe wiring itself is broken (wrong signal / clock / hierarchy).
set diag_trigger [expr {[info exists ::env(ILA_DIAG)] ? $::env(ILA_DIAG) : 0}]
if {$diag_trigger} {
    puts "DIAG: triggering on EXPECTED value (stream_tdata==0x42 & tvalid==1)"
    set_property TRIGGER_COMPARE_VALUE eq8'h42 $p_stream_tdata
    set_property TRIGGER_COMPARE_VALUE eq1'b1   $p_stream_tvalid
} else {
    puts "REAL: triggering on BAD value (stream_tdata!=0x42 & tvalid==1)"
    set_property TRIGGER_COMPARE_VALUE neq8'h42 $p_stream_tdata
    set_property TRIGGER_COMPARE_VALUE eq1'b1   $p_stream_tvalid
}

# Sanity print
puts "==== Trigger setup ===="
foreach p [list $p_stream_tdata $p_stream_tvalid $p_src_fixed] {
    puts "  [get_property NAME $p] = [get_property TRIGGER_COMPARE_VALUE $p]"
}

run_hw_ila $ila
puts "ILA armed."

# Dump valid properties for diagnostic.
puts "==== ILA hw_ila properties ===="
foreach k [list_property $ila] {
    if {[string match "*STATUS*" $k] || [string match "*STATE*" $k]} {
        catch {puts "  $k = [get_property $k $ila]"}
    }
}

# Just wait — 30 s window is comfortably longer than average time between
# bad bytes at 0.4% rate on a ~90 MB/s stream.
if {[catch {wait_on_hw_ila -timeout 30 $ila} err]} {
    puts "wait_on_hw_ila error: $err"
}
puts "wait_on_hw_ila returned."

# Try upload regardless.
if {[catch {
    upload_hw_ila_data $ila
} err]} {
    puts "upload_hw_ila_data failed: $err"
}

# Try to upload regardless — if triggered, we get real data; if not,
# we can at least see the current sample buffer (should show 0x42 traffic).
if {[catch {
    upload_hw_ila_data $ila
    puts "Writing $csv_out"
    write_hw_ila_data -force -csv_file $csv_out [current_hw_ila_data $ila]
} err]} {
    puts "Data upload failed: $err"
}

disconnect_hw_server
close_hw_manager
