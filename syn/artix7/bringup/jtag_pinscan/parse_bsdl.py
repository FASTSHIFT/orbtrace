#!/usr/bin/env python3
"""Parse the xc7a35t_fgg484 BSDL boundary register + the A7-Lite GPIO xlsx
into a single JSON describing, for every GPIO header pin, its package pin
and its three boundary-scan cell numbers (control / output / input).

This is the data backbone for the pure-JTAG (no-bitstream) connectivity
scanner: knowing each pin's cells lets us build EXTEST DR vectors that
drive one pin and sample the rest.

Outputs: pinmap.json  { "GPIO1_5P": {"pkg":"C13","ctrl":757,"out":758,"in":759}, ... }
"""
import json
import re
import sys
import zipfile

BSDL_DEFAULT = ("/home/vifex/workpath/tools/xilinx/Vivado/2021.1/data/parts/"
                "xilinx/artix7/public/bsdl/xc7a35t_fgg484.bsd")


def parse_bsdl(path):
    """package_pin -> {ctrl, out, in}."""
    txt = open(path, "r", errors="ignore").read()
    # cell lines look like:  " 734 (BC_2, IO_D17, output3, X, 733, 1, Z)," 
    #                        " 735 (BC_2, IO_D17, input, X),"
    cells = {}
    for m in re.finditer(
        r'"\s*(\d+)\s*\(BC_\d+,\s*IO_([A-Z]+\d+),\s*(\w+)\s*,[^)]*\)', txt):
        num, pin, func = int(m.group(1)), m.group(2), m.group(3)
        d = cells.setdefault(pin, {})
        if func == "output3":
            d["out"] = num
            # control cell is the 5th field of an output3 line
            cm = re.search(r'output3,\s*\w+,\s*(\d+)', m.group(0))
            if cm:
                d["ctrl"] = int(cm.group(1))
        elif func == "input":
            d["in"] = num
    return cells


def parse_gpio_xlsx(path):
    """GPIO header net name -> package pin."""
    z = zipfile.ZipFile(path)
    strs = re.findall(r"<t[^>]*>(.*?)</t>",
                      z.read("xl/sharedStrings.xml").decode("utf-8", "ignore"), re.S)

    def cell_value(cm):
        v = re.search(r"<v>(.*?)</v>", cm)
        if not v:
            return None
        typ = re.search(r't="(\w+)"', cm)
        return strs[int(v.group(1))] if (typ and typ.group(1) == "s") else v.group(1)

    out = {}
    for sheet in ("xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"):
        xml = z.read(sheet).decode("utf-8", "ignore")
        for r in re.findall(r"<row[^>]*>(.*?)</row>", xml, re.S):
            vals = {}
            for cm in re.finditer(r'<c [^>]*?r="([A-Z]+)(\d+)"[^>]*?(/>|>(.*?)</c>)', r, re.S):
                col = cm.group(1)
                vals[col] = cell_value(cm.group(0))
            name, pin = vals.get("C"), vals.get("D")
            if name and "GPIO" in str(name) and pin and re.match(r"^[A-Z]+\d+$", str(pin)):
                out[name] = pin
    return out


def main():
    bsdl = sys.argv[1] if len(sys.argv) > 1 else BSDL_DEFAULT
    gpio = sys.argv[2] if len(sys.argv) > 2 else "/tmp/gpio.xlsx"
    cells = parse_bsdl(bsdl)
    nets = parse_gpio_xlsx(gpio)
    pinmap = {}
    for net, pkg in nets.items():
        c = cells.get(pkg)
        if c and all(k in c for k in ("ctrl", "out", "in")):
            pinmap[net] = {"pkg": pkg, **c}
    json.dump(pinmap, open("pinmap.json", "w"), indent=1)
    print(f"parsed {len(pinmap)} GPIO pins with full cell mapping -> pinmap.json")
    # show a few
    for net in list(pinmap)[:5]:
        print(" ", net, pinmap[net])


if __name__ == "__main__":
    main()
