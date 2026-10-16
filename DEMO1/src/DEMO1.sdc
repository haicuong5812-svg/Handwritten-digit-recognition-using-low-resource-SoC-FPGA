//Copyright (C)2014-2026 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.11.03 Education 
//Created Time: 2026-08-17 23:52:16
//create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]
// Khai bao xung nhip he thong 27MHz va xung nhip Camera 24MHz
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_clock -name cam_pclk -period 41.667 -waveform {0 20.833} [get_ports {cam_pclk}]

// Tach biet mien xung nhip bat dong bo giua Camera, He thong va HDMI
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {cam_pclk}]