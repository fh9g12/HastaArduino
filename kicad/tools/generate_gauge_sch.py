"""Generator for the strain-gauge board schematic: kicad/gaugeboard/gaugeboard.kicad_sch.

    py kicad/tools/generate_gauge_sch.py

A small, reusable board that holds everything about the strain gauges: two Adafruit ADS122C04 breakouts,
the half-bridge gauge headers, ONE shared pair of 350R completion resistors, its own clean 3.3 V regulator
(from the 5 V on the loom) and optional input filtering. It talks to the main HastaDAQ board over a 4-wire
I2C loom (GND, +5V, SDA, SCL) on a 0.1in header at each end. The footprint library is shared with the main
board (../hastadaq/HastaDAQ.pretty).

Like the main board, this script is a bootstrap: once the schematic is edited in KiCad (or a PCB exists),
treat the .kicad_sch as the source and stop re-running it (it reassigns reference designators).
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import schgen_common as sg
from schgen_common import *  # noqa: F401,F403

OUT_DIR = pathlib.Path(__file__).resolve().parent.parent / "gaugeboard"
sg.init("gaugeboard", OUT_DIR, "HastaDAQ strain-gauge board", paper="A3")

define_resistor()
define_cap()
define_cap_polarized()
define_pwrflag()
define_testpoint()

FP_R = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal"
FP_C_SMALL = "Capacitor_THT:C_Rect_L4.0mm_W2.5mm_P2.50mm"     # 100 nF Vishay K series, 2.5 mm lead spacing

text("HastaDAQ strain-gauge board", 20, 20, 3.0, bold=True)
text("Net labels connect everything: same name = same net. Companion to the main board (kicad/hastadaq). "
     "Reusable: any I2C master with 5 V and 3.3 V logic can drive it.", 20, 27)

# ------------------------------------------------------------------ loom + power conditioning
header("LOOM from main board (4-wire I2C): GND, +5V, SDA, SCL", 40, 62,
       [("GND", "GND"), ("5V", "+5V"), ("SDA", "SDA"), ("SCL", "SCL")])
text("Pin 2 is +5V, NOT 3V3: use a keyed plug, never a Qwiic cable.", 20, 85)
header("LOOM OUT (pass-through, paralleled with J1): GND, +5V, SDA, SCL", 40, 108,
       [("GND", "GND"), ("5V", "+5V"), ("SDA", "SDA"), ("SCL", "SCL")])
text("Second 1x4 header wired straight to the loom: daisy-chains another I2C board (+5V, 3.3 V logic).", 20, 131)

vertical_part("C_Polarized", "C", "47uF 16V (RS PRO LHK 5x7)", 110, 62, "+5V", "GND", "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm")
vertical_part("C", "C", "100nF 50V X7R (Vishay K104)", 140, 62, "+5V", "GND", FP_C_SMALL)
# Microchip MCP1700-3302E/TO (data sheet DS20001826C): TO-92 pin 1 = GND, 2 = VIN, 3 = VOUT; stable with a 1 uF
# ceramic, tantalum or aluminium output cap; 250 mA max, 2.3-6.0 V in, dropout about 0.2 V at 250 mA. Do not feed it
# more than 6 V (the loom carries 5 V).
block("LDO_3V3", "3.3 V LDO: MCP1700-3302E/TO (TO-92: pin 1 GND, 2 VIN, 3 VOUT)", 200, 62,
      left=[(2, "VIN", "+5V", "power_in"), (1, "GND", "GND", "power_in")],
      right=[(3, "VOUT", "+3V3", "power_out")],
      ref_prefix="U", width=30.48, footprint="Package_TO_SOT_THT:TO-92_Inline")
vertical_part("C_Polarized", "C", "10uF 10V tantalum (RS PRO CB, + to 3V3)", 260, 62, "+3V3", "GND", "Capacitor_THT:CP_Radial_D5.0mm_P2.50mm")
vertical_part("C", "C", "100nF 50V X7R (Vishay K104)", 280, 62, "+3V3", "GND", FP_C_SMALL)
box(85, 40, 295, 92)
text("POWER: bulk + decoupling on the loom 5 V (any ferrite bead is part of the loom, not the board), the LDO makes the quiet 3.3 V that powers BOTH ADCs and the bridge excitation", 88, 38)
text("Load is about 20 mA (bridges 2 x 4.7 mA + ADCs); the LDO dissipates about 35 mW (250 mA rating).", 88, 96)

# PWR_FLAGs: nets fed through a passive part (loom header)
for i, net in enumerate(["+5V", "GND"]):
    fx, fy = snap(310 + i * 22), snap(70)
    instance("HastaDAQ:PWR_FLAG", next_ref("#FLG"), "PWR_FLAG", fx, fy, [1], (fx + 2, fy - 3), (fx + 2, fy - 1), "", bom=False)
    stub_label(net, fx, fy, "down", 2.54)

# Test points: GND for a scope clip and the regulated 3V3 (the one rail worth checking on this board)
FP_TP = "TestPoint:TestPoint_Pad_D2.0mm"
text("TEST POINTS: GND (scope clip) and the regulated +3V3", 300, 90)
for i, net in enumerate(["GND", "+3V3"]):
    tx, ty = snap(310 + i * 15), snap(110)
    instance("HastaDAQ:TestPoint", next_ref("TP"), "TP", tx, ty, [1], (tx + 2, ty - 1), (tx + 2, ty + 2), FP_TP)
    stub_label(net, tx, ty - 2.54, "up")

# ------------------------------------------------------------------ ADCs, filters, gauge headers
def ads(title, y, a0, a1):
    block("ADS122C04", title, 90, y,
          left=[(1, "VIN", "+3V3", "power_in"), (2, "GND", "GND", "power_in"),
                (3, "SDA", "SDA", "bidirectional"), (4, "SCL", "SCL", "input"),
                (5, "~{RST}", None), (6, "DRDY", None)],
          right=[(7, "A0", a0, "input"), (8, "A1", a1, "input"), (9, "A2", None), (10, "A3", None),
                 (11, "Ref+", None), (12, "Ref-", None)],
          footprint="HastaDAQ:Adafruit_ADS122C04_Breakout")


def channel(n, y):
    ads(f"Adafruit ADS122C04 #{n}" + (" (I2C 0x40)" if n == 1 else " (address jumper bridged)"), y,
        f"ADS{n}_A0", f"ADS{n}_A1")
    # optional input filter: 0R links by default; fit 1k + 100nF (C DNP otherwise) for a ~800 Hz low-pass
    vertical_part("R", "R", "0R link", 175, y, f"ADS{n}_SIG", f"ADS{n}_A0", FP_R)
    vertical_part("R", "R", "0R link", 200, y, "ADS_REF", f"ADS{n}_A1", FP_R)
    vertical_part("C", "C", "100nF 50V X7R (DNP)", 225, y, f"ADS{n}_A0", f"ADS{n}_A1", FP_C_SMALL, dnp=True)
    box(165, y - 16, 245, y + 16)
    text(f"ADS{n} input filter (optional: 1k links + 100nF)", 166, y - 18)
    # (no extra supply decoupling here: each Adafruit breakout already has 10 uF + 100 nF on VIN)
    # half-bridge gauge head
    header(f"HB{n} half-bridge #{n} (on beam): V, SIG, GND", 340, y,
           [("V", "+3V3"), ("SIG", f"ADS{n}_SIG"), ("GND", "GND")])


channel(1, 150)
channel(2, 230)

# ONE shared completion pair at the ADC end; its mid-point is the reference node for BOTH channels
completion(372, 190, "ADS_REF", "Shared completion\nresistors (fixed)\n-> A1 of BOTH ADCs")

text("NOTES\n"
     "1. Each half-bridge head (2 gauges) plugs into a 3-pin header: V (+3V3), SIG (mid-point), GND. The two fixed 350R\n"
     "   completion resistors are shared; their mid-point (ADS_REF) goes to A1 of both ADCs. Excitation is the ADC's own VIN, so\n"
     "   VREF_SUPPLY is ratiometric: no Ref+/Ref- wiring.\n"
     "2. 3V3 comes ONLY from the on-board LDO (from the loom's 5 V): cable voltage drop and the main board's switching noise do\n"
     "   not reach the bridges or the ADC reference. The ADC logic lines (SDA/SCL) are pulled up by the ADS122C04 breakouts to\n"
     "   this 3V3 and are 3.3 V logic: the master must not drive them above 3.6 V. Each breakout also has its own 10uF + 100nF on\n"
     "   VIN, so no extra ADC decoupling is fitted here.\n"
     "3. Input filters are optional: with the 0R links and no capacitor fitted there is none (original behaviour). Fit 1k in each\n"
     "   link and 100nF across A0-A1 for about an 800 Hz low-pass (the 100nF positions are marked DNP).\n"
     "4. ADS #2: bridge its ADDR0 solder jumper (ADDR0 is pulled to GND by 10k, so the jumper ties it to VCC: expected address 0x41;\n"
     "   the main board's firmware scans at boot). The Adafruit breakouts carry 10k pull-ups on SDA/SCL to their VIN.\n"
     "5. Use shielded twisted cable for the gauge wires, shield to GND at this board only.",
     20, 277)

sg.write_outputs("${KIPRJMOD}/../hastadaq/HastaDAQ.pretty")
