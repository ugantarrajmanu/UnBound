#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

/// Google's Android Open Accessory (AOA) mode identifiers.
static const uint16_t UNBAccessoryVendorID = 0x18D1;
static const uint16_t UNBAccessoryProductIDMin = 0x2D00; // accessory
static const uint16_t UNBAccessoryProductIDMax = 0x2D05; // accessory + adb/audio variants

/// Snapshot of one attached USB device.
@interface UNBUSBDeviceInfo : NSObject
@property (nonatomic, readonly) io_service_t service;
@property (nonatomic, readonly) uint16_t vendorID;
@property (nonatomic, readonly) uint16_t productID;
@property (nonatomic, readonly) uint64_t registryID;
@property (nonatomic, readonly, copy) NSString *productName;
/// bInterfaceClass of every interface currently published for the device.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *interfaceClasses;
@property (nonatomic, readonly) BOOL isAccessoryMode;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface UNBUSB : NSObject
+ (NSArray<UNBUSBDeviceInfo *> *)connectedDevices;

/// AOA handshake: GET_PROTOCOL, SEND_STRING ×6, START. The device then disconnects and
/// re-enumerates as an accessory (vendor 0x18D1). Returns the AOA protocol version, or 0 on failure.
+ (NSInteger)startAccessoryMode:(UNBUSBDeviceInfo *)device
                   manufacturer:(NSString *)manufacturer
                          model:(NSString *)model
                    description:(NSString *)description
                        version:(NSString *)version
                            uri:(NSString *)uri
                         serial:(NSString *)serial
                          error:(NSError **)error;
@end

/// Bulk IN/OUT pipes of a device that is already in accessory mode.
@interface UNBAccessoryConnection : NSObject
- (nullable instancetype)initWithDevice:(UNBUSBDeviceInfo *)device error:(NSError **)error;
/// Blocking read into `buffer` (its length is the maximum). Returns bytes read, or -1 on error/close.
- (NSInteger)readInto:(NSMutableData *)buffer error:(NSError **)error;
/// Blocking write of the whole buffer (chunked; ends with a zero-length packet when needed).
- (BOOL)writeData:(NSData *)data error:(NSError **)error;
/// Aborts pending I/O and releases the device. Safe to call more than once, from any thread.
- (void)close;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
