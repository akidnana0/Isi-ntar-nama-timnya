# DE10-Nano (Cyclone V SE 5CSEBA6U23I7) - sha512_accel_top
# core_clk   : SHA-512 plane + control plane + DMA reader (lwh2f / f2h-read bridges
#              must be clocked by this same clock)
# h2f_axi_clk: h2f write slave + f2h write master side of the dual-clock FIFOs
create_clock -name core_clk    -period 20.000 [get_ports {core_clk}]
create_clock -name h2f_axi_clk -period 10.000 [get_ports {h2f_axi_clk}]
derive_clock_uncertainty

# The two domains only meet through gray-code FIFOs, pulse/reset synchronizers
set_clock_groups -asynchronous -group {core_clk} -group {h2f_axi_clk}
