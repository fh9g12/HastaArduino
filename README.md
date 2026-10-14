# HastaArduino

Bench- and wind-tunnel instrumentation for a free-to-pitch / control-surface aircraft model: firmware for a Pimoroni Pico Plus 2 (WiFi via an RM2 breakout) and the MATLAB package (`wt.hasta`) that drives it over SCPI/TCP.

**Documentation: [docs/README.md](docs/README.md)** covers the architecture, wire protocol, MATLAB package, coding conventions, testing approach, safety rules for anyone (human or agent) changing or running it, and the known gotchas and open items.

Quick orientation:

* `HastaDAQ/` is the flagship firmware; `HastaDrivers/` the shared driver library.
* `matlab/hastadaq/` is the MATLAB side (`+wt/+hasta`, `+wt/+runNum`, `+scripts`).
* `kicad/` and `wiring/` hold the schematic and cable diagrams.
