#import "ATInterfaceCounters.h"
#import <sys/sysctl.h>
#import <sys/socket.h>
#import <net/if.h>
#import <net/route.h>

BOOL ATReadInterfaceCounters(NSString *interfaceName, uint64_t *rxBytes, uint64_t *txBytes) {
    unsigned int index = if_nametoindex(interfaceName.UTF8String);
    if (index == 0) return NO;
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, (int)index};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0 || len == 0) return NO;
    char *buf = malloc(len);
    if (!buf) return NO;
    BOOL found = NO;
    if (sysctl(mib, 6, buf, &len, NULL, 0) == 0) {
        char *p = buf, *end = buf + len;
        while (p + sizeof(struct if_msghdr) <= end) {
            struct if_msghdr *ifm = (struct if_msghdr *)p;
            size_t msglen = ifm->ifm_msglen;
            if (msglen < sizeof(struct if_msghdr) || msglen > (size_t)(end - p)) break;
            if (ifm->ifm_version != RTM_VERSION) { p += msglen; continue; }
            if (ifm->ifm_type == RTM_IFINFO2 && msglen >= sizeof(struct if_msghdr2)) {
                struct if_msghdr2 *if2 = (struct if_msghdr2 *)p;
                if (if2->ifm_index == index) {
                    *rxBytes = if2->ifm_data.ifi_ibytes;
                    *txBytes = if2->ifm_data.ifi_obytes;
                    found = YES;
                    break;
                }
            }
            p += msglen;
        }
    }
    free(buf);
    return found;
}
