#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "status.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statvfs.h>
#include <sys/sysinfo.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

static void read_file_string(const char* path, char* buf, size_t max) {
    FILE* f = fopen(path, "r");
    if (!f) {
        snprintf(buf, max, "N/A");
        return;
    }
    if (fgets(buf, (int)max, f)) {
        char* p = strchr(buf, '\n');
        if (p) *p = '\0';
    } else {
        snprintf(buf, max, "N/A");
    }
    fclose(f);
}

static long read_file_long(const char* path, long def_val) {
    FILE* f = fopen(path, "r");
    if (!f) return def_val;
    long val = def_val;
    if (fscanf(f, "%ld", &val) != 1) {
        val = def_val;
    }
    fclose(f);
    return val;
}

static const char* get_cpu_thermal_zone_path(void) {
    static char tz_path[64] = {0};
    if (tz_path[0]) return tz_path;

    char type_path[64];
    char type_buf[32];
    for (int i = 0; i < 90; i++) {
        snprintf(type_path, sizeof(type_path), "/sys/class/thermal/thermal_zone%d/type", i);
        FILE* f = fopen(type_path, "r");
        if (!f) continue;
        if (fgets(type_buf, sizeof(type_buf), f)) {
            if (strstr(type_buf, "cpuss-0") || strstr(type_buf, "cpu-1-0") ||
                strstr(type_buf, "cpu-0-0")) {
                fclose(f);
                snprintf(tz_path, sizeof(tz_path), "/sys/class/thermal/thermal_zone%d/temp", i);
                return tz_path;
            }
        }
        fclose(f);
    }
    snprintf(tz_path, sizeof(tz_path), "/sys/class/thermal/thermal_zone24/temp");
    return tz_path;
}

static bool check_service_run(const char* svc_name) {
    char path[128];
    snprintf(path, sizeof(path), "/data/adb/rootfs/service/%s/supervise/stat", svc_name);
    FILE* f = fopen(path, "r");
    if (!f) return false;
    char buf[32] = {0};
    bool running = false;
    if (fgets(buf, sizeof(buf), f)) {
        if (strncmp(buf, "run", 3) == 0) {
            running = true;
        }
    }
    fclose(f);
    return running;
}

