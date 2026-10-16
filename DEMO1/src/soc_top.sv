`timescale 1ns / 1ps
module soc_top (
    input  wire clk,                
    input  wire rstn,               
    output wire uart_tx,            
    input  wire uart_rx,
    output wire       cam_xclk,     
    input  wire       cam_pclk,     
    input  wire       cam_vsync,    
    input  wire       cam_href,     
    input  wire [7:0] cam_data,     
    output wire       cam_scl,      
    inout  wire       cam_sda,      
    input  wire       btn_capture,     
    output wire       led_status,
    
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_data_p,
    output wire [2:0] tmds_data_n
);

    // 1. TẠO XUNG NHỊP CHO CAMERA (24 MHz)
    wire clk_24m;
    Gowin_PLLVR u_pll_cam (
        .clkin(clk),
        .clkout(clk_24m)
    );
    assign cam_xclk = clk_24m;

    // 2. TỰ ĐỘNG CẤU HÌNH CAMERA (I2C)
    OV2640_Controller u_ov2640_ctrl (
        .clk(clk),
        .resend(~rstn),
        .config_finished(),
        .sioc(cam_scl),
        .siod(cam_sda),
        .reset(),
        .pwdn()
    );

    // 3. MẠCH CHỐNG RUNG NÚT NHẤN (DEBOUNCE)
    reg [19:0] debounce_cnt;
    reg btn_stable;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            debounce_cnt <= 0;
            btn_stable <= 1'b1; 
        end else begin
            if (btn_capture == btn_stable)
                debounce_cnt <= 0;
            else begin
                debounce_cnt <= debounce_cnt + 20'd1;
                if (debounce_cnt == 20'd500_000) begin 
                    btn_stable <= btn_capture;
                    debounce_cnt <= 0;
                end
            end
        end
    end

    // 4. HỆ THỐNG THU HÌNH VÀ XỬ LÝ ẢNH ĐA MỨC XÁM (EDGE AI VISION)
    wire        pixel_valid;
    wire [15:0] pixel_rgb565;

    dvp_capture u_dvp (
        .pclk        (cam_pclk),
        .rst_n       (rstn),
        .vsync       (cam_vsync),
        .href        (cam_href),
        .pix_data_in (cam_data),
        .pixel_valid (pixel_valid),
        .pixel_rgb565(pixel_rgb565)
    );

    wire        cnn_we;
    wire [9:0]  cnn_waddr;
    wire [5:0]  cnn_wdata;   // 6-bit Grayscale
    wire        capture_done;
    wire [9:0]  debug_y; 

    reg         arm_trig;
    wire        capture_req = arm_trig | (~btn_stable);

    image_processor u_img_proc (
        .pclk        (cam_pclk),
        .vsync       (cam_vsync),
        .href        (cam_href),
        .pixel_valid (pixel_valid),
        .pixel_rgb565(pixel_rgb565),
        .capture_btn (capture_req),
        .ram_write_en(cnn_we),
        .ram_addr    (cnn_waddr),
        .ram_data    (cnn_wdata),
        .capture_done(capture_done),
        .debug_y     (debug_y)      
    );

    // 5. BỘ ĐIỀU PHỐI BUS APB VÀ ARM CORTEX-M3
    wire        master_psel1;
    wire        master_penable;
    wire        master_pwrite;
    wire        master_pready1 = 1'b1;
    wire [7:0]  master_paddr;
    wire [31:0] master_pwdata;
    wire [31:0] master_prdata1;
    wire [3:0]  master_pstrb; 
    wire [2:0]  master_pprot; 
    
    reg [8:0] fifo_ptr;      // 9-bit đếm đủ 300 phần tử Flatten
    reg [3:0] final_digit; 

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            fifo_ptr    <= 9'd0;
            final_digit <= 4'd1;
            arm_trig    <= 1'b0;
        end else if (master_psel1 && master_penable && master_pready1) begin
            if (master_pwrite) begin
                if (master_paddr == 8'hE4)      final_digit <= master_pwdata[3:0];
                else if (master_paddr == 8'hE8) arm_trig    <= master_pwdata[0];
            end else begin
                if (master_paddr == 8'hE0)      fifo_ptr <= 9'd0; 
                else if (master_paddr == 8'h00) fifo_ptr <= fifo_ptr + 9'd1; 
            end
        end
    end

    wire [31:0] cnn_raddr;
    wire [15:0] cnn_rdata; 
    wire [31:0] cnn_rdata_ext;

    assign cnn_raddr = (master_paddr == 8'hE0) ? 32'h0000_8000 : {22'd0, fifo_ptr, 1'b0};          
    assign cnn_rdata_ext = { {16{cnn_rdata[15]}}, cnn_rdata };      
    assign master_prdata1 = (master_paddr == 8'hE8) ? {31'd0, ~btn_stable} :
                            (master_paddr == 8'hEC) ? {22'd0, debug_y}     :
                            cnn_rdata_ext; 

    core_arm_m3_Top u_empu (
        .sys_clk(clk), .reset_n(rstn), .uart0_txd(uart_tx), .uart0_rxd(uart_rx),
        .master_pclk(), .master_prst(), .master_penable(master_penable),
        .master_paddr(master_paddr), .master_pwrite(master_pwrite),
        .master_pwdata(master_pwdata), .master_pstrb(master_pstrb),
        .master_pprot(master_pprot), .master_psel1(master_psel1),
        .master_prdata1(master_prdata1), .master_pready1(master_pready1), .master_pslverr1(1'b0)
    );

    // 6. GIA TỐC PHẦN CỨNG CNN (6 -> 12 -> 300)
    wire hw_done;
    cnn_hw_core #(
        .INPUT_H(28), .INPUT_W(28), .INPUT_CH(1), .BITS(15)
    ) u_cnn_hw_accelerator (
        .clk           (clk),
        .pclk          (cam_pclk),
        .rstn          (rstn), 
        .hw_done       (hw_done),
        .arm_raddr     (cnn_raddr),                        
        .arm_rdata     (cnn_rdata),         
        .cam_we        (cnn_we),
        .cam_waddr     (cnn_waddr),
        .cam_wdata     (cnn_wdata),
        .capture_done  (capture_done) 
    );

    // 7. CẢNH BÁO LED TRÊN KIT & XUẤT HÌNH HDMI KÈM BOUNDING BOX
    reg [21:0] blink_cnt;
    reg        led_blink;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            blink_cnt <= 22'd0;
            led_blink <= 1'b0;
        end else begin
            if (blink_cnt >= 22'd2_700_000) begin
                blink_cnt <= 22'd0;
                led_blink <= ~led_blink;
            end else begin
                blink_cnt <= blink_cnt + 22'd1;
            end
        end
    end

    assign led_status = (final_digit == 4'd0) ? led_blink : 1'b0;
    
    wire clk_126m;
    wire clk_25m; 

    video_pll u_video_pll (
        .clkin(clk),              
        .clkout(clk_126m)         
    );
    
    Gowin_CLKDIV u_video_clkdiv (
        .hclkin(clk_126m),
        .resetn(rstn),
        .clkout(clk_25m)          
    );

    wire hsync, vsync, de;
    wire [9:0] pixel_x, pixel_y;

    vga_timing u_vga_timing (
        .clk_pix(clk_25m),
        .rstn(rstn),
        .hsync(hsync),
        .vsync(vsync),
        .de(de),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y)
    );

    wire [23:0] rgb_data;

    osd_display u_osd (
        .cam_pclk(cam_pclk),            
        .clk_pix(clk_25m),              
        .rstn(rstn),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .de(de),
        .cam_vsync(cam_vsync),          
        .cam_href(cam_href),            
        .cam_pixel_valid(pixel_valid),  
        .cam_pixel_rgb565(pixel_rgb565),
        .capture_btn(~btn_stable),      
        .final_digit(final_digit),      
        .rgb_data(rgb_data)
    );

    DVI_TX_Top u_dvi_tx (
        .I_rst_n(rstn),
        .I_serial_clk(clk_126m),        
        .I_rgb_clk(clk_25m),
        .I_rgb_vs(vsync),
        .I_rgb_hs(hsync),
        .I_rgb_de(de),
        .I_rgb_r(rgb_data[23:16]),
        .I_rgb_g(rgb_data[15:8]),
        .I_rgb_b(rgb_data[7:0]),
        .O_tmds_clk_p(tmds_clk_p),
        .O_tmds_clk_n(tmds_clk_n),
        .O_tmds_data_p(tmds_data_p),
        .O_tmds_data_n(tmds_data_n)
    );

endmodule