module I2C_Interface #(parameter SID = 8'h60) ( 
    input clk,                                  
    inout siod,                                 
    output sioc,                                
    output taken,                               
    input send,                                 
    input [7:0] rega,                           
    input [7:0] value                           
);
    reg [7:0] divider = 8'b00000001;
    reg [31:0] busy_sr = {32{1'b0}};
    reg [31:0] data_sr = {32{1'b1}};
    reg sioc_temp;
    reg taken_temp;
    reg siod_temp;
    
    localparam id = SID;
    
    assign siod = siod_temp;
    assign sioc = sioc_temp;
    assign taken = taken_temp;
    
    always @ (busy_sr or data_sr[31]) begin
        // TẠI PHA CHỜ ACK CỦA CAMERA, BẮT BUỘC THẢ NỔI BUS (1'bZ)
        if(busy_sr[11:10] == 2'b10 || busy_sr[20:19] == 2'b10 || busy_sr[29:28] == 2'b10) begin
            siod_temp <= 1'bZ;
        end
        else begin
            // Các thời điểm khác, FPGA ép mức 1 và 0 chủ động để bù đắp cho việc thiếu trở Pull-up
            siod_temp <= data_sr[31];
        end
    end
            
    always @ (posedge clk) begin
        taken_temp <= 1'b0;
        
        if(busy_sr[31] == 0) begin
            sioc_temp <= 1;
            if(send == 1) begin
                if(divider == 8'b00000000) begin
                    data_sr <= {3'b100, id, 1'b0, rega, 1'b0, value, 1'b0, 2'b01};
                    busy_sr <= {3'b111, 9'b111111111, 9'b111111111, 9'b111111111, 2'b11};
                    taken_temp <= 1'b1;
                end
                else begin
                    divider <= divider + 1;
                end
            end
        end
        else begin
            case ({busy_sr[31:29],busy_sr[2:0]})
                6'b111_111: begin // START
                    case (divider[7:6])                                      
                        2'b00: sioc_temp <= 1;                                   
                        2'b01: sioc_temp <= 1;                                   
                        2'b10: sioc_temp <= 1;                                   
                        default: sioc_temp <= 1;
                    endcase
                end
                6'b111_110: begin // START
                    case (divider[7:6])
                        2'b00: sioc_temp <= 1;          
                        2'b01: sioc_temp <= 1;
                        2'b10: sioc_temp <= 1;
                        default: sioc_temp <= 1;
                    endcase
                end
                6'b111_100: begin // START
                    case (divider[7:6])
                        2'b00: sioc_temp <= 0;          
                        2'b01: sioc_temp <= 0;          
                        2'b10: sioc_temp <= 0;
                        default: sioc_temp <= 0;
                    endcase
                end
                6'b110_000: begin // STOP
                    case (divider[7:6])
                        2'b00: sioc_temp <= 0;
                        2'b01: sioc_temp <= 1;
                        2'b10: sioc_temp <= 1;
                        default: sioc_temp <= 1;        
                    endcase
                end
                6'b100_000: begin // STOP
                    case (divider[7:6])                                      
                        2'b00: sioc_temp <= 1;          
                        2'b01: sioc_temp <= 1;
                        2'b10: sioc_temp <= 1;
                        default: sioc_temp <= 1;
                    endcase
                end
                6'b000_000: begin // STOP
                    case (divider[7:6])
                        2'b00: sioc_temp <= 1;                                   
                        2'b01: sioc_temp <= 1;          
                        2'b10: sioc_temp <= 1;
                        default: sioc_temp <= 1;
                    endcase
                end
                default: begin // CHUYỂN DỮ LIỆU
                    case (divider[7:6])
                        2'b00: sioc_temp <= 0;                                   
                        2'b01: sioc_temp <= 1;                                   
                        2'b10: sioc_temp <= 1;
                        default: sioc_temp <= 0;
                    endcase
                end
            endcase
            
            if(divider == 8'b11111111) begin
                busy_sr <= {busy_sr[30:0], 1'b0};        
                data_sr <= {data_sr[30:0], 1'b1};        
                divider <= {8{1'b0}};                   
            end
            else begin
                divider <= divider + 1;
            end
        end
    end
endmodule