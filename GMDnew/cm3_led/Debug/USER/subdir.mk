################################################################################
# Automatically-generated file. Do not edit!
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
C_SRCS += \
../USER/gw1ns4c_it.c \
../USER/main.c 

OBJS += \
./USER/gw1ns4c_it.o \
./USER/main.o 

C_DEPS += \
./USER/gw1ns4c_it.d \
./USER/main.d 


# Each subdirectory must supply rules for building sources it contributes
USER/%.o: ../USER/%.c USER/subdir.mk
	@echo 'Building file: $<'
	@echo 'Invoking: Cross ARM C Compiler'
	arm-none-eabi-gcc -mcpu=cortex-m3 -mthumb -O3 -fmessage-length=0 -fsigned-char -ffunction-sections -fdata-sections -g3 -I"D:\FILEGOWIN\TangNano-4K-example-main\TangNano-4K-example-main\cm3_led\GMD_project\CORE" -I"D:\FILEGOWIN\TangNano-4K-example-main\TangNano-4K-example-main\cm3_led\GMD_project\PERIPHERAL\Includes" -I"D:\FILEGOWIN\TangNano-4K-example-main\TangNano-4K-example-main\cm3_led\GMD_project\SYSTEM" -I"D:\FILEGOWIN\TangNano-4K-example-main\TangNano-4K-example-main\cm3_led\GMD_project\USER" -std=gnu11 -MMD -MP -MF"$(@:%.o=%.d)" -MT"$@" -c -o "$@" "$<"
	@echo 'Finished building: $<'
	@echo ' '


