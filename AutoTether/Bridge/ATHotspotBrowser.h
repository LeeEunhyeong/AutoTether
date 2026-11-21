// Wraps the private SFRemoteHotspotSession (Sharing.framework) used by the Wi-Fi menu's Personal Hotspot section.
// Based on github.com/samihalawa/mac-auto-hotspot (MIT).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ATHotspotDevice : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *model;
@property (nonatomic) NSInteger batteryLife;
@property (nonatomic) NSInteger signalStrength;
@end

typedef void (^ATHotspotCompletion)(NSString *_Nullable ssid, NSString *_Nullable password, NSError *_Nullable error);

@interface ATHotspotBrowser : NSObject
@property (nonatomic, readonly) BOOL isAvailable;
@property (nonatomic, copy, nullable) void (^onDevicesChanged)(NSArray<ATHotspotDevice *> *devices);
- (void)start;
// Completion runs once on the main queue; times out after 15 s.
- (void)enableHotspotForDeviceWithIdentifier:(NSString *)identifier completion:(ATHotspotCompletion)completion;
@end

NS_ASSUME_NONNULL_END
