#import "UNBUSB.h"
#import <IOUSBHost/IOUSBHost.h>

static NSError *UNBUSBError(NSString *message) {
    return [NSError errorWithDomain:@"UNBUSB" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Opens the device; if another client holds it, politely asks that owner to close (DeviceSeize).
/// Only called for devices that already passed the Android filter. Never uses DeviceCapture.
static IOUSBHostDevice *UNBOpenDevice(io_service_t service, NSError **error) {
    NSError *first = nil;
    IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service options:IOUSBHostObjectInitOptionsNone
                                                                   queue:nil error:&first interestHandler:nil];
    if (device) return device;
    device = [[IOUSBHostDevice alloc] initWithIOService:service options:IOUSBHostObjectInitOptionsDeviceSeize
                                                  queue:nil error:error interestHandler:nil];
    if (!device && error) {
        // Name the owner so the user knows what to quit (on developer Macs it is usually adb).
        CFTypeRef owner = IORegistryEntryCreateCFProperty(service, CFSTR("UsbExclusiveOwner"), kCFAllocatorDefault, 0);
        NSString *ownerName = CFBridgingRelease(owner);
        if ([ownerName isKindOfClass:[NSString class]]) {
            NSString *hint = [ownerName containsString:@"adb"]
                ? @" Stop it with `adb kill-server` (or quit Android Studio) and unplug/replug the tablet."
                : @" Quit that app and unplug/replug the tablet.";
            *error = [NSError errorWithDomain:@"UNBUSB" code:2 userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"The tablet's USB connection is in use by %@.%@", ownerName, hint]}];
        } else if (*error == nil) {
            *error = first;
        }
    }
    return device;
}

static NSNumber *UNBNumberProperty(io_registry_entry_t entry, NSString *key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    id obj = CFBridgingRelease(value);
    return [obj isKindOfClass:[NSNumber class]] ? obj : nil;
}

static NSString *UNBStringProperty(io_registry_entry_t entry, NSString *key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    id obj = CFBridgingRelease(value);
    return [obj isKindOfClass:[NSString class]] ? obj : nil;
}

#pragma mark - Device info

@implementation UNBUSBDeviceInfo

- (instancetype)initWithService:(io_service_t)service {
    self = [super init];
    if (!self) return nil;
    IOObjectRetain(service);
    _service = service;
    _vendorID = UNBNumberProperty(service, @"idVendor").unsignedShortValue;
    _productID = UNBNumberProperty(service, @"idProduct").unsignedShortValue;
    uint64_t rid = 0;
    IORegistryEntryGetRegistryEntryID(service, &rid);
    _registryID = rid;
    _productName = UNBStringProperty(service, @"USB Product Name")
        ?: UNBStringProperty(service, @"kUSBProductString") ?: @"USB device";

    NSMutableArray<NSNumber *> *classes = [NSMutableArray array];
    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &children) == KERN_SUCCESS) {
        io_registry_entry_t child;
        while ((child = IOIteratorNext(children))) {
            if (IOObjectConformsTo(child, "IOUSBHostInterface")) {
                NSNumber *cls = UNBNumberProperty(child, @"bInterfaceClass");
                if (cls) [classes addObject:cls];
            }
            IOObjectRelease(child);
        }
        IOObjectRelease(children);
    }
    _interfaceClasses = classes;
    return self;
}

- (BOOL)isAccessoryMode {
    return _vendorID == UNBAccessoryVendorID && _productID >= UNBAccessoryProductIDMin && _productID <= UNBAccessoryProductIDMax;
}

- (void)dealloc {
    IOObjectRelease(_service);
}

@end

#pragma mark - Enumeration + AOA handshake

@implementation UNBUSB

+ (NSArray<UNBUSBDeviceInfo *> *)connectedDevices {
    NSMutableArray *result = [NSMutableArray array];
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) != KERN_SUCCESS) {
        return result;
    }
    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        [result addObject:[[UNBUSBDeviceInfo alloc] initWithService:service]];
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return result;
}

