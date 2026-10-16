`timescale 1ns / 1ps
module osd_display (
    input  wire        cam_pclk,        // Xung nhịp điểm ảnh từ camera (~24MHz)
    input  wire        clk_pix,         // Xung nhịp quét màn hình HDMI (25.2MHz)
    input  wire        rstn,
    input  wire [9:0]  pixel_x,         // Tọa độ X đang quét trên HDMI
    input  wire [9:0]  pixel_y,         // Tọa độ Y đang quét trên HDMI
    input  wire        de,              // Tín hiệu cho phép hiển thị
    
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire        cam_pixel_valid, 
    input  wire [15:0] cam_pixel_rgb565,
    input  wire        capture_btn,     
    
    input  wire [3:0]  final_digit,     // Kết quả AI (0: Người, 1: Gia cầm, 2: Gia súc)
    output reg  [23:0] rgb_data         
);

// =============================================================
// 1. ĐỒNG BỘ VÀ TẠO TỌA ĐỘ CAMERA
// =============================================================
reg vsync_d1, vsync_d2;
reg href_d1, href_d2;

always @(posedge cam_pclk or negedge rstn) begin
    if (!rstn) begin
        vsync_d1 <= 1'b0; vsync_d2 <= 1'b0;
        href_d1  <= 1'b0; href_d2  <= 1'b0;
    end else begin
        vsync_d1 <= cam_vsync; vsync_d2 <= vsync_d1;
        href_d1  <= cam_href;  href_d2  <= href_d1;
    end
end

wire vsync_start = (!vsync_d1 && vsync_d2);
wire href_start  = (href_d1 && !href_d2);
wire href_end    = (!href_d1 && href_d2);

reg [9:0] cam_x_cnt;
reg [9:0] cam_y_cnt;

always @(posedge cam_pclk or negedge rstn) begin
    if (!rstn) begin
        cam_x_cnt <= 10'd0;
        cam_y_cnt <= 10'd0;
    end else begin
        if (vsync_start) begin
            cam_x_cnt <= 10'd0;
            cam_y_cnt <= 10'd0;
        end else if (href_end) begin
            cam_y_cnt <= cam_y_cnt + 10'd1;
        end else if (href_d1) begin
            if (href_start) 
                cam_x_cnt <= 10'd0;
            else if (cam_pixel_valid) 
                cam_x_cnt <= cam_x_cnt + 10'd1;
        end
    end
end

// =============================================================
// 2. LƯU ẢNH VÀ TÌM BOUNDING BOX ĐỐI TƯỢNG TRỰC TIẾP TRÊN FPGA
// =============================================================
wire in_ai_box = (cam_x_cnt >= 10'd40 && cam_x_cnt < 10'd152) && 
                 (cam_y_cnt >= 10'd40 && cam_y_cnt < 10'd152);

reg is_capturing;
always @(posedge cam_pclk or negedge rstn) begin
    if (!rstn) begin
        is_capturing <= 1'b1;
    end else begin
        if (capture_btn) begin
            is_capturing <= 1'b0;
        end else if (vsync_start && !capture_btn) begin
            is_capturing <= 1'b1;
        end
    end
end

reg img_ram [0:12543];
reg [13:0] cam_wr_ptr;

wire [5:0] green_cam = cam_pixel_rgb565[10:5];
reg  [5:0] prev_green_osd;

always @(posedge cam_pclk or negedge rstn) begin
    if (!rstn) prev_green_osd <= 6'd0;
    else if (href_start || cam_pixel_valid) prev_green_osd <= green_cam;
end

wire [5:0] grad_x_osd    = (green_cam > prev_green_osd) ? (green_cam - prev_green_osd) : (prev_green_osd - green_cam);
wire       is_edge_pixel = (grad_x_osd >= 6'd5);

// Tọa độ tương đối (0..111) trong vùng AI
wire [9:0] rel_x_full = cam_x_cnt - 10'd40;
wire [9:0] rel_y_full = cam_y_cnt - 10'd40;
wire [6:0] rel_x      = rel_x_full[6:0];
wire [6:0] rel_y      = rel_y_full[6:0];

// Thanh ghi tìm Bounding Box
reg [6:0] cur_min_x, cur_max_x, cur_min_y, cur_max_y;
reg [6:0] bbox_min_x, bbox_max_x, bbox_min_y, bbox_max_y;

wire valid_bbox_region = (rel_x >= 7'd4 && rel_x <= 7'd107) && (rel_y >= 7'd4 && rel_y <= 7'd107);

always @(posedge cam_pclk or negedge rstn) begin
    if (!rstn) begin
        cam_wr_ptr <= 14'd0;
        cur_min_x  <= 7'd111; cur_max_x <= 7'd0;
        cur_min_y  <= 7'd111; cur_max_y <= 7'd0;
        bbox_min_x <= 7'd20;  bbox_max_x <= 7'd90;
        bbox_min_y <= 7'd20;  bbox_max_y <= 7'd90;
    end else begin
        if (vsync_start) begin
            cam_wr_ptr <= 14'd0;
            if ((cur_max_x > cur_min_x + 7'd6) && (cur_max_y > cur_min_y + 7'd6)) begin
                bbox_min_x <= cur_min_x;
                bbox_max_x <= cur_max_x;
                bbox_min_y <= cur_min_y;
                bbox_max_y <= cur_max_y;
            end
            cur_min_x <= 7'd111; cur_max_x <= 7'd0;
            cur_min_y <= 7'd111; cur_max_y <= 7'd0;
        end else if (is_capturing && cam_pixel_valid && in_ai_box) begin
            img_ram[cam_wr_ptr] <= is_edge_pixel;
            if (cam_wr_ptr < 14'd12543) begin
                cam_wr_ptr <= cam_wr_ptr + 14'd1;
            end
            if (grad_x_osd >= 6'd8 && valid_bbox_region) begin
                if (rel_x < cur_min_x) cur_min_x <= rel_x;
                if (rel_x > cur_max_x) cur_max_x <= rel_x;
                if (rel_y < cur_min_y) cur_min_y <= rel_y;
                if (rel_y > cur_max_y) cur_max_y <= rel_y;
            end
        end
    end
end

// =============================================================
// 3. ĐỌC RAM VÀ VẼ KHUNG BOUNDING BOX LÊN HDMI (Phóng to 2x)
// =============================================================
wire is_display_box = (pixel_x >= 10'd100 && pixel_x < 10'd324) && 
                      (pixel_y >= 10'd100 && pixel_y < 10'd324);

wire [9:0] box_offset_x = pixel_x - 10'd100;
wire [9:0] box_offset_y = pixel_y - 10'd100;

wire [6:0] ram_read_x = box_offset_x[7:1];
wire [6:0] ram_read_y = box_offset_y[7:1];

wire [13:0] read_addr = ({7'd0, ram_read_y} << 6) + ({7'd0, ram_read_y} << 5) + ({7'd0, ram_read_y} << 4) + {7'd0, ram_read_x};

wire on_bbox_x = (ram_read_x == bbox_min_x || ram_read_x == bbox_max_x) && (ram_read_y >= bbox_min_y && ram_read_y <= bbox_max_y);
wire on_bbox_y = (ram_read_y == bbox_min_y || ram_read_y == bbox_max_y) && (ram_read_x >= bbox_min_x && ram_read_x <= bbox_max_x);
wire is_bbox_border = is_display_box && (on_bbox_x || on_bbox_y);

reg pixel_val;
reg is_display_box_d;
reg is_bbox_border_d;

always @(posedge clk_pix) begin
    pixel_val        <= img_ram[read_addr];
    is_display_box_d <= is_display_box;
    is_bbox_border_d <= is_bbox_border;
end

// =============================================================
// 4. VẼ SỐ LED 7 ĐOẠN
// =============================================================
reg [6:0] seg;
always @(*) begin
    case(final_digit)
        4'd0: seg = 7'b0111111; 4'd1: seg = 7'b0000110; 4'd2: seg = 7'b1011011;
        4'd3: seg = 7'b1001111; 4'd4: seg = 7'b1100110; 4'd5: seg = 7'b1101101;
        4'd6: seg = 7'b1111101; 4'd7: seg = 7'b0000111; 4'd8: seg = 7'b1111111;
        4'd9: seg = 7'b1101111; default: seg = 7'b0000000;
    endcase
end

wire s0 = seg[0] && (pixel_x >= 10'd400 && pixel_x <= 10'd480) && (pixel_y >= 10'd120 && pixel_y <= 10'd140);
wire s1 = seg[1] && (pixel_x >= 10'd460 && pixel_x <= 10'd480) && (pixel_y >= 10'd120 && pixel_y <= 10'd200);
wire s2 = seg[2] && (pixel_x >= 10'd460 && pixel_x <= 10'd480) && (pixel_y >= 10'd200 && pixel_y <= 10'd280);
wire s3 = seg[3] && (pixel_x >= 10'd400 && pixel_x <= 10'd480) && (pixel_y >= 10'd260 && pixel_y <= 10'd280);
wire s4 = seg[4] && (pixel_x >= 10'd400 && pixel_x <= 10'd420) && (pixel_y >= 10'd200 && pixel_y <= 10'd280);
wire s5 = seg[5] && (pixel_x >= 10'd400 && pixel_x <= 10'd420) && (pixel_y >= 10'd120 && pixel_y <= 10'd200);
wire s6 = seg[6] && (pixel_x >= 10'd400 && pixel_x <= 10'd480) && (pixel_y >= 10'd190 && pixel_y <= 10'd210);
wire draw_seg = s0 | s1 | s2 | s3 | s4 | s5 | s6;

// =============================================================
// 5. XUẤT MÀU RA HDMI (HIỂN THỊ BOUNDING BOX ĐỘNG & CẢNH BÁO)
// =============================================================
always @(posedge clk_pix) begin
    if (!de) begin
        rgb_data <= 24'h000000;
    end else if (draw_seg) begin
        rgb_data <= (final_digit == 4'd0) ? 24'hFF0000 : 24'h00FF00;
    end else if (is_bbox_border_d) begin
        rgb_data <= (final_digit == 4'd0) ? 24'hFF0000 : 24'h00FF00;
    end else if (is_display_box_d) begin
        rgb_data <= pixel_val ? 24'hFFFFFF : 24'h000000; 
    end else begin
        rgb_data <= (final_digit == 4'd0) ? 24'h400000 : 24'h001F3F;
    end
end

endmodule