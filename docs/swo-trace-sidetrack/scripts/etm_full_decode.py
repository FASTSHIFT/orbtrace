#!/usr/bin/env python3
"""
ETMv3.5 instruction-flow reconstructor.
Pipeline: TPIU de-mux -> ETM packet parse (I-sync/branch/P-header)
          -> capstone disassembly from ELF -> write instruction flow to file.
"""
import sys, re
from elftools.elf.elffile import ELFFile
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB

INFILE  = sys.argv[1] if len(sys.argv)>1 else "trace_eval/cmp_br0.bin"
ELF     = sys.argv[2] if len(sys.argv)>2 else "proj_lvgl.axf"
OUTFILE = sys.argv[3] if len(sys.argv)>3 else "trace_eval/instr_flow.txt"

# ---------- load ELF code + symbols ----------
code_segs=[]   # (addr, bytes)
syms=[]
with open(ELF,'rb') as f:
    elf=ELFFile(f)
    for sec in elf.iter_sections():
        if sec['sh_flags'] & 0x4 and sec['sh_type']=='SHT_PROGBITS':  # EXECINSTR
            code_segs.append((sec['sh_addr'], sec.data()))
    symtab=elf.get_section_by_name('.symtab')
    if symtab:
        for s in symtab.iter_symbols():
            if s['st_info']['type']=='STT_FUNC' and s['st_value']:
                syms.append((s['st_value']&~1, s.name))
syms.sort()
sym_addrs=[a for a,_ in syms]
import bisect
def symof(a):
    i=bisect.bisect_right(sym_addrs,a)-1
    if i<0: return "?"
    return f"{syms[i][1]}+{a-syms[i][0]}"

def read_mem(addr,n=4):
    for base,data in code_segs:
        if base<=addr<base+len(data):
            off=addr-base
            return data[off:off+n]
    return b''

md=Cs(CS_ARCH_ARM, CS_MODE_THUMB)
def insn_at(addr):
    raw=read_mem(addr,4)
    if not raw: return None
    for ins in md.disasm(raw, addr):
        return ins
    return None

# ---------- TPIU de-mux ----------
data=open(INFILE,'rb').read()
SYNC=bytes([0xFF,0xFF,0xFF,0x7F])
first=data.find(SYNC)
buf=data[first+4:] if first>=0 else data
etm=bytearray(); cur=0; i=0
while i+16<=len(buf):
    fr=buf[i:i+16]
    if fr[0:4]==SYNC: i+=4; continue
    i+=16; aux=fr[15]
    for k in range(15):
        b=fr[k]
        if k%2==0:
            ab=(aux>>(k//2))&1
            if b&1: cur=b>>1
            elif cur==2: etm.append(b|ab)
        elif cur==2: etm.append(b)
etm=bytes(etm)
print(f"[tpiu] ETM payload {len(etm)} bytes")

# ---------- ETMv3.5 packet decode ----------
# Simplified state machine focusing on branch-address packets + I-sync.
# Reference: ARM IHI0014 ETMv3 signal protocol.
out=open(OUTFILE,'w')
pc=None
i=0; n=len(etm)
ninstr=0; nbranch=0; nsync=0

def parse_branch(i):
    """Branch address packet: bytes, bit7=continuation. Returns (addr_bits, nbytes, exc)."""
    addr=0; shift=0; cnt=0
    while i+cnt < n:
        b=etm[i+cnt]
        addr |= (b & 0x7F) << shift
        shift += 7
        cnt += 1
        if not (b & 0x80):
            break
    return addr, cnt

while i<n:
    b=etm[i]
    # A-sync: 00 00 00 00 00 80
    if b==0x00 and etm[i:i+6]==b'\x00\x00\x00\x00\x00\x80':
        i+=6; nsync+=1; continue
    # I-sync: header 0x08, then info byte + context(optional) + 4 addr bytes
    if b==0x08:
        # info byte at i+1; address is 4 bytes little-endian following
        if i+6<=n:
            a=etm[i+2]|(etm[i+3]<<8)|(etm[i+4]<<16)|(etm[i+5]<<24)
            if 0x08000000<=a<=0x08100000:
                pc=a & ~1
                out.write(f"\n--- ISYNC PC=0x{pc:08X} {symof(pc)} ---\n")
                i+=6; nsync+=1; continue
        i+=1; continue
    # Branch address packet: LSB-set byte typically; treat bit0==1 as branch start
    if b & 0x01:
        addr,cnt=parse_branch(i)
        # In ETMv3.5 the branch addr is compressed/relative; here we take the
        # reconstructed bits as low-order update of current PC.
        if pc is None:
            newpc=addr & ~1
        else:
            # update low bits that were transmitted
            bits=cnt*7
            mask=(1<<bits)-1
            newpc=((pc & ~mask) | (addr & mask)) & ~1
        nbranch+=1
        # Disassemble from previous pc up to branch (best-effort: just log target)
        ins=insn_at(newpc)
        if ins and 0x08000000<=newpc<=0x08100000:
            out.write(f"BR-> 0x{newpc:08X}  {symof(newpc):40s} {ins.mnemonic} {ins.op_str}\n")
            pc=newpc
        i+=cnt; continue
    # P-header / other: skip 1 byte (atoms not fully reconstructed here)
    i+=1

out.close()
print(f"[etm] branches={nbranch} syncs={nsync}")
print(f"[out] wrote {OUTFILE}")
