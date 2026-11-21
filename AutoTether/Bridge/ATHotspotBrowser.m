#import "ATHotspotBrowser.h"
#import <objc/message.h>
#import <dlfcn.h>

@implementation ATHotspotDevice
@end

@interface ATHotspotBrowser ()
@property (nonatomic, strong, nullable) id session;
@property (atomic, copy) NSArray *rawDevices;
@end

@implementation ATHotspotBrowser

- (instancetype)init {
    if ((self = [super init])) {
        dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW);
        Class cls = NSClassFromString(@"SFRemoteHotspotSession");
        if (cls) { _session = [cls new]; }
        _rawDevices = @[];
    }
    return self;
}

- (BOOL)isAvailable { return self.session != nil; }

- (void)start {
    if (!self.session) return;
    // Disable instead of crashing if a macOS update changes the private API.
    if (![self.session respondsToSelector:NSSelectorFromString(@"setDelegate:")] ||
        ![self.session respondsToSelector:NSSelectorFromString(@"enableHotspotForDevice:withCompletionHandler:")]) {
        self.session = nil;
        return;
    }
    @try { [self.session setValue:self forKey:@"delegate"]; }
    @catch (__unused id e) { self.session = nil; return; }
    SEL sel = NSSelectorFromString(@"startBrowsing");
    if ([self.session respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(self.session, sel);
}

static id ATValue(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; } @catch (__unused id e) { return nil; }
}

- (void)session:(id)session updatedFoundDevices:(NSArray *)list {
    NSArray *snapshot = [list isKindOfClass:NSArray.class] ? [list copy] : @[];
    self.rawDevices = snapshot;
    NSMutableArray<ATHotspotDevice *> *out = [NSMutableArray array];
    for (id d in snapshot) {
        ATHotspotDevice *dev = [ATHotspotDevice new];
        dev.name = [ATValue(d, @"deviceName") description] ?: @"?";
        dev.identifier = [ATValue(d, @"deviceIdentifier") description] ?: dev.name;
        dev.model = [ATValue(d, @"model") description] ?: @"";
        dev.batteryLife = [ATValue(d, @"batteryLife") integerValue];
        dev.signalStrength = [ATValue(d, @"signalStrength") integerValue];
        [out addObject:dev];
    }
    void (^cb)(NSArray *) = self.onDevicesChanged;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(out); });
}

- (void)enableHotspotForDeviceWithIdentifier:(NSString *)identifier completion:(ATHotspotCompletion)completion {
    __block BOOL done = NO;
    void (^finish)(NSString *, NSString *, NSError *) = ^(NSString *s, NSString *p, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) return;
            done = YES;
            completion(s, p, e);
        });
    };
    id device = nil;
    for (id d in self.rawDevices) {
        NSString *ident = [ATValue(d, @"deviceIdentifier") description] ?: [ATValue(d, @"deviceName") description];
        if ([ident isEqualToString:identifier]) { device = d; break; }
    }
    if (!self.session || !device) {
        finish(nil, nil, [NSError errorWithDomain:@"AutoTether" code:1 userInfo:@{NSLocalizedDescriptionKey: @"기기를 찾을 수 없음"}]);
        return;
    }
    SEL sel = NSSelectorFromString(@"enableHotspotForDevice:withCompletionHandler:");
    if (![self.session respondsToSelector:sel]) {
        finish(nil, nil, [NSError errorWithDomain:@"AutoTether" code:2 userInfo:@{NSLocalizedDescriptionKey: @"이 macOS에서 지원되지 않는 API"}]);
        return;
    }
    // Observed on macOS 26–27: (ssid, password, ?, error).
    void (^handler)(id, id, id, id) = ^(id a, id b, id c, id d) {
        NSString *ssid = [a isKindOfClass:NSString.class] ? a : nil;
        NSString *pw = [b isKindOfClass:NSString.class] ? b : nil;
        NSError *err = [d isKindOfClass:NSError.class] ? d : ([c isKindOfClass:NSError.class] ? c : nil);
        if (ssid.length) finish(ssid, pw, nil);
        else finish(nil, nil, err ?: [NSError errorWithDomain:@"AutoTether" code:3 userInfo:@{NSLocalizedDescriptionKey: @"기기 응답 없음"}]);
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.session, sel, device, handler);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        finish(nil, nil, [NSError errorWithDomain:@"AutoTether" code:4 userInfo:@{NSLocalizedDescriptionKey: @"시간 초과"}]);
    });
}

@end
