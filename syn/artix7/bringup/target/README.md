# target/ — OpenOCD configs for the STM32F429 trace source

OpenOCD scripts that configure the STM32 (debug target) side. Run via the
`../scripts/*.sh` wrappers, or directly with
`openocd -f interface/stlink.cfg -f target/stm32f4x.cfg -f <this>.cfg`.

- `etm_enable.cfg` — full 4-bit parallel ETM enable (GPIO AF mux + DEMCR +
  DBGMCU + TPIU + ETM). Branch broadcast OFF (ETMCR 0x880).
- `etm_itm_enable.cfg` — ETM + ITM variant.
- `etm_syncfreq.cfg` — ETM sync-frequency probing.
- `downclock.cfg` — lower HCLK (env `DIV`) so TRACECLK fits the 50 MSa/s logic
  analyser, without resetting (avoids firmware clock re-init).
- `gpio_toggle.cfg` — PE2 GPIO toggle smoke test (pin sanity).
- `jtag_probe.tcl`, `jtag_extest_probe.tcl` — JTAG boundary-scan probes.