void status_collect(struct sys_status* st) {
    memset(st, 0, sizeof(*st));

    /* Hostname & Kernel */
    if (gethostname(st->hostname, sizeof(st->hostname)) != 0 || strlen(st->hostname) == 0) {
        snprintf(st->hostname, sizeof(st->hostname), "phoenix");
    }
    struct utsname uts;
    if (uname(&uts) == 0) {
        snprintf(st->kernel, sizeof(st->kernel), "Linux %s", uts.release);
    } else {
        snprintf(st->kernel, sizeof(st->kernel), "Linux");
    }

    /* Date & Time */
    time_t now = time(NULL);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    strftime(st->time_str, sizeof(st->time_str), "%Y-%m-%d %H:%M:%S", &tm_buf);

    /* Uptime */
    FILE* f_up = fopen("/proc/uptime", "r");
    if (f_up) {
        double up_sec = 0;
        if (fscanf(f_up, "%lf", &up_sec) == 1) {
            int d = (int)(up_sec / 86400);
            int h = (int)((up_sec - d * 86400) / 3600);
            int m = (int)((up_sec - d * 86400 - h * 3600) / 60);
            snprintf(st->uptime_str, sizeof(st->uptime_str), "Up: %dd %dh %dm", d, h, m);
        }
        fclose(f_up);
    }

    /* Load Average */
    FILE* f_load = fopen("/proc/loadavg", "r");
    if (f_load) {
        if (fscanf(f_load, "%f %f %f", &st->load1, &st->load5, &st->load15) != 3) {
            st->load1 = st->load5 = st->load15 = 0.0f;
        }
        fclose(f_load);
    }

    /* CPU Frequencies & Thermal */
    long freq0 = read_file_long("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", 0);
    long freq6 = read_file_long("/sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq", 0);
    st->cpu_little_mhz = (int)(freq0 / 1000);
    st->cpu_big_mhz = (int)(freq6 / 1000);

    long temp_raw = read_file_long(get_cpu_thermal_zone_path(), 0);
    st->cpu_temp = (float)temp_raw / 1000.0f;

    /* Memory Info */
    FILE* f_mem = fopen("/proc/meminfo", "r");
    if (f_mem) {
        char line[128];
        while (fgets(line, sizeof(line), f_mem)) {
            unsigned long long val = 0;
            if (sscanf(line, "MemTotal: %llu kB", &val) == 1)
                st->mem_total_kb = val;
            else if (sscanf(line, "MemAvailable: %llu kB", &val) == 1)
                st->mem_avail_kb = val;
            else if (sscanf(line, "SwapTotal: %llu kB", &val) == 1)
                st->swap_total_kb = val;
            else if (sscanf(line, "SwapFree: %llu kB", &val) == 1) {
                if (st->swap_total_kb >= val) st->swap_used_kb = st->swap_total_kb - val;
            }
        }
        fclose(f_mem);
        if (st->mem_total_kb >= st->mem_avail_kb) {
            st->mem_used_kb = st->mem_total_kb - st->mem_avail_kb;
        }
    }

    /* Storage Usage */
    struct statvfs sv;
    if (statvfs("/", &sv) == 0) {
        uint64_t total = ((uint64_t)sv.f_blocks * (uint64_t)sv.f_frsize) / (1024ULL * 1024ULL);
        uint64_t free_b = ((uint64_t)sv.f_bfree * (uint64_t)sv.f_frsize) / (1024ULL * 1024ULL);
        st->root_total_mb = total;
        st->root_used_mb = (total >= free_b) ? (total - free_b) : 0;
    }
    if (statvfs("/data", &sv) == 0) {
        uint64_t total = ((uint64_t)sv.f_blocks * (uint64_t)sv.f_frsize) / (1024ULL * 1024ULL);
        uint64_t free_b = ((uint64_t)sv.f_bfree * (uint64_t)sv.f_frsize) / (1024ULL * 1024ULL);
        st->data_total_mb = total;
        st->data_used_mb = (total >= free_b) ? (total - free_b) : 0;
    }

    /* Network Interfaces */
    snprintf(st->wlan_ip, sizeof(st->wlan_ip), "Disconnected");
    snprintf(st->docker_ip, sizeof(st->docker_ip), "Inactive");

    struct ifaddrs* ifap = NULL;
    if (getifaddrs(&ifap) == 0) {
        for (struct ifaddrs* ifa = ifap; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            struct sockaddr_in* sin = (struct sockaddr_in*)ifa->ifa_addr;
            char ip_buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &sin->sin_addr, ip_buf, sizeof(ip_buf));

            if (strcmp(ifa->ifa_name, "wlan0") == 0) {
                snprintf(st->wlan_ip, sizeof(st->wlan_ip), "%s", ip_buf);
            } else if (strcmp(ifa->ifa_name, "docker0") == 0) {
                snprintf(st->docker_ip, sizeof(st->docker_ip), "%s", ip_buf);
            }
        }
        freeifaddrs(ifap);
    }

    read_file_string("/sys/class/net/wlan0/address", st->wlan_mac, sizeof(st->wlan_mac));

    FILE* f_net = fopen("/proc/net/dev", "r");
    if (f_net) {
        char line[256];
        while (fgets(line, sizeof(line), f_net)) {
            char ifname[32] = {0};
            unsigned long long rx = 0, tx = 0;
            char* col = strchr(line, ':');
            if (!col) continue;
            *col = ' ';
            if (sscanf(line, "%31s %llu %*s %*s %*s %*s %*s %*s %*s %llu", ifname, &rx, &tx) >= 3) {
                if (strcmp(ifname, "wlan0") == 0) {
                    st->wlan_rx_bytes = (uint64_t)rx;
                    st->wlan_tx_bytes = (uint64_t)tx;
                }
            }
        }
        fclose(f_net);
    }

    /* Battery & Power */
    st->battery_pct = (int)read_file_long("/sys/class/power_supply/battery/capacity", 0);
    read_file_string("/sys/class/power_supply/battery/status", st->battery_status,
                     sizeof(st->battery_status));
    long uvolts = read_file_long("/sys/class/power_supply/battery/voltage_now", 0);
    long uamps = read_file_long("/sys/class/power_supply/battery/current_now", 0);
    long btemp = read_file_long("/sys/class/power_supply/battery/temp", 0);

    st->battery_volts = (float)uvolts / 1000000.0f;
    st->battery_current_ma = (int)(uamps / 1000);
    st->battery_temp = (float)btemp / 10.0f;

    /* Services */
    st->svc_wifi = check_service_run("wifi");
    st->svc_dhcp = check_service_run("dhcp");
    st->svc_charge = check_service_run("charge");
    st->svc_dockerd = check_service_run("dockerd");
    st->svc_singbox = check_service_run("singbox");
}

