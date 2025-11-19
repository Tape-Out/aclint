`ifndef CLINT_MMIO_V
`define CLINT_MMIO_V

`timescale 1ns/1ps

module clint_mmio #(
    parameter [31:0] BASE_ADDR = 32'h0200_0000,
    parameter [31:0] CLK_FREQ  = 32'd100_000_000    // 100MHz
)(
    input  wire         clk,
    input  wire         resetn,

    input  wire         mem_valid,
    input  wire         mem_instr,
    output reg          mem_ready,
    input  wire [31:0]  mem_addr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0]  mem_wdata,
    /* verilator lint_on  UNUSEDSIGNAL */
    input  wire [3:0]   mem_wstrb,
    output reg  [31:0]  mem_rdata,

    output reg  [63:0]  mtime,

    output reg          timer_irq,
    output reg          software_irq,
    input  wire         eoi
);

    reg [63:0] mtimecmp;        // timer irq= mtime >= mtimecmp
    reg [31:0] msip;            // software irq= any(msip)
    reg [63:0] mtime_next;
    reg [ 7:0] mtime_had_wt;

    reg timer_irq_next;
    reg software_irq_next;

    localparam [31:0]
        CLINT_MSIP     = BASE_ADDR + 32'h0000,     // sw irq pedding
        CLINT_MTIMECMP = BASE_ADDR + 32'h4000,     // MTIMECMP 0x4000(LO), 0x4004(HI)
        CLINT_MTIME    = BASE_ADDR + 32'hBFF8;     // MTIME    0xBFF8(LO), 0xBFFC(HI)

    wire [31:0] wmask = {
        {8{mem_wstrb[3]}},
        {8{mem_wstrb[2]}},
        {8{mem_wstrb[1]}},
        {8{mem_wstrb[0]}}
    };
    wire [31:0] wdata = mem_wdata & wmask;

    integer i;
    wire [63:0] next_time = mtime + 64'b1;

    always @(posedge clk) begin: TIMER_COUNTER
        if (!resetn) begin
            mtime <= 64'b0;
        end else begin
            if (|mtime_had_wt) begin
                for (i = 0; i < 8; i = i + 1) begin
                    if (mtime_had_wt[i]) begin
                        mtime[i*8 +: 8] <= mtime_next[i*8 +: 8];
                    end else begin
                        mtime[i*8 +: 8] <= next_time[i*8 +: 8];
                    end
                end
                mtime_had_wt <= 8'b0;
            end else begin
                mtime <= next_time;
            end

            mtime_next <= next_time;
        end
    end

    always @(*) begin: TIMER_IRQ_GEN
        timer_irq_next = (mtime >= mtimecmp);
    end

    always @(*) begin: SOFTWARE_IRQ_GEN
        software_irq_next = |msip;
    end

    always @(posedge clk) begin: IRQ_OUTPUT
        if (!resetn) begin
            timer_irq <= 1'b0;
            software_irq <= 1'b0;
        end else if (eoi) begin
            timer_irq <= 1'b0;
            software_irq <= 1'b0;
        end else begin
            timer_irq <= timer_irq_next;
            software_irq <= software_irq_next;
        end
    end

    always @(posedge clk) begin
        mem_ready <= !resetn ? 0 : mem_valid && !mem_instr;
    end

    always @(posedge clk) begin: MMIO_READ
        if (!resetn) begin
            mem_rdata <= 32'b0;
        end else begin
            if (mem_valid && !mem_instr && mem_wstrb == 4'b0) begin
                case (mem_addr)
                    CLINT_MSIP:                     mem_rdata <= msip;
                    CLINT_MTIMECMP:                 mem_rdata <= mtimecmp[31:0];
                    CLINT_MTIMECMP + 32'h4:         mem_rdata <= mtimecmp[63:32];
                    CLINT_MTIME:                    mem_rdata <= mtime[31:0];
                    CLINT_MTIME + 32'h4:            mem_rdata <= mtime[63:32];
                    default:                        mem_rdata <= 32'b0;
                endcase
            end else begin
                mem_rdata <= 32'b0;
            end
        end
    end

    always @(posedge clk) begin: MMIO_WRITE
        if (!resetn) begin
            mtimecmp        <= 0;
            msip            <= 0;
            mtime_had_wt    <= 0;
            mtime_next      <= 0;
        end else begin
            if (mem_valid && !mem_instr && mem_wstrb != 4'b0) begin
                case (mem_addr)
                    CLINT_MSIP: begin
                        if (mem_wstrb[0]) msip[7:0]   <= wdata[7:0];
                        if (mem_wstrb[1]) msip[15:8]  <= wdata[15:8];
                        if (mem_wstrb[2]) msip[23:16] <= wdata[23:16];
                        if (mem_wstrb[3]) msip[31:24] <= wdata[31:24];
                    end
                    CLINT_MTIMECMP: begin
                        if (mem_wstrb[0]) mtimecmp[7:0]   <= wdata[7:0];
                        if (mem_wstrb[1]) mtimecmp[15:8]  <= wdata[15:8];
                        if (mem_wstrb[2]) mtimecmp[23:16] <= wdata[23:16];
                        if (mem_wstrb[3]) mtimecmp[31:24] <= wdata[31:24];
                    end
                    CLINT_MTIMECMP + 32'h4: begin
                        if (mem_wstrb[0]) mtimecmp[39:32] <= wdata[7:0];
                        if (mem_wstrb[1]) mtimecmp[47:40] <= wdata[15:8];
                        if (mem_wstrb[2]) mtimecmp[55:48] <= wdata[23:16];
                        if (mem_wstrb[3]) mtimecmp[63:56] <= wdata[31:24];
                    end
                    CLINT_MTIME: begin
                        if (mem_wstrb[0]) begin
                            mtime_next[7:0] <= wdata[7:0];
                            mtime_had_wt[0] <= 1;
                        end else mtime_had_wt[0] <= 0;
                        if (mem_wstrb[1]) begin
                            mtime_next[15:8] <= wdata[15:8];
                            mtime_had_wt[1] <= 1;
                        end else mtime_had_wt[1] <= 0;
                        if (mem_wstrb[2]) begin
                            mtime_next[23:16] <= wdata[23:16];
                            mtime_had_wt[2] <= 1;
                        end else mtime_had_wt[2] <= 0;
                        if (mem_wstrb[3]) begin
                            mtime_next[31:24] <= wdata[31:24];
                            mtime_had_wt[3] <= 1;
                        end else mtime_had_wt[3] <= 0;
                    end
                    CLINT_MTIME + 32'h4: begin
                        if (mem_wstrb[0]) begin
                            mtime_next[39:32] <= wdata[7:0];
                            mtime_had_wt[4] <= 1;
                        end else mtime_had_wt[4] <= 0;
                        if (mem_wstrb[1]) begin
                            mtime_next[47:40] <= wdata[15:8];
                            mtime_had_wt[5] <= 1;
                        end else mtime_had_wt[5] <= 0;
                        if (mem_wstrb[2]) begin
                            mtime_next[55:48] <= wdata[23:16];
                            mtime_had_wt[6] <= 1;
                        end else mtime_had_wt[6] <= 0;
                        if (mem_wstrb[3]) begin
                            mtime_next[63:56] <= wdata[31:24];
                            mtime_had_wt[7] <= 1;
                        end else mtime_had_wt[7] <= 0;
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule

`endif
