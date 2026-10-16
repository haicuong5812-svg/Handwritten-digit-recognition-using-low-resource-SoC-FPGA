`timescale 1ns / 1ps
//============================================================================
// CNN HARDWARE ACCELERATOR (6 -> 12 -> 300, SYNCHRONOUS BSRAM ROM)
//============================================================================
module cnn_hw_core #(
    parameter INPUT_H           = 28, 
    parameter INPUT_W           = 28, 
    parameter INPUT_CH          = 1,
    parameter CONV1_OUT_CH      = 6,  // 6 filters
    parameter CONV1_KERNEL      = 3,
    parameter CONV1_OUT_H       = INPUT_H - CONV1_KERNEL + 1, 
    parameter CONV1_OUT_W       = INPUT_W - CONV1_KERNEL + 1,
    parameter POOL1_SIZE        = 2,  
    parameter POOL1_OUT_H       = CONV1_OUT_H / POOL1_SIZE, 
    parameter POOL1_OUT_W       = CONV1_OUT_W / POOL1_SIZE,
    parameter CONV2_IN_CH       = CONV1_OUT_CH, 
    parameter CONV2_OUT_CH      = 12, // 12 filters
    parameter CONV2_KERNEL      = 3,
    parameter CONV2_OUT_H       = POOL1_OUT_H - CONV2_KERNEL + 1, 
    parameter CONV2_OUT_W       = POOL1_OUT_W - CONV2_KERNEL + 1,
    parameter POOL2_SIZE        = 2,  
    parameter POOL2_OUT_H       = CONV2_OUT_H / POOL2_SIZE, 
    parameter POOL2_OUT_W       = CONV2_OUT_W / POOL2_SIZE,
    parameter FLATTEN_SIZE      = POOL2_OUT_H * POOL2_OUT_W * CONV2_OUT_CH, // 300
    parameter BITS              = 15, 
    parameter FRAC_BITS         = 8,          
    parameter CONV1_WEIGHT_FILE = "conv1_w.mem", 
    parameter CONV1_BIAS_FILE   = "conv1_b.mem",
    parameter CONV2_WEIGHT_FILE = "conv2_w.mem", 
    parameter CONV2_BIAS_FILE   = "conv2_b.mem"
)(
    input  wire          clk,
    input  wire          pclk,
    input  wire          rstn,
    output reg           hw_done,
    input  wire [31:0]   arm_raddr,
    output wire [BITS:0] arm_rdata,
    input  wire          cam_we,
    input  wire [9:0]    cam_waddr,
    input  wire [5:0]    cam_wdata,   // 6-bit Grayscale từ image_processor
    input  wire          capture_done
);

    // =======================================================
    // 1. KHỞI TẠO TRỌNG SỐ ROM (ĐỌC ĐỒNG BỘ VÀO BSRAM)
    // =======================================================
    localparam C1_W_SZ = CONV1_OUT_CH * INPUT_CH * CONV1_KERNEL * CONV1_KERNEL;   // 54
    localparam C2_W_SZ = CONV2_OUT_CH * CONV2_IN_CH * CONV2_KERNEL * CONV2_KERNEL; // 648

    // conv1_w, conv1_b, conv2_b rất nhỏ nên giữ ở logic LUT; conv2_w (648 words) ép vào BSRAM
    (* syn_romstyle = "logic" *)     reg signed [BITS:0] conv1_w [0 : C1_W_SZ - 1]; 
    (* syn_romstyle = "logic" *)     reg signed [BITS:0] conv1_b [0 : CONV1_OUT_CH - 1];
    (* syn_romstyle = "block_rom" *) reg signed [BITS:0] conv2_w [0 : C2_W_SZ - 1]; 
    (* syn_romstyle = "logic" *)     reg signed [BITS:0] conv2_b [0 : CONV2_OUT_CH - 1];
    
    initial begin
        $readmemh(CONV1_WEIGHT_FILE, conv1_w); 
        $readmemh(CONV1_BIAS_FILE,   conv1_b);
        $readmemh(CONV2_WEIGHT_FILE, conv2_w); 
        $readmemh(CONV2_BIAS_FILE,   conv2_b);
    end

    wire [15:0] w_addr_1, w_addr_2;
    wire [9:0]  f_idx_1,  f_idx_2;

    // Đọc đồng bộ theo xung clk để Gowin tổng hợp conv2_w thành 1 BSRAM (0 LUT)
    reg signed [BITS:0] cur_w1, cur_b1;
    reg signed [BITS:0] cur_w2, cur_b2;

    always @(posedge clk) begin
        cur_w1 <= conv1_w[w_addr_1[5:0]];
        cur_b1 <= conv1_b[f_idx_1[2:0]];
        cur_w2 <= conv2_w[w_addr_2[9:0]];
        cur_b2 <= conv2_b[f_idx_2[3:0]];
    end

    // =======================================================
    // 2. BỘ NHỚ RAM ẢNH ĐẦU VÀO (28x28 QUY ĐỔI SANG Q8.8)
    // =======================================================
    wire [15:0] cp1_raddr;
    reg signed [BITS:0] cp1_rdata;
    
    (* syn_ramstyle = "block_ram" *) reg [15:0] image_ram [0:1023];

    wire [15:0] pixel_q88 = {7'b0, cam_wdata, cam_wdata[5:4], 1'b0} - 16'h0100;

    always @(posedge pclk) begin
        if (cam_we) begin
            image_ram[cam_waddr] <= pixel_q88;
        end
    end

    always @(posedge clk) begin
        cp1_rdata <= image_ram[cp1_raddr[9:0]];
    end

    // =======================================================
    // 3. HAI KHỐI BSRAM CHO POOL1 (1014 words) VÀ POOL2 (300 words)
    // =======================================================
    wire cp1_we; 
    wire [15:0] cp1_waddr; 
    wire [BITS:0] cp1_wdata; 
    wire pool1_done;

    wire [15:0] cp2_raddr; 
    wire [BITS:0] cp2_rdata;
    wire cp2_we; 
    wire [15:0] cp2_waddr; 
    wire [BITS:0] cp2_wdata; 
    wire [15:0] bram_rdata;

    wire [15:0] arm_word_addr = arm_raddr[15:0] >> 1; 

    gowin_dp_ram_Top pool1_ram (
        .clka(clk), .cea(cp1_we), .reseta(~rstn), .ada(cp1_waddr[9:0]), .din(cp1_wdata),
        .clkb(clk), .ceb(1'b1),   .resetb(~rstn), .oce(1'b1),           .adb(cp2_raddr[9:0]), .dout(cp2_rdata)
    );

    gowin_dp_ram_Top pool2_ram (
        .clka(clk), .cea(cp2_we), .reseta(~rstn), .ada(cp2_waddr[9:0]),     .din(cp2_wdata),
        .clkb(clk), .ceb(1'b1),   .resetb(~rstn), .oce(1'b1),               .adb(arm_word_addr[9:0]), .dout(bram_rdata)
    );

    // =======================================================
    // 4. BỘ MUX DÙNG CHUNG CONV_BUF
    // =======================================================
    wire        cb1_we, cb2_we;
    wire [15:0] cb1_waddr, cb2_waddr;
    wire [15:0] cb1_wdata, cb2_wdata;
    wire [15:0] cb1_raddr, cb2_raddr;
    wire [15:0] shared_cb_rdata;
    wire        cnn_start_signal;
    
    reg is_layer2;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) is_layer2 <= 1'b0;
        else if (cnn_start_signal) is_layer2 <= 1'b0;
        else if (pool1_done) is_layer2 <= 1'b1;
    end

    wire        shared_cb_we    = is_layer2 ? cb2_we : cb1_we;
    wire [9:0]  shared_cb_waddr = is_layer2 ? cb2_waddr[9:0] : cb1_waddr[9:0];
    wire [15:0] shared_cb_wdata = is_layer2 ? cb2_wdata : cb1_wdata;
    wire [9:0]  shared_cb_raddr = is_layer2 ? cb2_raddr[9:0] : cb1_raddr[9:0];

    gowin_dp_ram_Top shared_conv_buf_ram (
        .clka(clk), .cea(shared_cb_we), .reseta(~rstn), .ada(shared_cb_waddr), .din(shared_cb_wdata),
        .clkb(clk), .ceb(1'b1),         .resetb(~rstn), .oce(1'b1),              .adb(shared_cb_raddr), .dout(shared_cb_rdata)
    );

    // =======================================================
    // 5. KHỞI TẠO MODULE VÀ FSM KÍCH HOẠT
    // =======================================================
    wire layer2_done; 
    reg cap_done_d1, cap_done_d2;
    reg cnn_start;      
    assign cnn_start_signal = cnn_start;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            cap_done_d1 <= 0;
            cap_done_d2 <= 0;
            cnn_start   <= 0;
        end else begin
            cap_done_d1 <= capture_done;
            cap_done_d2 <= cap_done_d1;
            cnn_start   <= (cap_done_d1 && !cap_done_d2); 
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) hw_done <= 0;
        else if (layer2_done) hw_done <= 1'b1; 
        else if (!cap_done_d1) hw_done <= 1'b0;
    end

    assign arm_rdata = arm_raddr[15] ? {15'd0, hw_done} : bram_rdata;

    conv_pool_2d #(
        .IN_H(INPUT_H), .IN_W(INPUT_W), .IN_CH(INPUT_CH), .OUT_CH(CONV1_OUT_CH), .KERNEL_H(CONV1_KERNEL), .KERNEL_W(CONV1_KERNEL),
        .POOL_H(POOL1_SIZE), .POOL_W(POOL1_SIZE), .BITS(BITS), .FRAC_BITS(FRAC_BITS)
    ) u_conv_pool_1 (
        .clk(clk), .rstn(rstn), .activation_function(1'b1), 
        .weight_addr_out (w_addr_1),
        .filter_idx_out  (f_idx_1),
        .cur_weight      (cur_w1),
        .cur_bias        (cur_b1), 
        .in_raddr(cp1_raddr), .in_rdata(cp1_rdata), .out_we(cp1_we), .out_waddr(cp1_waddr), .out_wdata(cp1_wdata), .done(pool1_done),
        .cb_we(cb1_we), .cb_waddr(cb1_waddr), .cb_wdata(cb1_wdata), .cb_raddr(cb1_raddr), .cb_rdata(shared_cb_rdata),
        .start_fsm(cnn_start) 
    );

    conv_pool_2d #(
        .IN_H(POOL1_OUT_H), .IN_W(POOL1_OUT_W), .IN_CH(CONV2_IN_CH), .OUT_CH(CONV2_OUT_CH), .KERNEL_H(CONV2_KERNEL), .KERNEL_W(CONV2_KERNEL),
        .POOL_H(POOL2_SIZE), .POOL_W(POOL2_SIZE), .BITS(BITS), .FRAC_BITS(FRAC_BITS)
    ) u_conv_pool_2 (
        .clk(clk), .rstn(rstn), .activation_function(1'b1), 
        .weight_addr_out (w_addr_2),
        .filter_idx_out  (f_idx_2),
        .cur_weight      (cur_w2),
        .cur_bias        (cur_b2), 
        .in_raddr(cp2_raddr), .in_rdata(cp2_rdata), .out_we(cp2_we), .out_waddr(cp2_waddr), .out_wdata(cp2_wdata), .done(layer2_done),
        .cb_we(cb2_we), .cb_waddr(cb2_waddr), .cb_wdata(cb2_wdata), .cb_raddr(cb2_raddr), .cb_rdata(shared_cb_rdata),
        .start_fsm(pool1_done) 
    );
endmodule