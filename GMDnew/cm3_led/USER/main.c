#include "gw1ns4c.h"
#include "cnn_weights.h"

// THÔNG SỐ MẠNG NEURAL NETWORK (6 -> 12 -> 300 -> 32 -> 3)
#define FLATTEN_SIZE 300
#define FC1_OUT      32
#define FC2_OUT      3   // 0: Người, 1: Gia cầm (Gà), 2: Gia súc (Bò)
#define FRAC_BITS    8
#define PAD          0   // Không dùng Padding thừa
#define FC1_ROW_SIZE (PAD + FLATTEN_SIZE + PAD)
#define FC2_ROW_SIZE (PAD + FC1_OUT + PAD)

// QUY HOẠCH ĐỊA CHỈ BUS APB
#define APB_CNN_BASE    0x40002400
#define CNN_HW_DONE     (*(volatile uint16_t *)(APB_CNN_BASE + 0x00E0))
#define CNN_BRAM_DATA   ((volatile int32_t *)(APB_CNN_BASE + 0x0000))
#define LED_RESULT_REG  (*(volatile uint32_t *)(APB_CNN_BASE + 0x00E4))
#define CAM_TRIG_REG    (*(volatile uint32_t *)(APB_CNN_BASE + 0x00E8))

int main(void) {
    // Khởi tạo trạng thái ban đầu: An toàn (Class 1) và hạ cờ chụp
    LED_RESULT_REG = 1;
    CAM_TRIG_REG   = 0;

    while(1) {
        // 1. Kích hoạt FPGA bắt đầu chụp khung hình mới
        CAM_TRIG_REG = 1;

        uint32_t timeout = 0;
        uint8_t success = 0;

        // 2. Chờ Camera chốt khung hình và FPGA chạy xong Conv1 + Conv2
        while (timeout < 5000000) {
            if ((CNN_HW_DONE & 0x01) == 1) {
                success = 1;
                break;
            }
            timeout++;
        }

        if (success == 0) {
            CAM_TRIG_REG = 0;
        } else {
            // 3. Đọc 300 phần tử Flatten từ pool2_ram qua Bus APB
            int16_t flatten_data[FLATTEN_SIZE];
            for (int i = 0; i < FLATTEN_SIZE; i++) {
                flatten_data[i] = (int16_t)(CNN_BRAM_DATA[0]);
            }

            // 4. Đọc xong dữ liệu -> Hạ cờ CAM_TRIG_REG về 0 để giải phóng FPGA
            CAM_TRIG_REG = 0;

            // 5. Tính toán lớp ẩn FC1 (300 -> 32) + ReLU
            int32_t fc1_out[FC1_OUT] = {0};
            for (int i = 0; i < FC1_OUT; i++) {
                int64_t sum = 0;
                int w_ptr = i * FC1_ROW_SIZE + PAD;
                for (int j = 0; j < FLATTEN_SIZE; j++) {
                    sum += ((int64_t)flatten_data[j] * (int16_t)fc1_weights[w_ptr++]);
                }
                sum += ((int64_t)fc1_bias[i]) << FRAC_BITS;
                sum >>= FRAC_BITS;
                fc1_out[i] = (sum > 0) ? (int32_t)sum : 0;
            }

            // 6. Tính toán lớp đầu ra FC2 (32 -> 3)
            int32_t fc2_out[FC2_OUT] = {0};
            for (int i = 0; i < FC2_OUT; i++) {
                int64_t sum = 0;
                int w_ptr = i * FC2_ROW_SIZE + PAD;
                for (int j = 0; j < FC1_OUT; j++) {
                    sum += ((int64_t)fc1_out[j] * (int16_t)fc2_weights[w_ptr++]);
                }
                sum += ((int64_t)fc2_bias[i]) << FRAC_BITS;
                sum >>= FRAC_BITS;
                fc2_out[i] = (int32_t)sum;
            }

            // 7. Tìm lớp có điểm số cao nhất (Argmax)
            int best_idx = 0;
            int32_t best_val = fc2_out[0];
            for (int i = 1; i < FC2_OUT; i++) {
                if (fc2_out[i] > best_val) {
                    best_val = fc2_out[i];
                    best_idx = i;
                }
            }

            // 8. Xuất kết quả xuống FPGA (Cập nhật màn hình HDMI + Nháy LED chân 10 khi best_idx == 0)
            LED_RESULT_REG = best_idx;
        }

        // Đảm bảo FPGA đã xóa cờ HW_DONE trước khi sang khung hình tiếp theo
        while ((CNN_HW_DONE & 0x01) == 1) {}

        // Giữ nhịp quét ổn định ~10 FPS
        for (volatile int delay = 0; delay < 300000; delay++);
    }
}

// CÁC HÀM SYSTEM CALL GIẢ ĐỊNH CHO TRÌNH BIÊN DỊCH ARM GCC
int _write(int file, char *ptr, int len) { return len; }
int _close(int file) { return -1; }
int _lseek(int file, int ptr, int dir) { return 0; }
int _read(int file, char *ptr, int len) { return 0; }
int _fstat(int file, void *st) { return 0; }
int _isatty(int file) { return 1; }