void status_render(struct drm_buf* buf, const struct sys_status* st) {
    fb_clear(buf, COLOR_BG);

    int pad = 40;
    int card_w = (int)buf->width - 2 * pad;
    char str[256];

    /* 1. Header Card (offset by 140px to clear dual punch-hole cameras) */
    int cur_y = 140;
    int h_header = 145;
    fb_draw_card(buf, pad, cur_y, card_w, h_header, COLOR_CARD_BG, COLOR_CARD_BRD);

    snprintf(str, sizeof(str), "%s", st->hostname);
    fb_draw_text(buf, pad + 25, cur_y + 20, str, COLOR_TITLE, 0, 3);

    snprintf(str, sizeof(str), "%s", st->time_str);
    int time_w = (int)strlen(str) * (8 * 2);
    fb_draw_text(buf, pad + card_w - time_w - 25, cur_y + 28, str, COLOR_ACCENT, 0, 2);

    snprintf(str, sizeof(str), "%s   |   %s", st->kernel, st->uptime_str);
    fb_draw_text(buf, pad + 25, cur_y + 85, str, COLOR_TEXT_MUT, 0, 2);

    /* 2. CPU & Thermal Card */
    cur_y += h_header + 25;
    int h_cpu = 295;
    fb_draw_card(buf, pad, cur_y, card_w, h_cpu, COLOR_CARD_BG, COLOR_CARD_BRD);

    fb_draw_text(buf, pad + 25, cur_y + 20, "CPU & THERMAL", COLOR_HEADER, 0, 2);

    snprintf(str, sizeof(str), "Load Avg: %.2f, %.2f, %.2f", st->load1, st->load5, st->load15);
    fb_draw_text(buf, pad + 25, cur_y + 65, str, COLOR_TEXT, 0, 2);

    float load_pct = st->load1 / 8.0f;
    uint32_t load_color =
        (load_pct > 0.8f) ? COLOR_ERR : ((load_pct > 0.5f) ? COLOR_WARN : COLOR_OK);
    fb_draw_bar(buf, pad + 25, cur_y + 110, card_w - 50, 16, load_pct, load_color, COLOR_CARD_BRD);

    snprintf(str, sizeof(str), "LITTLE: %d MHz   BIG: %d MHz", st->cpu_little_mhz, st->cpu_big_mhz);
    fb_draw_text(buf, pad + 25, cur_y + 145, str, COLOR_TEXT, 0, 2);

    snprintf(str, sizeof(str), "CPU Core Temp: %.1f C", st->cpu_temp);
    fb_draw_text(buf, pad + 25, cur_y + 195, str, COLOR_TEXT, 0, 2);

    snprintf(str, sizeof(str), "Architecture: Qualcomm SM7150 (8 Cores)");
    fb_draw_text(buf, pad + 25, cur_y + 240, str, COLOR_TEXT_MUT, 0, 2);

    /* 3. Memory & Storage Card */
    cur_y += h_cpu + 25;
    int h_mem = 330;
    fb_draw_card(buf, pad, cur_y, card_w, h_mem, COLOR_CARD_BG, COLOR_CARD_BRD);

    fb_draw_text(buf, pad + 25, cur_y + 20, "MEMORY & STORAGE", COLOR_HEADER, 0, 2);

    float mem_used_gb = (float)st->mem_used_kb / (1024.0f * 1024.0f);
    float mem_tot_gb = (float)st->mem_total_kb / (1024.0f * 1024.0f);
    float mem_pct =
        (st->mem_total_kb > 0) ? ((float)st->mem_used_kb / (float)st->mem_total_kb) : 0.0f;

    snprintf(str, sizeof(str), "RAM:  %.2f / %.2f GB (%d%%)", mem_used_gb, mem_tot_gb,
             (int)(mem_pct * 100));
    fb_draw_text(buf, pad + 25, cur_y + 65, str, COLOR_TEXT, 0, 2);
    fb_draw_bar(buf, pad + 25, cur_y + 105, card_w - 50, 16, mem_pct, COLOR_ACCENT, COLOR_CARD_BRD);

    float root_used_gb = (float)st->root_used_mb / 1024.0f;
    float root_tot_gb = (float)st->root_total_mb / 1024.0f;
    float root_pct =
        (st->root_total_mb > 0) ? ((float)st->root_used_mb / (float)st->root_total_mb) : 0.0f;
    snprintf(str, sizeof(str), "Root: %.2f / %.2f GB (%d%%)", root_used_gb, root_tot_gb,
             (int)(root_pct * 100));
    fb_draw_text(buf, pad + 25, cur_y + 140, str, COLOR_TEXT, 0, 2);
    fb_draw_bar(buf, pad + 25, cur_y + 180, card_w - 50, 14, root_pct, COLOR_ACCENT,
                COLOR_CARD_BRD);

    float data_used_gb = (float)st->data_used_mb / 1024.0f;
    float data_tot_gb = (float)st->data_total_mb / 1024.0f;
    float data_pct =
        (st->data_total_mb > 0) ? ((float)st->data_used_mb / (float)st->data_total_mb) : 0.0f;
    snprintf(str, sizeof(str), "Data: %.1f / %.1f GB (%d%%)", data_used_gb, data_tot_gb,
             (int)(data_pct * 100));
    fb_draw_text(buf, pad + 25, cur_y + 215, str, COLOR_TEXT, 0, 2);
    fb_draw_bar(buf, pad + 25, cur_y + 255, card_w - 50, 14, data_pct, COLOR_ACCENT,
                COLOR_CARD_BRD);

    /* 4. Network Card */
    cur_y += h_mem + 25;
    int h_net = 275;
    fb_draw_card(buf, pad, cur_y, card_w, h_net, COLOR_CARD_BG, COLOR_CARD_BRD);

    fb_draw_text(buf, pad + 25, cur_y + 20, "NETWORK INTERFACES", COLOR_HEADER, 0, 2);

    snprintf(str, sizeof(str), "wlan0 IP:  %s", st->wlan_ip);
    fb_draw_text(buf, pad + 25, cur_y + 65, str, COLOR_OK, 0, 2);

    snprintf(str, sizeof(str), "wlan0 MAC: %s", st->wlan_mac);
    fb_draw_text(buf, pad + 25, cur_y + 110, str, COLOR_TEXT_MUT, 0, 2);

    float rx_mb = (float)st->wlan_rx_bytes / (1024.0f * 1024.0f);
    float tx_mb = (float)st->wlan_tx_bytes / (1024.0f * 1024.0f);
    snprintf(str, sizeof(str), "Traffic:   RX %.1f MB  |  TX %.1f MB", rx_mb, tx_mb);
    fb_draw_text(buf, pad + 25, cur_y + 155, str, COLOR_TEXT, 0, 2);

    snprintf(str, sizeof(str), "docker0:   %s", st->docker_ip);
    fb_draw_text(buf, pad + 25, cur_y + 205, str, COLOR_ACCENT, 0, 2);

    /* 5. Battery & Power Card */
    cur_y += h_net + 25;
    int h_bat = 265;
    fb_draw_card(buf, pad, cur_y, card_w, h_bat, COLOR_CARD_BG, COLOR_CARD_BRD);

    fb_draw_text(buf, pad + 25, cur_y + 20, "BATTERY & CHARGE", COLOR_HEADER, 0, 2);

    snprintf(str, sizeof(str), "Level: %d%%   [%s]", st->battery_pct, st->battery_status);
    fb_draw_text(buf, pad + 25, cur_y + 65, str, COLOR_TITLE, 0, 2);

    float bat_pct_f = (float)st->battery_pct / 100.0f;
    uint32_t bat_col =
        (st->battery_pct > 30) ? COLOR_OK : ((st->battery_pct > 15) ? COLOR_WARN : COLOR_ERR);
    fb_draw_bar(buf, pad + 25, cur_y + 110, card_w - 50, 16, bat_pct_f, bat_col, COLOR_CARD_BRD);

    snprintf(str, sizeof(str), "Voltage: %.2f V   Current: %+d mA", st->battery_volts,
             st->battery_current_ma);
    fb_draw_text(buf, pad + 25, cur_y + 145, str, COLOR_TEXT, 0, 2);

    snprintf(str, sizeof(str), "Battery Temp: %.1f C", st->battery_temp);
    fb_draw_text(buf, pad + 25, cur_y + 190, str, COLOR_TEXT_MUT, 0, 2);

    /* 6. Supervised Services Card */
    cur_y += h_bat + 25;
    int h_svc = 240;
    fb_draw_card(buf, pad, cur_y, card_w, h_svc, COLOR_CARD_BG, COLOR_CARD_BRD);

    fb_draw_text(buf, pad + 25, cur_y + 20, "SUPERVISED SERVICES", COLOR_HEADER, 0, 2);

    int svc_y = cur_y + 65;
    snprintf(str, sizeof(str), "[*] wifi:    %s", st->svc_wifi ? "RUNNING" : "STOPPED");
    fb_draw_text(buf, pad + 25, svc_y, str, st->svc_wifi ? COLOR_OK : COLOR_ERR, 0, 2);

    snprintf(str, sizeof(str), "[*] dhcp:    %s", st->svc_dhcp ? "RUNNING" : "STOPPED");
    fb_draw_text(buf, pad + 480, svc_y, str, st->svc_dhcp ? COLOR_OK : COLOR_ERR, 0, 2);

    svc_y += 45;
    snprintf(str, sizeof(str), "[*] charge:  %s", st->svc_charge ? "RUNNING" : "STOPPED");
    fb_draw_text(buf, pad + 25, svc_y, str, st->svc_charge ? COLOR_OK : COLOR_ERR, 0, 2);

    snprintf(str, sizeof(str), "[*] dockerd: %s", st->svc_dockerd ? "RUNNING" : "STOPPED");
    fb_draw_text(buf, pad + 480, svc_y, str, st->svc_dockerd ? COLOR_OK : COLOR_WARN, 0, 2);

    svc_y += 45;
    snprintf(str, sizeof(str), "[*] singbox: %s", st->svc_singbox ? "RUNNING" : "STOPPED");
    fb_draw_text(buf, pad + 25, svc_y, str, st->svc_singbox ? COLOR_OK : COLOR_TEXT_MUT, 0, 2);

    /* 7. Footer / Instructions Card */
    cur_y += h_svc + 25;
    int h_foot = 150;
    fb_draw_card(buf, pad, cur_y, card_w, h_foot, COLOR_CARD_BG, COLOR_CARD_BRD);

    snprintf(str, sizeof(str), "Auto-sleep in %d s (Touch or press Power)", st->timeout_remaining);
    fb_draw_text(buf, pad + 25, cur_y + 25, str, COLOR_WARN, 0, 2);

    snprintf(str, sizeof(str), "Press Power button to turn screen ON / OFF");
    fb_draw_text(buf, pad + 25, cur_y + 75, str, COLOR_TEXT_MUT, 0, 2);
}
