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

FP_R = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal"
FP_C_CER = "Capacitor_THT:C_Rect_L7.2mm_W3.5mm_P5.00mm"      # 10 uF class radial ceramic / film footprint
FP_C_SMALL = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"     # 100 nF

text("HastaDAQ strain-gauge board", 20, 20, 3.0, bold=True)
text("Net labels connect everything: same name = same net. Companion to the main board (kicad/hastadaq). "
     "Reusable: any I2C master with 5 V and 3.3 V logic can drive it.", 20, 27)

# ------------------------------------------------------------------ loom + power conditioning
header("LOOM from main board (4-wire I2C): GND, +5V, SDA, SCL", 40, 62,
       [("GND", "GND"), ("5V", "+5V"), ("SDA", "SDA"), ("SCL", "SCL")])
text("Pin 2 is +5V, NOT 3V3: use a keyed plug, never a Qwiic cable.", 20, 85)

vertical_part("C_Polarized", "C", "47uF (>=10V)", 110, 62, "+5V", "GND", "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm")
vertical_part("C", "C", "100nF", 140, 62, "+5V", "GND", FP_C_SMALL)
# LP2950-N 3.3 V (TI data sheet SNVS764Q): TO-92 pin 1 = OUT, 2 = GND, 3 = IN; stable with ceramic output caps
# (2.2 uF min for the 3.3 V version); 100 mA max, 2.3-30 V in, dropout about 0.4 V at 100 mA.
block("LDO_3V3", "3.3 V LDO: LP2950-N 3.3 V (TO-92: pin 1 OUT, 2 GND, 3 IN)", 200, 62,
      left=[(3, "IN", "+5V", "power_in"), (2, "GND", "GND", "power_in")],
      right=[(1, "OUT", "+3V3", "power_out")],
      ref_prefix="U", width=30.48, footprint="Package_TO_SOT_THT:TO-92_Inline")
vertical_part("C", "C", "10uF out", 260, 62, "+3V3", "GND", FP_C_CER)
vertical_part("C", "C", "100nF", 280, 62, "+3V3", "GND", FP_C_SMALL)
box(85, 40, 295, 92)
text("POWER: bulk + decoupling on the loom 5 V (any ferrite bead is part of the loom, not the board), the LDO makes the quiet 3.3 V that powers BOTH ADCs and the bridge excitation", 88, 38)
text("Load is about 20 mA (bridges 2 x 4.7 mA + ADCs); the LDO dissipates about 35 mW.", 88, 96)

# PWR_FLAGs: nets fed through a passive part (loom header)
for i, net in enumerate(["+5V", "GND"]):
    fx, fy = snap(310 + i * 22), snap(70)
    instance("HastaDAQ:PWR_FLAG", next_ref("#FLG"), "PWR_FLAG", fx, fy, [1], (fx + 2, fy - 3), (fx + 2, fy - 1), "", bom=False)
    stub_label(net, fx, fy, "down", 2.54)

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
    vertical_part("C", "C", "DNP", 225, y, f"ADS{n}_A0", f"ADS{n}_A1", FP_C_SMALL)
    box(165, y - 16, 245, y + 16)
    text(f"ADS{n} input filter (optional: 1k links + 100nF)", 166, y - 18)
    # supply decoupling at the ADC
    vertical_part("C", "C", "10uF", 262, y, "+3V3", "GND", FP_C_CER)
    vertical_part("C", "C", "100nF", 282, y, "+3V3", "GND", FP_C_SMALL)
    box(254, y - 16, 295, y + 16)
    text(f"ADS{n} decoupling (at the ADC)", 255, y - 18)
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
     "   this 3V3 and are 3.3 V logic: the master must not drive them above 3.6 V.\n"
     "3. Input filters are optional: with the 0R links and no capacitor fitted there is none (original behaviour). Fit 1k in each\n"
     "   link and 100nF across A0-A1 for about an 800 Hz low-pass.\n"
     "4. ADS #2: bridge one address jumper on its back (resulting address unconfirmed; the main board's firmware scans at boot).\n"
     "5. Use shielded twisted cable for the gauge wires, shield to GND at this board only.",
     20, 277)

sg.write_outputs("${KIPRJMOD}/../hastadaq/HastaDAQ.pretty")
