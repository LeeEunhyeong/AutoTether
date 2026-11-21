// 64-bit per-interface byte counters via sysctl(NET_RT_IFLIST2).
// (if_data from getifaddrs is 32-bit and wraps at 4 GB.) Technique from github.com/exelban/stats (MIT).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Returns NO if the interface is unknown.
BOOL ATReadInterfaceCounters(NSString *interfaceName, uint64_t *rxBytes, uint64_t *txBytes);
NS_ASSUME_NONNULL_END
