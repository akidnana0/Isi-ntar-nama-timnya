# DE10-Nano (Cyclone V SE 5CSEBA6U23I7) - sha512_accel_top
#
# PENTING: `get_ports` hanya valid jika sha512_accel_top adalah top-level Quartus.
# Jika modul ini ada di dalam sistem Platform Designer (HPS + bridge), core_clk dan
# h2f_axi_clk BUKAN port top-level: clock berasal dari PLL / h2f_user clock HPS.
# Pada kasus itu hapus dua create_clock di bawah, aktifkan derive_pll_clocks, dan
# ganti {core_clk}/{h2f_axi_clk} pada set_clock_groups dengan nama clock hasil
# `report_clocks` (mis. *pll*|outclk_wire[0]).
#
# core_clk   : SHA-512 plane + control plane + DMA reader
#              (lwh2f bridge dan port AXI baca DMA harus memakai clock ini)
# h2f_axi_clk: h2f write slave + result writer (sisi lain FIFO dual-clock)
create_clock -name core_clk    -period 20.000 [get_ports {core_clk}]
create_clock -name h2f_axi_clk -period 10.000 [get_ports {h2f_axi_clk}]
# derive_pll_clocks
derive_clock_uncertainty

# Kedua domain hanya bertemu lewat FIFO gray-code, pulse/level synchronizer,
# reset synchronizer, dan register kuasi-statis (RESULT_BASE/RESULT_SLOTS).
set_clock_groups -asynchronous -group [get_clocks {core_clk}] -group [get_clocks {h2f_axi_clk}]

# Batasi delay bus pointer gray (semua bit harus tiba dalam satu periode tujuan).
set_net_delay -max 5.000 -from [get_registers {*u_fifo|wgray[*]}] -to [get_registers {*u_fifo|wg_r1[*]}]
set_net_delay -max 5.000 -from [get_registers {*u_fifo|rgray[*]}] -to [get_registers {*u_fifo|rg_w1[*]}]
