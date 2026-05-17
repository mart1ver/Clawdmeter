#include "imu.h"

// Panlee SC01 Plus: no IMU. Orientation is fixed to 0 (landscape, native).

void    imu_init(void)         {}
void    imu_tick(void)         {}
uint8_t imu_get_rotation(void) { return 0; }
