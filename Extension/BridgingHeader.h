//
//  BridgingHeader.h
//  RoutingDiag / Extension
//
//  iOS's public SDK omits `<net/route.h>` even though the underlying
//  `sysctl(PF_ROUTE, NET_RT_DUMP, ...)` interface is still usable.
//  We provide the minimum declarations RoutingTable.swift needs
//  inline here, copied verbatim from the open-source macOS headers
//  (https://github.com/apple/darwin-xnu/blob/main/bsd/net/route.h).
//
//  `sockaddr_dl` (AF_LINK addresses) lives in a header that *is*
//  shipped on iOS, so we just pull that in.
//

#import <net/if_dl.h>

// --- from <net/route.h> ---

// Route message index constants — order of sockaddrs in the variable
// block following `rt_msghdr`.
#define RTAX_DST        0
#define RTAX_GATEWAY    1
#define RTAX_NETMASK    2
#define RTAX_GENMASK    3
#define RTAX_IFP        4
#define RTAX_IFA        5
#define RTAX_AUTHOR     6
#define RTAX_BRD        7
#define RTAX_MAX        8

// Route flags.
#define RTF_UP          0x1
#define RTF_GATEWAY     0x2
#define RTF_HOST        0x4
#define RTF_REJECT      0x8
#define RTF_DYNAMIC     0x10
#define RTF_MODIFIED    0x20
#define RTF_DONE        0x40
#define RTF_CLONING     0x100
#define RTF_XRESOLVE    0x200
#define RTF_LLINFO      0x400
#define RTF_STATIC      0x800
#define RTF_BLACKHOLE   0x1000
#define RTF_NOIFREF     0x2000
#define RTF_PRCLONING   0x10000
#define RTF_WASCLONED   0x20000
#define RTF_PINNED      0x100000
#define RTF_LOCAL       0x200000
#define RTF_BROADCAST   0x400000
#define RTF_MULTICAST   0x800000
#define RTF_IFSCOPE     0x1000000
#define RTF_ROUTER      0x80000000

// Route message types.
#define RTM_VERSION     5

#define RTM_ADD         0x1
#define RTM_DELETE      0x2
#define RTM_CHANGE      0x3
#define RTM_GET         0x4

// RTA_* — bitmask for rtm_addrs. Equivalent to (1 << RTAX_*).
#define RTA_DST         0x1
#define RTA_GATEWAY     0x2
#define RTA_NETMASK     0x4
#define RTA_GENMASK     0x8
#define RTA_IFP         0x10
#define RTA_IFA         0x20
#define RTA_AUTHOR      0x40
#define RTA_BRD         0x80

struct rt_metrics {
    u_int32_t rmx_locks;
    u_int32_t rmx_mtu;
    u_int32_t rmx_hopcount;
    int32_t   rmx_expire;
    u_int32_t rmx_recvpipe;
    u_int32_t rmx_sendpipe;
    u_int32_t rmx_ssthresh;
    u_int32_t rmx_rtt;
    u_int32_t rmx_rttvar;
    u_int32_t rmx_pksent;
    u_int32_t rmx_state;
    u_int32_t rmx_filler[3];
};

struct rt_msghdr {
    u_short   rtm_msglen;
    u_char    rtm_version;
    u_char    rtm_type;
    u_short   rtm_index;
    int       rtm_flags;
    int       rtm_addrs;
    pid_t     rtm_pid;
    int       rtm_seq;
    int       rtm_errno;
    int       rtm_use;
    u_int32_t rtm_inits;
    struct rt_metrics rtm_rmx;
};
