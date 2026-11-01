#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DNS_PORT 53
#define BUFFER_SIZE 2048
#define MAX_SESSIONS 1024
#define MAX_UPSTREAMS 8
#define SESSION_TIMEOUT_SEC 5
#define DEFAULT_UPSTREAM_1 "223.5.5.5"
#define DEFAULT_UPSTREAM_2 "223.6.6.6"

struct upstream_server {
    struct sockaddr_in addr;
    char ip_str[INET_ADDRSTRLEN];
};

struct session {
    struct sockaddr_in client_addr;
    time_t expire_at;
    uint16_t client_id;
    bool active;
};

static volatile sig_atomic_t g_running = 1;
static volatile sig_atomic_t g_reload = 0;

static uint16_t g_session_seq = 0;
static struct session g_sessions[MAX_SESSIONS];

static void handle_signal(int sig) {
    if (sig == SIGHUP) {
        g_reload = 1;
    } else {
        g_running = 0;
    }
}

static int add_upstream(struct upstream_server* servers, int count, int max, const char* ip) {
    if (count >= max || ip == NULL) {
        return count;
    }

    struct in_addr addr;
    if (inet_pton(AF_INET, ip, &addr) != 1) {
        return count;
    }

    /* Skip loopback addresses to avoid forwarding loops */
    if ((ntohl(addr.s_addr) >> 24) == 127 || addr.s_addr == INADDR_ANY) {
        return count;
    }

    for (int i = 0; i < count; i++) {
        if (servers[i].addr.sin_addr.s_addr == addr.s_addr) {
            return count;
        }
    }

    memset(&servers[count].addr, 0, sizeof(servers[count].addr));
    servers[count].addr.sin_family = AF_INET;
    servers[count].addr.sin_port = htons(DNS_PORT);
    servers[count].addr.sin_addr = addr;
    strncpy(servers[count].ip_str, ip, sizeof(servers[count].ip_str) - 1);
    servers[count].ip_str[sizeof(servers[count].ip_str) - 1] = '\0';
    return count + 1;
}

static int load_upstream_servers(const char* path, struct upstream_server* servers, int max) {
    int count = 0;

    if (path != NULL) {
        FILE* fp = fopen(path, "r");
        if (fp != NULL) {
            char line[256];
            while (fgets(line, sizeof(line), fp) != NULL && count < max) {
                char* p = line;
                while (*p == ' ' || *p == '\t') {
                    p++;
                }
                if (*p == '#' || *p == ';' || *p == '\n' || *p == '\0') {
                    continue;
                }
                if (strncmp(p, "nameserver", 10) == 0 && (p[10] == ' ' || p[10] == '\t')) {
                    p += 10;
                    while (*p == ' ' || *p == '\t') {
                        p++;
                    }
                    char ip_buf[INET_ADDRSTRLEN];
                    size_t i = 0;
                    while (*p != ' ' && *p != '\t' && *p != '\n' && *p != '\r' && *p != '\0' &&
                           i < sizeof(ip_buf) - 1) {
                        ip_buf[i++] = *p++;
                    }
                    ip_buf[i] = '\0';
                    count = add_upstream(servers, count, max, ip_buf);
                }
            }
            fclose(fp);
        }
    }

    if (count == 0) {
        count = add_upstream(servers, count, max, DEFAULT_UPSTREAM_1);
        count = add_upstream(servers, count, max, DEFAULT_UPSTREAM_2);
    }

    for (int i = 0; i < count; i++) {
        fprintf(stdout, "[dns-forwarder] Upstream DNS [%d]: %s\n", i, servers[i].ip_str);
    }
    fflush(stdout);
    return count;
}

static int alloc_session(const struct sockaddr_in* client_addr, uint16_t client_id, time_t now) {
    for (int i = 0; i < MAX_SESSIONS; i++) {
        uint16_t idx = (g_session_seq++) % MAX_SESSIONS;
        if (!g_sessions[idx].active || now > g_sessions[idx].expire_at) {
            g_sessions[idx].client_addr = *client_addr;
            g_sessions[idx].client_id = client_id;
            g_sessions[idx].expire_at = now + SESSION_TIMEOUT_SEC;
            g_sessions[idx].active = true;
            return idx;
        }
    }
    return -1;
}

