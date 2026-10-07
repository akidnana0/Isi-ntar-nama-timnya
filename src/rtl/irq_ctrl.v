// ============================================================================
// irq_ctrl.v : FPGA-side Interrupt Controller  (-> HPS GIC, e.g. IRQ 72)
//   IRQ_STATUS[0] job complete, [1] error, [2] FIFO overflow  (W1C from HPS)
//   fpga_irq = IRQ_GLOBAL_EN & |(IRQ_STATUS & IRQ_EN)
// ============================================================================
module irq_ctrl (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       job_done_pulse,
    input  wire       error_pulse,
    input  wire       fifo_ovf_pulse,
    input  wire [2:0] irq_en,
    input  wire       irq_global_en,
    input  wire [2:0] irq_w1c,
    output wire [2:0] irq_status,
    output wire       fpga_irq
);
    reg [2:0] st;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) st <= 3'b000;
        else        st <= (st & ~irq_w1c) | {fifo_ovf_pulse, error_pulse, job_done_pulse};

    assign irq_status = st;
    assign fpga_irq   = irq_global_en & (|(st & irq_en));
endmodule
