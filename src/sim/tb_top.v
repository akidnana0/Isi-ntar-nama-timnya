`timescale 1ns/1ps
`include "params.vh"
`ifndef NC
`define NC 12
`endif
module tb;
  reg core_clk=0, axi_clk=0, rst_n=0;
  always #10 core_clk=~core_clk;   // 50 MHz
  always #5  axi_clk=~axi_clk;     // 100 MHz
  reg [7:0] mem [0:'h1FFFF];
  // AXI-Lite master
  reg [7:0] awaddr=0, araddr=0; reg awvalid=0, wvalid=0, bready=0, arvalid=0, rready=0;
  reg [31:0] wdata=0; reg [3:0] wstrb=0;
  wire awready, wready, bvalid, arready, rvalid; wire [1:0] bresp, rresp; wire [31:0] rdata;
  // DMA read slave (core_clk)
  wire [11:0] arid; wire [31:0] rd_araddr; wire [3:0] arlen; wire [2:0] arsize; wire [1:0] arburst;
  wire rd_arvalid, rd_rready; reg rd_active=0; reg [31:0] rd_addr; reg [4:0] rd_left;
  wire [63:0] rd_data = {mem[rd_addr+7],mem[rd_addr+6],mem[rd_addr+5],mem[rd_addr+4],mem[rd_addr+3],mem[rd_addr+2],mem[rd_addr+1],mem[rd_addr]};
  integer bursts_4k_cross=0;
  always @(posedge core_clk) if (rd_arvalid && !rd_active) begin
      rd_active<=1; rd_addr<=rd_araddr; rd_left<=arlen+1;
      if ((rd_araddr>>12) != ((rd_araddr + (arlen+1)*8 - 1)>>12)) bursts_4k_cross=bursts_4k_cross+1;
    end else if (rd_active && rd_rready) begin
      rd_addr<=rd_addr+8; rd_left<=rd_left-1; if (rd_left==1) rd_active<=0; end
  // result write slave (axi_clk)
  wire [11:0] wr_awid, wr_wid; wire [31:0] wr_awaddr; wire [3:0] wr_awlen; wire [2:0] wr_awsize; wire [1:0] wr_awburst;
  wire wr_awvalid, wr_wlast, wr_wvalid, wr_bready; wire [63:0] wr_wdata; wire [7:0] wr_wstrb;
  reg [1:0] ws=0; reg [31:0] wa; integer k;
  always @(posedge axi_clk) case (ws)
    0: if (wr_awvalid) begin wa<=wr_awaddr; ws<=1; end
    1: if (wr_wvalid) begin for (k=0;k<8;k=k+1) mem[wa+k]<=wr_wdata[8*k+:8]; wa<=wa+8; if (wr_wlast) ws<=2; end
    2: if (wr_bready) ws<=0;
  endcase
  wire irq;
  sha512_accel_top #(.N(`NC)) dut (
    .core_clk(core_clk), .core_rst_n(rst_n), .h2f_axi_clk(axi_clk), .h2f_axi_rst_n(rst_n),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .s_axi_awid(12'd0), .s_axi_awaddr(32'd0), .s_axi_awlen(4'd0), .s_axi_awsize(3'd0), .s_axi_awburst(2'd0),
    .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_wid(12'd0), .s_axi_wdata(64'd0), .s_axi_wstrb(8'd0),
    .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b0),
    .m_rd_arid(arid), .m_rd_araddr(rd_araddr), .m_rd_arlen(arlen), .m_rd_arsize(arsize), .m_rd_arburst(arburst),
    .m_rd_arvalid(rd_arvalid), .m_rd_arready(!rd_active), .m_rd_rid(12'd0), .m_rd_rdata(rd_data), .m_rd_rresp(2'b00),
    .m_rd_rlast(rd_active && rd_left==1), .m_rd_rvalid(rd_active), .m_rd_rready(rd_rready),
    .m_wr_awid(wr_awid), .m_wr_awaddr(wr_awaddr), .m_wr_awlen(wr_awlen), .m_wr_awsize(wr_awsize), .m_wr_awburst(wr_awburst),
    .m_wr_awvalid(wr_awvalid), .m_wr_awready(ws==0), .m_wr_wid(wr_wid), .m_wr_wdata(wr_wdata), .m_wr_wstrb(wr_wstrb),
    .m_wr_wlast(wr_wlast), .m_wr_wvalid(wr_wvalid), .m_wr_wready(ws==1), .m_wr_bid(12'd0), .m_wr_bresp(2'b00),
    .m_wr_bvalid(ws==2), .m_wr_bready(wr_bready), .fpga_irq(irq));

  task axil_wr(input [7:0] a, input [31:0] d); reg ha, hw; begin
    @(negedge core_clk); awaddr=a; awvalid=1; wdata=d; wvalid=1; wstrb=4'hF; bready=1;
    while (awvalid|wvalid) begin @(negedge core_clk); ha=awvalid&awready; hw=wvalid&wready;
      @(posedge core_clk); #1; if(ha) awvalid=0; if(hw) wvalid=0; end
    while (1) begin @(negedge core_clk); if (bvalid) begin @(posedge core_clk); #1; bready=0; disable axil_wr; end end
  end endtask
  task axil_rd(input [7:0] a, output [31:0] d); reg h; begin
    @(negedge core_clk); araddr=a; arvalid=1; rready=1;
    while (arvalid) begin @(negedge core_clk); h=arvalid&arready; @(posedge core_clk); #1; if(h) arvalid=0; end
    while (1) begin @(negedge core_clk); if (rvalid) begin d=rdata; @(posedge core_clk); #1; rready=0; disable axil_rd; end end
  end endtask

  integer cyc=0; always @(posedge core_clk) cyc=cyc+1;
  integer maxbusy=0, nb; always @(posedge core_clk) begin nb=0; for(k=0;k<`NC;k=k+1) nb=nb+dut.core_busy[k]; if(nb>maxbusy) maxbusy=nb; end
  reg [31:0] st; integer t0, i, j, f;
  initial begin
    $readmemh("mem.hex", mem);
    #100 rst_n=1; #200;
    axil_wr(8'h28, `RES_BASE); axil_wr(8'h2C, `NJOBS);
    axil_wr(8'h14, `JOB_BASE); axil_wr(8'h18, `NJOBS);
    axil_wr(8'h08, (1<<`NC)-1);
    t0=cyc; axil_wr(8'h00, 32'h1);
    st=0;
    while (!(st[1]|st[2]) && cyc-t0 < 2000000) axil_rd(8'h04, st);
    $display("STATUS=%h after %0d core cycles, max cores busy simultaneously=%0d, 4KB-crossing bursts=%0d", st, cyc-t0, maxbusy, bursts_4k_cross);
    axil_rd(8'h24, st); $display("ERROR_FLAGS=%h", st);
    f=$fopen("got.txt","w");
    for (i=0;i<`NJOBS;i=i+1) begin
      $fwrite(f,"%0x ", {mem[`RES_BASE+128*i+1],mem[`RES_BASE+128*i]});
      for (j=1;j<=8;j=j+1) $fwrite(f,"%016x", {mem[`RES_BASE+128*i+8*j+7],mem[`RES_BASE+128*i+8*j+6],mem[`RES_BASE+128*i+8*j+5],mem[`RES_BASE+128*i+8*j+4],mem[`RES_BASE+128*i+8*j+3],mem[`RES_BASE+128*i+8*j+2],mem[`RES_BASE+128*i+8*j+1],mem[`RES_BASE+128*i+8*j]});
      $fwrite(f,"\n");
    end
    $fclose(f); $finish;
  end
endmodule
