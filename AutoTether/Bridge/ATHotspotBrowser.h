// Thin wrapper around the private Sharing.framework class SFRemoteHotspotSession —
// the same API behind the "Personal Hotspot" section of the macOS Wi-Fi menu (Instant Hotspot).
// It can see nearby iPhone/iPad on the same Apple ID, wake their hotspot over Bluetooth,
// and returns the hotspot SSID + password.
// Approach adapted from github.com/samihalawa/mac-auto-hotspot (MIT).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ATHotspotDevice : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *model;
@property (nonatomic) NSInteger batteryLife;
@property (nonatomic) NSInteger signalStrength;
@property (nonatomic) NSInteger networkType;
@end

typedef void (^ATHotspotCompletion)(NSString *_Nullable ssid, NSString *_Nullable password, NSError *_Nullable error);

@interface ATHotspotBrowser : NSObject
@property (nonatomic, readonly) BOOL isAvailable;
@property (nonatomic, copy, nullable) void (^onDevicesChanged)(NSArray<ATHotspotDevice *> *devices);
- (void)start;
- (void)stop;
/// Asks the device to turn on its Personal Hotspot. Completion is called exactly once (main queue), with a 15 s timeout.
- (void)enableHotspotForDeviceWithIdentifier:(NSString *)identifier completion:(ATHotspotCompletion)completion;
@end

NS_ASSUME_NONNULL_END
