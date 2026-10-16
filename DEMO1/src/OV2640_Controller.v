`timescale 1ns / 1ps

module OV2640_Controller (
    input clk,
    input resend,
    output config_finished,
    output sioc,
    inout siod,
    output reset,
    output pwdn
);
    assign reset = 1'b1;
    assign pwdn  = 1'b0;
    
    wire [15:0] command;
    wire finished;
    wire taken;
    
    assign config_finished = finished;
    
    // 1. DELAY CHỜ CAMERA LÊN NGUỒN (BOOT)
    reg [23:0] boot_delay_cnt = 0;
    reg camera_ready = 0;
    
    always @(posedge clk) begin
        if (resend) begin
            boot_delay_cnt <= 0;
            camera_ready <= 0;
        end else if (boot_delay_cnt < 24'd12_000_000) begin // Delay 0.5s
            boot_delay_cnt <= boot_delay_cnt + 1;
            camera_ready <= 0;
        end else begin
            camera_ready <= 1;
        end
    end

    // 2. XỬ LÝ DELAY GIỮA CÁC LỆNH I2C
    reg [19:0] cmd_delay_cnt = 0;
    reg cmd_ready = 1;
    
    // Lưu trạng thái: Lệnh VỪA GỬI XONG có phải là lệnh Reset (12_80) không?
    reg just_reset = 0;
    always @(posedge clk) begin
        if (taken) begin
            just_reset <= (command == 16'h12_80);
        end
    end
    
    // Nếu vừa gửi Reset, delay 10ms (270,000 clock). Nếu lệnh thường, delay 0.1ms (2,700 clock).
    wire [19:0] target_delay = just_reset ? 20'd270_000 : 20'd2_700;
    
    always @(posedge clk) begin
        if (resend | ~camera_ready) begin
            cmd_delay_cnt <= 0;
            cmd_ready <= 1;
        end else begin
            if (taken) begin
                cmd_ready <= 0;
                cmd_delay_cnt <= 0;
            end else if (!cmd_ready) begin
                if (cmd_delay_cnt < target_delay) begin
                     cmd_delay_cnt <= cmd_delay_cnt + 1;
                end else begin
                    cmd_ready <= 1;
                end
            end
        end
    end

    wire send = camera_ready & cmd_ready & (~finished);

    OV2640_Registers LUT(
        .clk(clk),
        .advance(taken),
        .command(command),
        .finished(finished),
        .resend(resend | ~camera_ready) 
    );

    I2C_Interface #(
        .SID (8'h60)
    ) I2C (
        .clk(clk),
        .taken(taken),
        .siod(siod),
        .sioc(sioc),
        .send(send),
        .rega(command[15:8]),
        .value(command[7:0])
    );
endmodule