static void handle_client_query(int client_fd, int upstream_fd,
                                const struct upstream_server* servers, int server_count,
                                time_t now) {
    uint8_t buf[BUFFER_SIZE];
    struct sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);

    ssize_t len =
        recvfrom(client_fd, buf, sizeof(buf), 0, (struct sockaddr*)&client_addr, &addr_len);
    if (len < 12) {
        return;
    }

    /* Only process queries (QR flag == 0) */
    if ((buf[2] & 0x80) != 0) {
        return;
    }

    uint16_t client_id = (uint16_t)(((uint16_t)buf[0] << 8) | (uint16_t)buf[1]);
    int idx = alloc_session(&client_addr, client_id, now);
    if (idx < 0) {
        return;
    }

    buf[0] = (uint8_t)(((uint16_t)idx >> 8) & 0xff);
    buf[1] = (uint8_t)((uint16_t)idx & 0xff);

    for (int i = 0; i < server_count; i++) {
        sendto(upstream_fd, buf, (size_t)len, 0, (const struct sockaddr*)&servers[i].addr,
               sizeof(servers[i].addr));
    }
}

static void handle_upstream_response(int client_fd, int upstream_fd, time_t now) {
    uint8_t buf[BUFFER_SIZE];
    struct sockaddr_in from_addr;
    socklen_t addr_len = sizeof(from_addr);

    ssize_t len =
        recvfrom(upstream_fd, buf, sizeof(buf), 0, (struct sockaddr*)&from_addr, &addr_len);
    if (len < 12) {
        return;
    }

    uint16_t idx = (uint16_t)(((uint16_t)buf[0] << 8) | (uint16_t)buf[1]);
    if (idx >= MAX_SESSIONS || !g_sessions[idx].active || now > g_sessions[idx].expire_at) {
        return;
    }

    buf[0] = (uint8_t)((g_sessions[idx].client_id >> 8) & 0xff);
    buf[1] = (uint8_t)(g_sessions[idx].client_id & 0xff);

    sendto(client_fd, buf, (size_t)len, 0, (const struct sockaddr*)&g_sessions[idx].client_addr,
           sizeof(g_sessions[idx].client_addr));
    g_sessions[idx].active = false;
}

int main(int argc, char** argv) {
    const char* config_path = (argc > 1) ? argv[1] : NULL;

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    int client_fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (client_fd < 0) {
        perror("socket client");
        return 1;
    }

    int opt = 1;
    setsockopt(client_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in bind_addr;
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons(DNS_PORT);
    bind_addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(client_fd, (struct sockaddr*)&bind_addr, sizeof(bind_addr)) < 0) {
        perror("bind 0.0.0.0:53");
        close(client_fd);
        return 1;
    }

    int upstream_fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (upstream_fd < 0) {
        perror("socket upstream");
        close(client_fd);
        return 1;
    }

    struct upstream_server servers[MAX_UPSTREAMS];
    int server_count = load_upstream_servers(config_path, servers, MAX_UPSTREAMS);

    fprintf(stdout, "[dns-forwarder] Started DNS forwarder on 0.0.0.0:53\n");
    fflush(stdout);

    struct pollfd fds[2];
    fds[0].fd = client_fd;
    fds[0].events = POLLIN;
    fds[1].fd = upstream_fd;
    fds[1].events = POLLIN;

    while (g_running) {
        if (g_reload) {
            g_reload = 0;
            fprintf(stdout, "[dns-forwarder] Reloading configuration\n");
            server_count = load_upstream_servers(config_path, servers, MAX_UPSTREAMS);
        }

        int ret = poll(fds, 2, 1000);
        if (ret < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("poll");
            break;
        }

        time_t now = time(NULL);

        if ((fds[0].revents & POLLIN) != 0) {
            handle_client_query(client_fd, upstream_fd, servers, server_count, now);
        }

        if ((fds[1].revents & POLLIN) != 0) {
            handle_upstream_response(client_fd, upstream_fd, now);
        }
    }

    close(client_fd);
    close(upstream_fd);
    fprintf(stdout, "[dns-forwarder] Stopped\n");
    return 0;
}
