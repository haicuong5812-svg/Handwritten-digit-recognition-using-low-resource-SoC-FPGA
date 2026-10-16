`timescale 1ns / 1ps
module image_processor(
    input wire        pclk,
    input wire        vsync,
    input wire        href,
    input wire        pixel_valid,
    input wire [15:0] pixel_rgb565,
    input wire        capture_btn,      
    
    output reg        ram_write_en,
    output reg [9:0]  ram_addr,    
    output reg [5:0]  ram_data,     // Nâng lên 6-bit Grayscale (0..63) đồng bộ với Python
    output reg        capture_done,
    output wire [9:0] debug_y      
);

    assign debug_y = y_cnt;
    reg [9:0] x_cnt = 0;
    reg [9:0] y_cnt = 0;
    
    // =======================================================
    // 1. MẠCH PHÁT HIỆN ĐỒNG BỘ CAMERA
    // =======================================================
    reg vsync_d, href_d;
    always @(posedge pclk) begin
        vsync_d <= vsync;
        href_d  <= href;
    end
    
    wire vsync_start  = (!vsync && vsync_d);
    wire vsync_end    = (vsync && !vsync_d);
    wire href_rising  = (!href_d && href);
    wire href_falling = (href_d && !href);

    // =======================================================
    // 2. MÁY TRẠNG THÁI CHỤP ẢNH
    // =======================================================
    reg [1:0] state = 0;
    localparam S_IDLE    = 2'd0;
    localparam S_WAIT_VS = 2'd1;
    localparam S_CAPTURE = 2'd2;
    localparam S_DONE    = 2'd3;

    always @(posedge pclk) begin
        case (state)
            S_IDLE: begin
                capture_done <= 1'b0;
                if (capture_btn) state <= S_WAIT_VS;
            end
            S_WAIT_VS: begin
                if (vsync_start) state <= S_CAPTURE;
            end
            S_CAPTURE: begin
                if (vsync_end && (y_cnt > 10'd50)) state <= S_DONE;
            end
            S_DONE: begin
                capture_done <= 1'b1;
                if (!capture_btn) state <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end

    // Đếm tọa độ pixel thực tế
    always @(posedge pclk) begin
        if (state == S_WAIT_VS && vsync_start) begin
            x_cnt <= 10'd0;
            y_cnt <= 10'd0;
        end else if (state == S_CAPTURE) begin
            if (href_falling) y_cnt <= y_cnt + 10'd1;
            
            if (href_rising) x_cnt <= 10'd0;
            else if (pixel_valid) x_cnt <= x_cnt + 10'd1;
        end
    end

    // =======================================================
    // 3. XÁC ĐỊNH VÙNG AI (112x112) & TRÍCH XUẤT ĐỘ SÁNG (LUMA)
    // =======================================================
    wire in_center_x  = (x_cnt >= 10'd40) && (x_cnt < 10'd152);
    wire in_center_y  = (y_cnt >= 10'd40) && (y_cnt < 10'd152);
    wire is_capturing = (state == S_CAPTURE);
    
    // Kênh Green 6-bit đại diện cho độ chói (Luminance) chuẩn nhất trong RGB565
    wire [5:0] green_channel = pixel_rgb565[10:5];

    // =======================================================
    // 4. LỌC TRUNG BÌNH 4 PIXEL THU NHỎ 112x112 -> 28x28 GRAYSCALE
    // =======================================================
    reg  [7:0] pix_sum = 8'd0;
    wire [7:0] total_4pix = pix_sum + {2'b00, green_channel};

    always @(posedge pclk) begin
        if (state == S_WAIT_VS) begin
            ram_addr     <= 10'h3FF; // Đặt sẵn địa chỉ cuộn (1023 -> +1 về 0)
            ram_write_en <= 1'b0;
            pix_sum      <= 8'd0;
        end else if (is_capturing && pixel_valid && in_center_x && in_center_y) begin
            // Tại hàng thứ 4 của mỗi block 4x4 (y_cnt[1:0] == 2'b11), tính trung bình 4 pixel ngang
            if (y_cnt[1:0] == 2'b11) begin
                case (x_cnt[1:0])
                    2'b00: begin
                        pix_sum      <= {2'b00, green_channel};
                        ram_write_en <= 1'b0;
                    end
                    2'b01, 2'b10: begin
                        pix_sum      <= pix_sum + {2'b00, green_channel};
                        ram_write_en <= 1'b0;
                    end
                    2'b11: begin
                        ram_write_en <= 1'b1;
                        ram_data     <= total_4pix[7:2]; // Chia 4 lấy trung bình 6-bit Grayscale
                        ram_addr     <= ram_addr + 10'd1;
                    end
                endcase
            end else begin
                ram_write_en <= 1'b0;
            end
        end else begin
            ram_write_en <= 1'b0;
        end
    end

endmodule