`timescale 1ns / 1ps
//============================================================================
// CONVOLUTION & POOLING 2D MODULE (OPTIMIZED DSP & LUT BALANCING)
//============================================================================
(* syn_dspstyle = "logic" *)
module conv_pool_2d #(
    parameter IN_H       = 28,
    parameter IN_W       = 28,   
    parameter IN_CH      = 1, 
    parameter OUT_CH     = 2,
    parameter KERNEL_H   = 3,       
    parameter KERNEL_W   = 3,    
    parameter POOL_H     = 2,           
    parameter POOL_W     = 2,
    parameter CONV_OUT_H = IN_H - KERNEL_H + 1,                 
    parameter CONV_OUT_W = IN_W - KERNEL_W + 1,
    parameter POOL_OUT_H = CONV_OUT_H / POOL_H,                 
    parameter POOL_OUT_W = CONV_OUT_W / POOL_W,
    parameter BITS       = 15,      
    parameter FRAC_BITS  = 8
)(
    input  wire                  clk,
    input  wire                  rstn,
    input  wire                  activation_function,     
    input  wire                  start_fsm,   
    output wire [15:0]           weight_addr_out,
    output wire [9:0]            filter_idx_out,
    input  wire signed [BITS:0]  cur_weight,
    input  wire signed [BITS:0]  cur_bias,
    output reg  [15:0]           in_raddr,    
    input  wire [BITS:0]         in_rdata,    
    output reg                   out_we,      
    output reg  [15:0]           out_waddr,   
    output reg  [BITS:0]         out_wdata,   
    output reg                   done,        
    output wire                  cb_we,
    output wire [15:0]           cb_waddr,
    output wire [15:0]           cb_wdata,
    output wire [15:0]           cb_raddr,
    input  wire [15:0]           cb_rdata
);

    localparam TAP_COUNT      = IN_CH * KERNEL_H * KERNEL_W;
    localparam CONV_POSITIONS = CONV_OUT_H * CONV_OUT_W;
    localparam POOL_OUT_POS   = POOL_OUT_H * POOL_OUT_W;
    localparam POOL_ELEMENTS  = POOL_H * POOL_W;

    reg         conv_buf_we;
    reg  [15:0] conv_buf_waddr;
    reg  [15:0] conv_buf_wdata;
    reg  [15:0] conv_buf_raddr;

    assign cb_we    = conv_buf_we;
    assign cb_waddr = conv_buf_waddr;
    assign cb_wdata = conv_buf_wdata;
    assign cb_raddr = conv_buf_raddr;

    localparam S_IDLE=4'd0, S_CONV_ADDR=4'd1, S_CONV_WAIT=4'd2, S_CONV_MAC=4'd3, S_CONV_STORE=4'd4;
    localparam S_POOL_ADDR=4'd5, S_POOL_WAIT=4'd6, S_POOL_COMPARE=4'd7, S_POOL_STORE=4'd8, S_DONE=4'd9;

    reg [3:0] state;
    reg [9:0] filter_idx, conv_out_row, conv_out_col, conv_pos;
    reg [9:0] ch_cnt, kr_cnt, kc_cnt;
    reg [9:0] pool_out_row, pool_out_col, pool_pos, pool_r_cnt, pool_c_cnt, pool_counter;

    // Ép toàn bộ các phép nhân tính địa chỉ sang mạch cộng ALU/LUT (Không dùng DSP)
    (* syn_dspstyle = "logic" *) wire [31:0] data_idx_temp = ch_cnt * (IN_H * IN_W) + (conv_out_row + kr_cnt) * IN_W + (conv_out_col + kc_cnt);
    wire [15:0] data_idx = data_idx_temp[15:0];  

    // Tối ưu nhân 9 (<<3 + 1) và nhân 3 (<<1 + 1) bằng dịch bit
    wire [15:0] ch_times_9 = ( {6'd0, ch_cnt} << 3 ) + {6'd0, ch_cnt};
    wire [15:0] kr_times_3 = ( {6'd0, kr_cnt} << 1 ) + {6'd0, kr_cnt};
    wire [15:0] tap_idx    = ch_times_9 + kr_times_3 + {6'd0, kc_cnt};
    
    (* syn_dspstyle = "logic" *) wire [31:0] weight_addr_temp = filter_idx * TAP_COUNT + tap_idx;
    wire [15:0] weight_addr = weight_addr_temp[15:0];

    assign weight_addr_out = weight_addr;
    assign filter_idx_out  = filter_idx;

    // Pipeline tính toán MAC
    reg  signed [BITS+24:0] acc;
    wire signed [BITS+24:0] biased = acc + $signed(cur_bias);
    (* syn_dspstyle = "logic" *) wire signed [(2*BITS)+1:0] full_product = $signed(in_rdata) * cur_weight;
    wire signed [BITS+16:0] prod_q = full_product >>> FRAC_BITS;

    // Tối ưu nhân 2 (POOL_H=2, POOL_W=2) bằng dịch bit
    wire [15:0] pool_in_row = ( {6'd0, pool_out_row} << 1 ) + {6'd0, pool_r_cnt};
    wire [15:0] pool_in_col = ( {6'd0, pool_out_col} << 1 ) + {6'd0, pool_c_cnt};

    (* syn_dspstyle = "logic" *) wire [31:0] cb_raddr_temp  = pool_in_row * CONV_OUT_W + pool_in_col;
    wire [15:0] cb_raddr_calc = cb_raddr_temp[15:0];
    
    (* syn_dspstyle = "logic" *) wire [31:0] out_waddr_temp = filter_idx * POOL_OUT_POS + pool_pos;
    wire [15:0] out_waddr_calc = out_waddr_temp[15:0];

    reg signed [BITS:0] cur_max;

    always @(posedge clk) begin
        if (!rstn) begin
            state        <= S_IDLE;
            filter_idx   <= 0; conv_out_row <= 0; conv_out_col <= 0; conv_pos <= 0;
            ch_cnt       <= 0; kr_cnt       <= 0; kc_cnt       <= 0;
            pool_out_row <= 0; pool_out_col <= 0; pool_pos     <= 0;
            pool_r_cnt   <= 0; pool_c_cnt   <= 0; pool_counter <= 0;
            acc          <= 0; done         <= 0;
            out_we       <= 0; conv_buf_we  <= 0;
            cur_max      <= {1'b1, {BITS{1'b0}}};
            in_raddr     <= 0; out_waddr    <= 0;
        end else begin
            out_we      <= 1'b0;
            conv_buf_we <= 1'b0;
            done        <= 1'b0;

            case (state)
                S_IDLE: begin
                    filter_idx <= 0; conv_out_row <= 0; conv_out_col <= 0; conv_pos <= 0;
                    ch_cnt     <= 0; kr_cnt       <= 0; kc_cnt       <= 0;
                    acc        <= 0; 
                    if (start_fsm) state <= S_CONV_ADDR; 
                end

                S_CONV_ADDR: begin in_raddr <= data_idx; state <= S_CONV_WAIT; end
                S_CONV_WAIT: begin state <= S_CONV_MAC; end
                S_CONV_MAC: begin
                    acc <= acc + prod_q;
                    if (kc_cnt == (KERNEL_W[9:0] - 10'd1)) begin
                        kc_cnt <= 0;
                        if (kr_cnt == (KERNEL_H[9:0] - 10'd1)) begin
                            kr_cnt <= 0;
                            if (ch_cnt == (IN_CH[9:0] - 10'd1)) begin
                                ch_cnt <= 0; state <= S_CONV_STORE;
                            end else begin ch_cnt <= ch_cnt + 10'd1; state <= S_CONV_ADDR; end
                        end else begin kr_cnt <= kr_cnt + 10'd1; state <= S_CONV_ADDR; end
                    end else begin kc_cnt <= kc_cnt + 10'd1; state <= S_CONV_ADDR; end
                end

                S_CONV_STORE: begin
                    conv_buf_waddr <= conv_pos;
                    if (activation_function && biased <= 0) conv_buf_wdata <= 0;
                    else if (biased > ((1<<BITS)-1))        conv_buf_wdata <= (1<<BITS)-1;
                    else                                    conv_buf_wdata <= biased[BITS:0];
                    conv_buf_we <= 1'b1; acc <= 0;
                    
                    if (conv_pos == (CONV_POSITIONS[9:0] - 10'd1)) begin
                        pool_out_row <= 0; pool_out_col <= 0; pool_pos <= 0;
                        pool_r_cnt   <= 0; pool_c_cnt   <= 0; pool_counter <= 0;
                        cur_max      <= {1'b1, {BITS{1'b0}}}; state <= S_POOL_ADDR;
                    end else begin
                        conv_pos <= conv_pos + 10'd1;
                        if (conv_out_col == (CONV_OUT_W[9:0] - 10'd1)) begin
                            conv_out_col <= 0; conv_out_row <= conv_out_row + 10'd1;
                        end else begin conv_out_col <= conv_out_col + 10'd1; end
                        state <= S_CONV_ADDR;
                    end
                end

                S_POOL_ADDR: begin
                    conv_buf_raddr <= cb_raddr_calc;
                    state          <= S_POOL_WAIT;
                end
                S_POOL_WAIT: begin state <= S_POOL_COMPARE; end
                S_POOL_COMPARE: begin
                    if ($signed(cb_rdata[BITS:0]) > $signed(cur_max)) cur_max <= cb_rdata[BITS:0];
                    
                    if (pool_counter == (POOL_ELEMENTS[9:0] - 10'd1)) begin
                        pool_counter <= 0; pool_r_cnt <= 0; pool_c_cnt <= 0; state <= S_POOL_STORE;
                    end else begin
                        pool_counter <= pool_counter + 10'd1;
                        if (pool_c_cnt == (POOL_W[9:0] - 10'd1)) begin
                            pool_c_cnt <= 0; pool_r_cnt <= pool_r_cnt + 10'd1;
                        end else begin pool_c_cnt <= pool_c_cnt + 10'd1; end
                        state <= S_POOL_ADDR;
                    end
                end
                S_POOL_STORE: begin
                    out_waddr <= out_waddr_calc;
                    out_wdata <= cur_max; out_we <= 1'b1; cur_max <= {1'b1, {BITS{1'b0}}};
                    
                    if (pool_pos == (POOL_OUT_POS[9:0] - 10'd1)) begin
                        if (filter_idx == (OUT_CH[9:0] - 10'd1)) begin
                            state <= S_DONE;
                        end else begin
                            filter_idx <= filter_idx + 10'd1; conv_out_row <= 0; conv_out_col <= 0; conv_pos <= 0; state <= S_CONV_ADDR;
                        end
                    end else begin
                        pool_pos <= pool_pos + 10'd1;
                        if (pool_out_col == (POOL_OUT_W[9:0] - 10'd1)) begin
                            pool_out_col <= 0; pool_out_row <= pool_out_row + 10'd1;
                        end else begin pool_out_col <= pool_out_col + 10'd1; end
                        state <= S_POOL_ADDR;
                    end
                end
                S_DONE: begin 
                    done  <= 1'b1; 
                    state <= S_IDLE; 
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule