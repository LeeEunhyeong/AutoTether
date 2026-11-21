// 64-bit byte counters via sysctl(NET_RT_IFLIST2); getifaddrs wraps at 4 GB.
// Technique from github.com/exelban/stats (MIT).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
BOOL ATReadInterfaceCounters(NSString *interfaceName, uint64_t *rxBytes, uint64_t *txBytes);
NS_ASSUME_NONNULL_END
