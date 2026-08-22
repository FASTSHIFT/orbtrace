// stream_recvmmsg — high-throughput UDP receiver using recvmmsg(2) to batch
// many datagrams per syscall, testing whether the ~112MB/s frame loss is a
// single-thread recvfrom per-packet overhead (fixable in software) or a hard
// NIC ceiling (not).
//
// Binds 192.168.10.245:5555 on the given iface (SO_BINDTODEVICE), receives for
// N seconds, tracks the 4-byte big-endian per-packet sequence for gaps.
//
// Build: gcc -O2 -o stream_recvmmsg stream_recvmmsg.c
// Run  : sudo ./stream_recvmmsg <iface> <seconds> [rcvbuf_mb]
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BATCH 1024
#define PKTMAX 2048

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char** argv)
{
    const char* iface = argc > 1 ? argv[1] : "enxc8a36266dcae";
    double secs = argc > 2 ? atof(argv[2]) : 30.0;
    int rcvbuf_mb = argc > 3 ? atoi(argv[3]) : 256;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    int rb = rcvbuf_mb * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rb, sizeof rb);
    int rb_act = 0; socklen_t rl = sizeof rb_act;
    getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rb_act, &rl);

    if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, iface, strlen(iface)) < 0)
        perror("SO_BINDTODEVICE (need root)");

    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(5555);
    inet_pton(AF_INET, "192.168.10.245", &a.sin_addr);
    if (bind(fd, (struct sockaddr*)&a, sizeof a) < 0) { perror("bind"); return 1; }

    // recvmmsg batch buffers
    static struct mmsghdr msgs[BATCH];
    static struct iovec iovs[BATCH];
    static uint8_t bufs[BATCH][PKTMAX];
    for (int i = 0; i < BATCH; i++) {
        iovs[i].iov_base = bufs[i];
        iovs[i].iov_len = PKTMAX;
        msgs[i].msg_hdr.msg_iov = &iovs[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
    }

    struct timespec to = { 1, 0 };
    uint64_t npkt = 0, nbytes = 0, gaps = 0, lost = 0;
    int have_prev = 0;
    uint32_t seq_prev = 0;
    double t0 = now_s(), tend = t0 + secs, t_first = 0;

    while (now_s() < tend) {
        int n = recvmmsg(fd, msgs, BATCH, MSG_WAITFORONE, &to);
        if (n <= 0) continue;
        if (t_first == 0) t_first = now_s();
        for (int i = 0; i < n; i++) {
            unsigned len = msgs[i].msg_len;
            if (len < 4) continue;
            uint8_t* p = bufs[i];
            uint32_t seq = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
                | ((uint32_t)p[2] << 8) | p[3];
            if (have_prev) {
                uint32_t d = seq - seq_prev; // wraps mod 2^32
                if (d != 1 && d < 0x80000000u) {
                    gaps++;
                    lost += d - 1;
                }
            }
            seq_prev = seq;
            have_prev = 1;
            npkt++;
            nbytes += len - 4;
        }
    }
    double dt = now_s() - (t_first ? t_first : t0);
    close(fd);

    printf("recvmmsg BATCH=%d rcvbuf=%.0fMB\n", BATCH, rb_act / 1e6);
    printf("packets=%llu bytes=%llu (%.1f MB) in %.2fs -> %.1f MB/s\n",
        (unsigned long long)npkt, (unsigned long long)nbytes, nbytes / 1e6, dt,
        dt > 0 ? nbytes / dt / 1e6 : 0);
    printf("seq-gap events=%llu lost-frames=%llu  (%s)\n",
        (unsigned long long)gaps, (unsigned long long)lost,
        gaps == 0 ? "ZERO LOSS" : "LOSS");
    return gaps == 0 ? 0 : 1;
}
