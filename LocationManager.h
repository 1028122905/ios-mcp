#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LocationManager : NSObject <CLLocationManagerDelegate>

+ (instancetype)sharedManager;

/**
 * Obtain current device GPS / network location fix.
 *
 * @param bundleId        Optional effective bundle identifier to proxy location authorization. When nil, automatically discovers authorized candidates on the device.
 * @param timeout         Timeout in seconds (range: 1.0 ~ 60.0, default: 10.0).
 * @param desiredAccuracy Desired location accuracy in meters, defaults to kCLLocationAccuracyHundredMeters.
 * @param completion      Completion callback returning location dictionary on success or errorMessage on failure.
 */
- (void)getCurrentLocationWithBundleId:(nullable NSString *)bundleId
                               timeout:(NSTimeInterval)timeout
                       desiredAccuracy:(CLLocationAccuracy)desiredAccuracy
                            completion:(void (^)(NSDictionary * _Nullable locationInfo, NSString * _Nullable errorMessage))completion;

@end

NS_ASSUME_NONNULL_END
