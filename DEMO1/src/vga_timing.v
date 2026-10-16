`timescale 1ns / 1ps

module vga_timing (
    input  wire clk_pix,   // Xung nhịp 25.2 MHz
    input  wire rstn,
    output wire hsync,     // Đồng bộ ngang
    output wire vsync,     // Đồng bộ dọc
    output wire de,        // Vùng hiển thị hợp lệ (Data Enable)
    output wire [9:0] pixel_x, // Tọa độ X (0 -> 639)
    output wire [9:0] pixel_y  // Tọa độ Y (0 -> 479)
);

    // Thông số chuẩn VGA 640x480 @ 60Hz
    localparam H_DISPLAY       = 640;
    localparam H_FRONT_PORCH   = 16;
    localparam H_SYNC_PULSE    = 96;
    localparam H_BACK_PORCH    = 48;
    localparam H_TOTAL         = 800;

    localparam V_DISPLAY       = 480;
    localparam V_FRONT_PORCH   = 10;
    localparam V_SYNC_PULSE    = 2;
    localparam V_BACK_PORCH    = 33;
    localparam V_TOTAL         = 525;

    reg [9:0] h_cnt;
    reg [9:0] v_cnt;

    always @(posedge clk_pix or negedge rstn) begin
        if (!rstn) begin
            h_cnt <= 0;
            v_cnt <= 0;
        end else begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 0;
                if (v_cnt == V_TOTAL - 1)
                    v_cnt <= 0;
                else
                    v_cnt <= v_cnt + 1;
            end else begin
                h_cnt <= h_cnt + 1;
            end
        end
    end

    // HSYNC và VSYNC của 640x480 là cực âm (active low)
    assign hsync = ~(h_cnt >= (H_DISPLAY + H_FRONT_PORCH) && h_cnt < (H_DISPLAY + H_FRONT_PORCH + H_SYNC_PULSE));
    assign vsync = ~(v_cnt >= (V_DISPLAY + V_FRONT_PORCH) && v_cnt < (V_DISPLAY + V_FRONT_PORCH + V_SYNC_PULSE));
    
    // DE (Data Enable) chỉ tích cực trong vùng có điểm ảnh
    assign de    = (h_cnt < H_DISPLAY) && (v_cnt < V_DISPLAY);
    
    assign pixel_x = (de) ? h_cnt : 10'd0;
    assign pixel_y = (de) ? v_cnt : 10'd0;

endmodule