+ (NSInteger)startAccessoryMode:(UNBUSBDeviceInfo *)info
                   manufacturer:(NSString *)manufacturer
                          model:(NSString *)model
                    description:(NSString *)description
                        version:(NSString *)version
                            uri:(NSString *)uri
                         serial:(NSString *)serial
                          error:(NSError **)error {
    IOUSBHostDevice *device = UNBOpenDevice(info.service, error);
    if (!device) return 0;

    NSInteger protocol = 0;
    @try {
        // GET_PROTOCOL (51): device-to-host vendor request, 2-byte little-endian version.
        IOUSBDeviceRequest getProtocol = {.bmRequestType = 0xC0, .bRequest = 51, .wValue = 0, .wIndex = 0, .wLength = 2};
        NSMutableData *versionData = [NSMutableData dataWithLength:2];
        NSUInteger transferred = 0;
        if (![device sendDeviceRequest:getProtocol data:versionData bytesTransferred:&transferred
                     completionTimeout:2.0 error:error] || transferred < 2) {
            return 0;
        }
        const uint8_t *v = versionData.bytes;
        protocol = v[0] | (v[1] << 8);
        if (protocol < 1) {
            if (error) *error = UNBUSBError(@"Device does not support Android Open Accessory");
            return 0;
        }

        // SEND_STRING (52) for each identifying string; wIndex selects which one.
        NSArray<NSString *> *strings = @[manufacturer, model, description, version, uri, serial];
        for (NSUInteger i = 0; i < strings.count; i++) {
            NSMutableData *payload = [[strings[i] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
            [payload appendBytes:"\0" length:1];
            IOUSBDeviceRequest send = {.bmRequestType = 0x40, .bRequest = 52, .wValue = 0,
                                       .wIndex = (uint16_t)i, .wLength = (uint16_t)payload.length};
            if (![device sendDeviceRequest:send data:payload bytesTransferred:nil completionTimeout:2.0 error:error]) {
                return 0;
            }
        }

        // START (53): the device re-enumerates in accessory mode.
        IOUSBDeviceRequest start = {.bmRequestType = 0x40, .bRequest = 53, .wValue = 0, .wIndex = 0, .wLength = 0};
        if (![device sendDeviceRequest:start data:nil bytesTransferred:nil completionTimeout:2.0 error:error]) {
            return 0;
        }
    } @finally {
        [device destroy];
    }
    return protocol;
}

@end

#pragma mark - Accessory connection

@implementation UNBAccessoryConnection {
    IOUSBHostDevice *_device;
    IOUSBHostInterface *_interface;
    IOUSBHostPipe *_inPipe;
    IOUSBHostPipe *_outPipe;
    NSUInteger _maxPacketSize;
    NSLock *_closeLock;
    BOOL _closed;
}

- (nullable instancetype)initWithDevice:(UNBUSBDeviceInfo *)info error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _closeLock = [NSLock new];

    if (!info.isAccessoryMode) {
        if (error) *error = UNBUSBError(@"Device is not in accessory mode");
        return nil;
    }
    _device = UNBOpenDevice(info.service, error);
    if (!_device) return nil;

    if (_device.configurationDescriptor == NULL) {
        if (![_device configureWithValue:1 matchInterfaces:YES error:error]) { [self close]; return nil; }
    }

    // Interface 0 carries the accessory bulk endpoints. It may take a moment to publish.
    io_service_t interfaceService = IO_OBJECT_NULL;
    for (int attempt = 0; attempt < 40 && interfaceService == IO_OBJECT_NULL; attempt++) {
        io_iterator_t children = IO_OBJECT_NULL;
        if (IORegistryEntryCreateIterator(info.service, kIOServicePlane, kIORegistryIterateRecursively, &children) == KERN_SUCCESS) {
            io_registry_entry_t child;
            while ((child = IOIteratorNext(children))) {
                if (interfaceService == IO_OBJECT_NULL && IOObjectConformsTo(child, "IOUSBHostInterface") &&
                    UNBNumberProperty(child, @"bInterfaceNumber").integerValue == 0) {
                    interfaceService = child;
                } else {
                    IOObjectRelease(child);
                }
            }
            IOObjectRelease(children);
        }
        if (interfaceService == IO_OBJECT_NULL) [NSThread sleepForTimeInterval:0.05];
    }
    if (interfaceService == IO_OBJECT_NULL) {
        if (error) *error = UNBUSBError(@"Accessory interface did not appear");
        [self close];
        return nil;
    }

    _interface = [[IOUSBHostInterface alloc] initWithIOService:interfaceService options:IOUSBHostObjectInitOptionsNone
                                                         queue:nil error:error interestHandler:nil];
    IOObjectRelease(interfaceService);
    if (!_interface) { [self close]; return nil; }

    const IOUSBConfigurationDescriptor *config = _interface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *intf = _interface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *ep = NULL;
    while ((ep = IOUSBGetNextEndpointDescriptor(config, intf, (const IOUSBDescriptorHeader *)ep))) {
        if (IOUSBGetEndpointType(ep) != kIOUSBEndpointTypeBulk) continue;
        uint8_t address = ep->bEndpointAddress;
        NSUInteger mps = OSSwapLittleToHostInt16(ep->wMaxPacketSize) & 0x7FF;
        IOUSBHostPipe *pipe = [_interface copyPipeWithAddress:address error:error];
        if (!pipe) { [self close]; return nil; }
        if (address & 0x80) {
            if (!_inPipe) _inPipe = pipe;
        } else if (!_outPipe) {
            _outPipe = pipe;
            _maxPacketSize = mps ?: 512;
        }
    }
    if (!_inPipe || !_outPipe) {
        if (error) *error = UNBUSBError(@"Accessory bulk endpoints not found");
        [self close];
        return nil;
    }
    return self;
}

- (NSInteger)readInto:(NSMutableData *)buffer error:(NSError **)error {
    IOUSBHostPipe *pipe = _inPipe;
    if (!pipe) { if (error) *error = UNBUSBError(@"closed"); return -1; }
    NSUInteger transferred = 0;
    if (![pipe sendIORequestWithData:buffer bytesTransferred:&transferred completionTimeout:0 error:error]) {
        return -1;
    }
    return (NSInteger)transferred;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    IOUSBHostPipe *pipe = _outPipe;
    if (!pipe) { if (error) *error = UNBUSBError(@"closed"); return NO; }
    const NSUInteger chunk = 256 * 1024;
    for (NSUInteger offset = 0; offset < data.length; offset += chunk) {
        NSUInteger len = MIN(chunk, data.length - offset);
        NSMutableData *piece = [[data subdataWithRange:NSMakeRange(offset, len)] mutableCopy];
        NSUInteger transferred = 0;
        if (![pipe sendIORequestWithData:piece bytesTransferred:&transferred completionTimeout:0 error:error]) return NO;
    }
    // A transfer that is an exact multiple of the packet size needs a ZLP to terminate it,
    // otherwise the tablet's read stays pending until more data arrives.
    if (data.length > 0 && _maxPacketSize > 0 && data.length % _maxPacketSize == 0) {
        if (![pipe sendIORequestWithData:nil bytesTransferred:nil completionTimeout:0 error:error]) return NO;
    }
    return YES;
}

- (void)close {
    [_closeLock lock];
    if (_closed) { [_closeLock unlock]; return; }
    _closed = YES;
    IOUSBHostInterface *intf = _interface;
    IOUSBHostDevice *device = _device;
    [_closeLock unlock];
    // Destroying the interface aborts in-flight requests, unblocking reader/writer threads.
    [intf destroy];
    [device destroy];
}

- (void)dealloc {
    [self close];
}

@end
