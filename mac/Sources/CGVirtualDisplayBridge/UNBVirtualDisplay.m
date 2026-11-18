#import "UNBVirtualDisplay.h"

NSErrorDomain const UNBVirtualDisplayErrorDomain = @"UNBVirtualDisplayErrorDomain";

// ---------------------------------------------------------------------------
// Private API surface (CoreGraphics, undocumented). Declared as protocols so the
// compiler emits no class references: nothing here can fail at link/load time.
// Shape matches prior art (DeskPad, Chromium's virtual_display_mac_util).
// ---------------------------------------------------------------------------
@protocol UNBPrivateVirtualDisplayMode <NSObject>
- (id)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@protocol UNBPrivateVirtualDisplay <NSObject>
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@end

static NSString *const kDisplayClass = @"CGVirtualDisplay";
static NSString *const kDescriptorClass = @"CGVirtualDisplayDescriptor";
static NSString *const kSettingsClass = @"CGVirtualDisplaySettings";
static NSString *const kModeClass = @"CGVirtualDisplayMode";

static NSError *UNBError(UNBVirtualDisplayErrorCode code, NSString *message) {
    return [NSError errorWithDomain:UNBVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation UNBVirtualDisplay {
    id _display;                 // CGVirtualDisplay *
    dispatch_queue_t _queue;
}

+ (NSArray<NSString *> *)missingAPIs {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    Class display = NSClassFromString(kDisplayClass);
    Class descriptor = NSClassFromString(kDescriptorClass);
    Class settings = NSClassFromString(kSettingsClass);
    Class mode = NSClassFromString(kModeClass);
    if (!display) [missing addObject:kDisplayClass];
    if (!descriptor) [missing addObject:kDescriptorClass];
    if (!settings) [missing addObject:kSettingsClass];
    if (!mode) [missing addObject:kModeClass];

    if (display) {
        if (![display instancesRespondToSelector:@selector(initWithDescriptor:)]) [missing addObject:@"-[CGVirtualDisplay initWithDescriptor:]"];
        if (![display instancesRespondToSelector:@selector(applySettings:)]) [missing addObject:@"-[CGVirtualDisplay applySettings:]"];
        if (![display instancesRespondToSelector:@selector(displayID)]) [missing addObject:@"-[CGVirtualDisplay displayID]"];
    }
    if (mode && ![mode instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) {
        [missing addObject:@"-[CGVirtualDisplayMode initWithWidth:height:refreshRate:]"];
    }
    if (descriptor) {
        for (NSString *setter in @[@"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:",
                                   @"setSerialNum:", @"setProductID:", @"setVendorID:", @"setQueue:", @"setTerminationHandler:"]) {
            if (![descriptor instancesRespondToSelector:NSSelectorFromString(setter)]) {
                [missing addObject:[NSString stringWithFormat:@"-[CGVirtualDisplayDescriptor %@]", setter]];
            }
        }
    }
    if (settings) {
        for (NSString *setter in @[@"setModes:", @"setHiDPI:"]) {
            if (![settings instancesRespondToSelector:NSSelectorFromString(setter)]) {
                [missing addObject:[NSString stringWithFormat:@"-[CGVirtualDisplaySettings %@]", setter]];
            }
        }
    }
    return missing;
}

+ (BOOL)isSupported {
    return [self missingAPIs].count == 0;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                         serialNumber:(uint32_t)serialNumber
                   terminationHandler:(nullable void (^)(void))terminationHandler
                                error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    NSArray *missing = [UNBVirtualDisplay missingAPIs];
    if (missing.count > 0) {
        if (error) *error = UNBError(UNBVirtualDisplayErrorUnsupported,
                                     [NSString stringWithFormat:@"Virtual display API unavailable: %@",
                                      [missing componentsJoinedByString:@", "]]);
        return nil;
    }

    _queue = dispatch_queue_create("unbound.virtual-display", DISPATCH_QUEUE_SERIAL);

    @try {
        id descriptor = [[NSClassFromString(kDescriptorClass) alloc] init];
        // With HiDPI the backing store is 2x the mode size, so allow headroom.
        NSUInteger scale = hiDPI ? 2 : 1;
        [descriptor setValue:name forKey:@"name"];
        [descriptor setValue:@(width * scale) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(height * scale) forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithBytes:&sizeInMillimeters objCType:@encode(CGSize)]
                      forKey:@"sizeInMillimeters"];
        [descriptor setValue:@(serialNumber) forKey:@"serialNum"];
        [descriptor setValue:@(0xA11E) forKey:@"productID"];
        [descriptor setValue:@(0xA11E) forKey:@"vendorID"];
        [descriptor setValue:_queue forKey:@"queue"];
        if (terminationHandler) {
            void (^handler)(void) = [terminationHandler copy];
            id block = ^(id __unused sender, id __unused display) { handler(); };
            [descriptor setValue:block forKey:@"terminationHandler"];
        }

        id<UNBPrivateVirtualDisplay> display =
            [(id<UNBPrivateVirtualDisplay>)[NSClassFromString(kDisplayClass) alloc] initWithDescriptor:descriptor];
        if (!display || display.displayID == kCGNullDirectDisplay) {
            if (error) *error = UNBError(UNBVirtualDisplayErrorCreationFailed,
                                         @"CGVirtualDisplay initWithDescriptor: returned no display");
            return nil;
        }
        _display = display;
        _displayID = display.displayID;
    } @catch (NSException *exception) {
        if (error) *error = UNBError(UNBVirtualDisplayErrorException,
                                     [NSString stringWithFormat:@"Exception creating virtual display: %@ — %@",
                                      exception.name, exception.reason]);
        return nil;
    }

    if (![self applyWidth:width height:height refreshRate:refreshRate hiDPI:hiDPI error:error]) {
        [self invalidate];
        return nil;
    }
    return self;
}

- (BOOL)applyWidth:(NSUInteger)width
            height:(NSUInteger)height
       refreshRate:(double)refreshRate
             hiDPI:(BOOL)hiDPI
             error:(NSError **)error {
    id<UNBPrivateVirtualDisplay> display = _display;
    if (!display) {
        if (error) *error = UNBError(UNBVirtualDisplayErrorApplySettingsFailed, @"Display has been invalidated");
        return NO;
    }
    @try {
        id settings = [[NSClassFromString(kSettingsClass) alloc] init];
        [settings setValue:@(hiDPI ? 1 : 0) forKey:@"hiDPI"];
        id mode = [(id<UNBPrivateVirtualDisplayMode>)[NSClassFromString(kModeClass) alloc]
                   initWithWidth:width height:height refreshRate:refreshRate];
        if (!mode) {
            if (error) *error = UNBError(UNBVirtualDisplayErrorApplySettingsFailed, @"Could not create display mode");
            return NO;
        }
        [settings setValue:@[mode] forKey:@"modes"];
        if (![display applySettings:settings]) {
            if (error) *error = UNBError(UNBVirtualDisplayErrorApplySettingsFailed,
                                         [NSString stringWithFormat:@"applySettings: rejected %lux%lu@%.0fHz hiDPI=%d",
                                          (unsigned long)width, (unsigned long)height, refreshRate, hiDPI]);
            return NO;
        }
    } @catch (NSException *exception) {
        if (error) *error = UNBError(UNBVirtualDisplayErrorException,
                                     [NSString stringWithFormat:@"Exception applying settings: %@ — %@",
                                      exception.name, exception.reason]);
        return NO;
    }
    _width = width;
    _height = height;
    _refreshRate = refreshRate;
    _hiDPI = hiDPI;
    return YES;
}

- (void)invalidate {
    // Releasing the CGVirtualDisplay object removes the display from the system.
    _display = nil;
}

- (void)dealloc {
    [self invalidate];
}

@end
