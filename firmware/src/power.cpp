#include "power.h"

// Panlee SC01 Plus: no PMU, no battery. All entry points are no-ops.

void power_init(void) {}
void power_tick(void) {}

int  power_battery_pct(void) { return -1; }   // -1 → UI hides the battery icon
bool power_is_charging(void) { return false; }
bool power_pwr_pressed(void) { return false; }
