#ifndef STATUS_H
#define STATUS_H

#include <stdbool.h>
#include <stdint.h>

#include "fb.h"

struct sys_status {
    char hostname[64];
    char kernel[80];
    char uptime_str[64];
    char time_str[64];

    float load1, load5, load15;
    int cpu_little_mhz;
    int cpu_big_mhz;
    float cpu_temp;

    uint64_t mem_total_kb;
    uint64_t mem_used_kb;
    uint64_t mem_avail_kb;
    uint64_t swap_total_kb;
    uint64_t swap_used_kb;

    uint64_t root_total_mb;
    uint64_t root_used_mb;
    uint64_t data_total_mb;
    uint64_t data_used_mb;

    char wlan_ip[32];
    char wlan_mac[32];
    uint64_t wlan_rx_bytes;
    uint64_t wlan_tx_bytes;
    char docker_ip[32];

    int battery_pct;
    char battery_status[32];
    float battery_volts;
    int battery_current_ma;
    float battery_temp;

    bool svc_wifi;
    bool svc_dhcp;
    bool svc_charge;
    bool svc_dockerd;
    bool svc_singbox;

    int timeout_remaining;
};

void status_collect(struct sys_status* st);
void status_render(struct drm_buf* buf, const struct sys_status* st);

#endif /* STATUS_H */
