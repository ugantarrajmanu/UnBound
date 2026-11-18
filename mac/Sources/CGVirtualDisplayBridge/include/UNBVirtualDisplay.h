#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const UNBVirtualDisplayErrorDomain;

typedef NS_ERROR_ENUM(UNBVirtualDisplayErrorDomain, UNBVirtualDisplayErrorCode) {
    UNBVirtualDisplayErrorUnsupported = 1,
    UNBVirtualDisplayErrorCreationFailed = 2,
    UNBVirtualDisplayErrorApplySettingsFailed = 3,
    UNBVirtualDisplayErrorException = 4,
};

/// Thin, crash-safe wrapper around the private CGVirtualDisplay API.
/// The display exists for as long as this object is alive (or until -invalidate).
@interface UNBVirtualDisplay : NSObject

/// YES if every private class/selector this wrapper relies on is present.
+ (BOOL)isSupported;
/// Names of private classes/selectors that could not be resolved (empty when supported).
+ (NSArray<NSString *> *)missingAPIs;

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
@property (nonatomic, readonly) BOOL hiDPI;

- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                         serialNumber:(uint32_t)serialNumber
                   terminationHandler:(nullable void (^)(void))terminationHandler
                                error:(NSError **)error;

/// Change the active mode (resolution / refresh rate / HiDPI) of a live display.
- (BOOL)applyWidth:(NSUInteger)width
            height:(NSUInteger)height
       refreshRate:(double)refreshRate
             hiDPI:(BOOL)hiDPI
             error:(NSError **)error;

/// Destroys the display. Safe to call more than once.
- (void)invalidate;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
