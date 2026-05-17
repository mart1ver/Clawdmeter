#pragma once

#include <Arduino_GFX_Library.h>
#include <FT6X36.h>
#include <Wire.h>

// ---- Display resolution (Panlee SC01 Plus, 3.5" IPS, landscape) ----
#define LCD_WIDTH   480
#define LCD_HEIGHT  320

// ---- ST7796 8-bit parallel display pins (SC01 Plus) ----
#define LCD_BL      45
#define LCD_RST     4
#define LCD_CS      GFX_NOT_DEFINED   // CS tied low on the board
#define LCD_DC      0
#define LCD_WR      47
#define LCD_RD      GFX_NOT_DEFINED
#define LCD_D0      9
#define LCD_D1      46
#define LCD_D2      3
#define LCD_D3      8
#define LCD_D4      18
#define LCD_D5      17
#define LCD_D6      16
#define LCD_D7      15

// ---- Touch pins (FT6336U via I2C, SC01 Plus) ----
#define IIC_SDA     6
#define IIC_SCL     5
#define TP_INT      7
#define TP_RST      -1                // tied on the board
#define FT6336_ADDR 0x38

// ---- Global hardware objects (defined in main.cpp) ----
extern Arduino_DataBus *bus;
extern Arduino_ST7796  *gfx;
extern FT6X36          touch;
