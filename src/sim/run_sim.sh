#!/bin/bash
# Regresi end-to-end sha512_accel_top (Icarus Verilog). Jalankan dari folder sim/.
#   ./run_sim.sh            -> semua tes
# Referensi digest dihitung dengan Python hashlib.sha512.
set -e
RTL="../rtl/sha512_accel_top.v ../rtl/sha512_core.v ../rtl/block_splitter.v ../rtl/work_dispatcher.v
     ../rtl/result_aggregator.v ../rtl/core_manager.v ../rtl/system_fsm.v ../rtl/irq_ctrl.v
     ../rtl/cdc_utils.v ../rtl/axi3_input_if.v ../rtl/axi3_output_if.v ../rtl/axi3_dma_reader.v
     ../rtl/axil_slave_fsm.v ../rtl/ctrl_regs.v"
run() { iverilog -g2005 "$@" -o t.vvp $TB $RTL && vvp -n t.vvp | head -3 | grep -E "STATUS|RESET|IDLE|ERROR RUN"; python3 check.py $OFF | tail -1; }
OFF=""
TB=tb_top.v
for mode in edge big small; do python3 gen.py $mode
  for n in 1 4 12; do echo "== pull mode, $mode docs, N=$n"; run -DNC=$n; done; done
python3 gen.py edge; TB=tb_stress.v
echo "== random backpressure";               run -DNC=6 -DSEED=13
echo "== SLVERR mid-burst -> RESET -> rerun"; run -DNC=4 -DSEED=5 -DERRBEAT=37
echo "== RESET in the middle of a run";       run -DNC=5 -DSEED=9 -DMIDRST=777
TB=tb_push.v; OFF=100
echo "== push mode (AXI3 slave, job ID = sequence number)"; run -DNC=4
