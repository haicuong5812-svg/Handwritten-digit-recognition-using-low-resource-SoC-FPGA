module dvp_capture(
    input  wire        pclk,        
    input  wire        rst_n,       
    input  wire        vsync,       
    input  wire        href,        
    input  wire [7:0]  pix_data_in, 
    
    output reg         pixel_valid, 
    output reg  [15:0] pixel_rgb565 
);

    reg [7:0] pixdata_d1; 
    reg       hcnt;

    // Chốt byte đầu tiên
    always @(posedge pclk or negedge rst_n) begin
        if(!rst_n) pixdata_d1 <= 8'd0;
        else pixdata_d1 <= pix_data_in;
    end

    // Đếm Lẻ/Chẵn
    always @(posedge pclk or negedge rst_n) begin
        if(!rst_n) hcnt <= 1'd0;
        else if(href) hcnt <= ~hcnt;
        else hcnt <= 1'd0;
    end

    // Ghép 2 byte thành 1 pixel 16-bit
    always @(posedge pclk or negedge rst_n) begin
        if(!rst_n) begin
            pixel_valid <= 1'b0;
            pixel_rgb565 <= 16'd0;
        end else if(href && hcnt) begin
            pixel_valid <= 1'b1;
            // Ghép thẳng 2 byte 
            pixel_rgb565 <= {pixdata_d1, pix_data_in}; 
        end else begin
            pixel_valid <= 1'b0;
        end
    end
endmodule