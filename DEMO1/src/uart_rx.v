`timescale 1ns / 1ps
module uart_rx #(
    parameter CLK_FREQ = 27_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire       clk,
    input  wire       rstn,
    input  wire       rx,
    output reg [7:0]  rx_data,
    output reg        rx_valid
);
    // Số chu kỳ clk cho 1 bit data
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    
    localparam S_IDLE  = 3'd0;
    localparam S_START = 3'd1;
    localparam S_DATA  = 3'd2;
    localparam S_STOP  = 3'd3;
    
    reg [2:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg        rx_sync_1, rx_sync_2; // Chống Metastability
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rx_sync_1 <= 1'b1;
            rx_sync_2 <= 1'b1;
        end else begin
            rx_sync_1 <= rx;
            rx_sync_2 <= rx_sync_1;
        end
    end

    // main FSM
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state     <= S_IDLE;
            clk_count <= 0;
            bit_index <= 0;
            rx_data   <= 0;
            rx_valid  <= 0;
        end else begin
            rx_valid <= 0;
            case (state)
                S_IDLE: begin
                    clk_count <= 0;
                    bit_index <= 0;
                    if (rx_sync_2 == 1'b0) state <= S_START;
                end
                S_START: begin
                    if (clk_count == (CLKS_PER_BIT / 2)) begin
                        if (rx_sync_2 == 1'b0) begin
                            clk_count <= 0;
                            state     <= S_DATA;
                        end else state <= S_IDLE;
                    end else clk_count <= clk_count + 16'd1;
                end
                S_DATA: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 16'd1;
                    end else begin
                        clk_count <= 0;
                        rx_data[bit_index] <= rx_sync_2;
                        if (bit_index < 7) begin
                            bit_index <= bit_index + 3'd1;
                        end else begin
                            bit_index <= 0;
                            state     <= S_STOP;
                        end
                    end
                end
                S_STOP: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 16'd1;
                    end else begin
                        rx_valid <= 1'b1;
                        state    <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule