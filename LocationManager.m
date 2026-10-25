#import "LocationManager.h"
#import "MCPLogger.h"
#import "SpringBoardPrivate.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define LOC_LOG(fmt, ...) do { \
    if ([MCPLogger isDebugLoggingEnabled]) { \
        NSString *_iosmcp_log = [NSString stringWithFormat:(@"[Location] " fmt), ##__VA_ARGS__]; \
        NSLog(@"[witchan][ios-mcp]%@", _iosmcp_log); \
        [MCPLogger logMessage:_iosmcp_log]; \
    } \
} while (0)

@interface UIApplication (MCPLocationPrivate)
- (id)_accessibilityFrontMostApplication;
@end

@interface CLLocationManager (MCPPrivateLocation)
- (instancetype)initWithEffectiveBundleIdentifier:(NSString *)bundleIdentifier;
- (void)setAllowsBackgroundLocationUpdates:(BOOL)allow;
+ (CLAuthorizationStatus)authorizationStatusForBundleIdentifier:(NSString *)bundleIdentifier;
@end

@interface LocationManager ()
@property (nonatomic, strong, nullable) CLLocationManager *locationManager;
@property (nonatomic, strong, nullable) CLLocation *bestLocation;
@property (nonatomic, strong) NSMutableArray<void (^)(NSDictionary * _Nullable, NSString * _Nullable)> *pendingCompletions;
@property (nonatomic, strong, nullable) dispatch_source_t timeoutTimer;
@property (nonatomic, strong, nullable) dispatch_source_t candidateStepTimer;
@property (nonatomic, assign) BOOL isUpdating;
@property (nonatomic, copy, nullable) NSString *currentBundleId;
@property (nonatomic, copy, nullable) NSString *lastSuccessfulBundleId;
@property (nonatomic, strong) NSArray<NSString *> *activeCandidates;
@property (nonatomic, assign) NSUInteger currentCandidateIndex;
@property (nonatomic, assign) BOOL userExplicitBundle;
@property (nonatomic, assign) CLLocationAccuracy requestedAccuracy;
@end

@implementation LocationManager

+ (instancetype)sharedManager {
    static LocationManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingCompletions = [NSMutableArray array];
        _activeCandidates = @[];
        _requestedAccuracy = kCLLocationAccuracyHundredMeters;
    }
    return self;
}

#pragma mark - Dynamic Authorization Discovery

- (CLAuthorizationStatus)authStatusForBundleId:(NSString *)bundleId {
    if (!bundleId || bundleId.length == 0) {
        return kCLAuthorizationStatusNotDetermined;
    }
    if ([CLLocationManager respondsToSelector:@selector(authorizationStatusForBundleIdentifier:)]) {
        return [CLLocationManager authorizationStatusForBundleIdentifier:bundleId];
    }
    return kCLAuthorizationStatusNotDetermined;
}

- (nullable NSString *)frontmostAppBundleId {
    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
        id frontApp = [app _accessibilityFrontMostApplication];
        if (frontApp && [frontApp respondsToSelector:@selector(bundleIdentifier)]) {
            NSString *bundleId = [frontApp bundleIdentifier];
            if ([bundleId isKindOfClass:[NSString class]] && bundleId.length > 0) {
                return bundleId;
            }
        }
    }
    return nil;
}

/**
 * Dynamically discover candidate application bundles granted location permissions on the device (zero hardcoding).
 * Candidate priority:
 * 1. Last successful bundle ID if still authorized
 * 2. Bundles with kCLAuthorizationStatusAuthorizedAlways
 * 3. Frontmost active application with kCLAuthorizationStatusAuthorizedWhenInUse
 * 4. Other applications with kCLAuthorizationStatusAuthorizedWhenInUse
 * 5. Fallback system defaults (e.g., Apple Maps, Weather)
 */
- (NSArray<NSString *> *)discoverAuthorizedCandidateBundles {
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];

    // 1. Prioritize reusing the last successful bundle ID
    if (self.lastSuccessfulBundleId.length > 0) {
        CLAuthorizationStatus lastStatus = [self authStatusForBundleId:self.lastSuccessfulBundleId];
        if (lastStatus == kCLAuthorizationStatusAuthorizedAlways ||
            lastStatus == kCLAuthorizationStatusAuthorizedWhenInUse) {
            [candidates addObject:self.lastSuccessfulBundleId];
        }
    }

    NSMutableArray<NSString *> *alwaysAuthorized = [NSMutableArray array];
    NSMutableArray<NSString *> *whenInUseAuthorized = [NSMutableArray array];

    NSString *frontBundleId = [self frontmostAppBundleId];
    if (frontBundleId.length > 0) {
        CLAuthorizationStatus frontStatus = [self authStatusForBundleId:frontBundleId];
        if (frontStatus == kCLAuthorizationStatusAuthorizedAlways) {
            [alwaysAuthorized addObject:frontBundleId];
        } else if (frontStatus == kCLAuthorizationStatusAuthorizedWhenInUse) {
            [whenInUseAuthorized addObject:frontBundleId];
        }
    }

    // 2. Query LaunchServices for installed applications and inspect authorization statuses
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass && [workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
        if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
            NSArray<LSApplicationProxy *> *apps = [workspace allInstalledApplications];
            for (LSApplicationProxy *proxy in apps) {
                if (![proxy respondsToSelector:@selector(applicationIdentifier)]) continue;
                NSString *appId = [proxy applicationIdentifier];
                if (![appId isKindOfClass:[NSString class]] || appId.length == 0) continue;

                CLAuthorizationStatus status = [self authStatusForBundleId:appId];
                if (status == kCLAuthorizationStatusAuthorizedAlways) {
                    [alwaysAuthorized addObject:appId];
                } else if (status == kCLAuthorizationStatusAuthorizedWhenInUse) {
                    [whenInUseAuthorized addObject:appId];
                }
            }
        }
    }

    for (NSString *b in alwaysAuthorized) {
        [candidates addObject:b];
    }
    for (NSString *b in whenInUseAuthorized) {
        [candidates addObject:b];
    }

    // 3. System defaults fallback
    [candidates addObject:@"com.apple.Maps"];
    [candidates addObject:@"com.apple.weather"];

    LOC_LOG(@"Discovered %lu candidate location bundles (Always: %lu, WhenInUse: %lu)",
            (unsigned long)candidates.count,
            (unsigned long)alwaysAuthorized.count,
            (unsigned long)whenInUseAuthorized.count);

    return [candidates array];
}

#pragma mark - Manager Setup & Lifecycle

- (void)setupLocationManagerForBundleId:(NSString *)bundleId {
    if (!bundleId || bundleId.length == 0) {
        bundleId = @"com.apple.Maps";
    }

    if (_locationManager && [_currentBundleId isEqualToString:bundleId]) {
        _locationManager.desiredAccuracy = self.requestedAccuracy;
        return;
    }

    if (_locationManager) {
        [_locationManager stopUpdatingLocation];
        _locationManager.delegate = nil;
        _locationManager = nil;
    }

    _currentBundleId = [bundleId copy];

    if ([CLLocationManager instancesRespondToSelector:@selector(initWithEffectiveBundleIdentifier:)]) {
        @try {
            _locationManager = [[CLLocationManager alloc] initWithEffectiveBundleIdentifier:bundleId];
            LOC_LOG(@"Initialized CLLocationManager with effective bundle: %@", bundleId);
        } @catch (NSException *e) {
            LOC_LOG(@"Exception in initWithEffectiveBundleIdentifier (%@): %@", bundleId, e.reason);
        }
    }

    if (!_locationManager) {
        _locationManager = [[CLLocationManager alloc] init];
        LOC_LOG(@"Initialized standard CLLocationManager");
    }

    _locationManager.delegate = self;
    _locationManager.desiredAccuracy = self.requestedAccuracy;
    _locationManager.distanceFilter = kCLDistanceFilterNone;

    if ([_locationManager respondsToSelector:@selector(setAllowsBackgroundLocationUpdates:)]) {
        @try {
            [_locationManager setAllowsBackgroundLocationUpdates:YES];
        } @catch (NSException *e) {
            LOC_LOG(@"setAllowsBackgroundLocationUpdates ignored: %@", e.reason);
        }
    }

    if ([_locationManager respondsToSelector:@selector(requestWhenInUseAuthorization)]) {
        [_locationManager requestWhenInUseAuthorization];
    }
}

- (void)scheduleCandidateStepTimer {
    if (self.candidateStepTimer) {
        dispatch_source_cancel(self.candidateStepTimer);
        self.candidateStepTimer = nil;
    }

    if (self.userExplicitBundle || self.currentCandidateIndex + 1 >= self.activeCandidates.count) {
        return;
    }

    dispatch_source_t stepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(stepTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (int64_t)(0.05 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(stepTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isUpdating) return;
        LOC_LOG(@"Candidate %@ did not yield fix within step window, advancing...", strongSelf.currentBundleId);
        [strongSelf tryNextCandidateBundle];
    });
    self.candidateStepTimer = stepTimer;
    dispatch_resume(stepTimer);
}

- (void)getCurrentLocationWithBundleId:(nullable NSString *)bundleId
                               timeout:(NSTimeInterval)timeout
                       desiredAccuracy:(CLLocationAccuracy)desiredAccuracy
                            completion:(void (^)(NSDictionary * _Nullable, NSString * _Nullable))completion {
    if (!completion) return;

    if (timeout <= 0.0) timeout = 10.0;
    if (timeout > 60.0) timeout = 60.0;

    CLLocationAccuracy targetAccuracy = (desiredAccuracy > 0) ? desiredAccuracy : kCLLocationAccuracyHundredMeters;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![CLLocationManager locationServicesEnabled]) {
            completion(nil, @"System location services are globally disabled in Settings -> Privacy -> Location Services.");
            return;
        }

        // Coalesce concurrent requests to prevent re-initializing active location updates
        if (self.isUpdating) {
            LOC_LOG(@"Coalescing concurrent location request into active session (bundle: %@)", self.currentBundleId);
            [self.pendingCompletions addObject:[completion copy]];
            return;
        }

        self.requestedAccuracy = targetAccuracy;
        self.bestLocation = nil;

        if (bundleId && bundleId.length > 0) {
            self.userExplicitBundle = YES;
            // Fast-check authorization for explicitly specified bundle
            CLAuthorizationStatus explicitStatus = [self authStatusForBundleId:bundleId];
            if (explicitStatus != kCLAuthorizationStatusAuthorizedAlways &&
                explicitStatus != kCLAuthorizationStatusAuthorizedWhenInUse) {
                NSString *msg = [NSString stringWithFormat:@"Location error: bundle '%@' is not authorized for location services (status: %d).",
                                 bundleId, (int)explicitStatus];
                completion(nil, msg);
                return;
            }
            self.activeCandidates = @[bundleId];
        } else {
            self.userExplicitBundle = NO;
            self.activeCandidates = [self discoverAuthorizedCandidateBundles];

            // Quick check if candidate bundles already possess fresh cached location (within 15 minutes)
            NSUInteger scanLimit = MIN(self.activeCandidates.count, (NSUInteger)6);
            for (NSUInteger i = 0; i < scanLimit; i++) {
                NSString *cand = self.activeCandidates[i];
                [self setupLocationManagerForBundleId:cand];
                CLLocation *cached = self.locationManager.location;
                if (cached && cached.horizontalAccuracy >= 0 && cached.horizontalAccuracy <= 5000.0) {
                    NSTimeInterval age = fabs([cached.timestamp timeIntervalSinceNow]);
                    if (age < 900.0 && cached.horizontalAccuracy <= MAX(targetAccuracy * 2.0, 200.0)) {
                        LOC_LOG(@"Pre-scan hit fresh cached location from %@ (acc: %.1fm, age: %.1fs)",
                                cand, cached.horizontalAccuracy, age);
                        self.lastSuccessfulBundleId = cand;
                        completion([self dictionaryFromLocation:cached], nil);
                        return;
                    }
                    if (!self.bestLocation || cached.horizontalAccuracy < self.bestLocation.horizontalAccuracy) {
                        self.bestLocation = cached;
                    }
                }
            }
        }

        self.currentCandidateIndex = 0;
        NSString *initialBundle = self.activeCandidates.firstObject ?: @"com.apple.Maps";
        [self setupLocationManagerForBundleId:initialBundle];

        // Check if initial candidate has valid cached location within 15 minutes
        CLLocation *cached = self.locationManager.location;
        if (cached && cached.horizontalAccuracy >= 0 && cached.horizontalAccuracy <= 5000.0) {
            NSTimeInterval age = fabs([cached.timestamp timeIntervalSinceNow]);
            if (age < 900.0 && cached.horizontalAccuracy <= MAX(targetAccuracy * 2.0, 200.0)) {
                LOC_LOG(@"Returning recent cached location (acc: %.1fm, age: %.1fs, bundle: %@)",
                        cached.horizontalAccuracy, age, self.currentBundleId);
                self.lastSuccessfulBundleId = self.currentBundleId;
                completion([self dictionaryFromLocation:cached], nil);
                return;
            }
            if (!self.bestLocation || cached.horizontalAccuracy < self.bestLocation.horizontalAccuracy) {
                self.bestLocation = cached;
            }
        }

        [self.pendingCompletions addObject:[completion copy]];
        self.isUpdating = YES;
        [self.locationManager startUpdatingLocation];
        [self scheduleCandidateStepTimer];
        LOC_LOG(@"Started updating location (bundle: %@, timeout: %.1fs, desiredAccuracy: %.1fm)",
                self.currentBundleId, timeout, self.requestedAccuracy);

        if (self.timeoutTimer) {
            dispatch_source_cancel(self.timeoutTimer);
        }
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER,
                                  (int64_t)(0.1 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            [weakSelf handleTimeout];
        });
        self.timeoutTimer = timer;
        dispatch_resume(timer);
    });
}

- (NSDictionary *)dictionaryFromLocation:(CLLocation *)location {
    if (!location) return nil;

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *isoTime = [formatter stringFromDate:location.timestamp];

    return @{
        @"latitude": @(location.coordinate.latitude),
        @"longitude": @(location.coordinate.longitude),
        @"altitude": @(location.altitude),
        @"horizontal_accuracy": @(location.horizontalAccuracy),
        @"vertical_accuracy": @(location.verticalAccuracy),
        @"speed": @(location.speed),
        @"course": @(location.course),
        @"timestamp": @([location.timestamp timeIntervalSince1970]),
        @"timestamp_iso": isoTime ?: @"",
        @"effective_bundle_id": self.currentBundleId ?: @""
    };
}

- (void)finishWithLocation:(nullable CLLocation *)location error:(nullable NSString *)error {
    if (self.candidateStepTimer) {
        dispatch_source_cancel(self.candidateStepTimer);
        self.candidateStepTimer = nil;
    }

    if (self.timeoutTimer) {
        dispatch_source_cancel(self.timeoutTimer);
        self.timeoutTimer = nil;
    }

    if (self.isUpdating) {
        [self.locationManager stopUpdatingLocation];
        self.isUpdating = NO;
    }

    if (location && self.currentBundleId.length > 0) {
        self.lastSuccessfulBundleId = self.currentBundleId;
    }

    NSArray *callbacks = [self.pendingCompletions copy];
    [self.pendingCompletions removeAllObjects];

    NSDictionary *info = [self dictionaryFromLocation:location];
    for (void (^cb)(NSDictionary *, NSString *) in callbacks) {
        cb(info, error);
    }
}

- (void)handleTimeout {
    LOC_LOG(@"Location request timed out (bestLocation: %@)", self.bestLocation);
    if (self.bestLocation && self.bestLocation.horizontalAccuracy >= 0) {
        [self finishWithLocation:self.bestLocation error:nil];
    } else {
        NSString *msg = [NSString stringWithFormat:@"Timed out waiting for location fix (bundle: '%@'). Ensure Location Services are enabled and at least one app has 'Always' or active 'While Using' location permission.",
                         self.currentBundleId ?: @"unknown"];
        [self finishWithLocation:nil error:msg];
    }
}

- (BOOL)tryNextCandidateBundle {
    while (self.currentCandidateIndex + 1 < self.activeCandidates.count) {
        self.currentCandidateIndex++;
        NSString *nextBundle = self.activeCandidates[self.currentCandidateIndex];
        LOC_LOG(@"Switching to next candidate bundle (%lu/%lu): %@",
                (unsigned long)(self.currentCandidateIndex + 1),
                (unsigned long)self.activeCandidates.count,
                nextBundle);
        [self setupLocationManagerForBundleId:nextBundle];

        CLLocation *cached = self.locationManager.location;
        if (cached && cached.horizontalAccuracy >= 0 && cached.horizontalAccuracy <= 5000.0) {
            NSTimeInterval age = fabs([cached.timestamp timeIntervalSinceNow]);
            if (age < 900.0) {
                LOC_LOG(@"Candidate %@ has valid recent cached location (acc: %.1fm, age: %.1fs)",
                        nextBundle, cached.horizontalAccuracy, age);
                [self finishWithLocation:cached error:nil];
                return YES;
            }
            if (!self.bestLocation || cached.horizontalAccuracy < self.bestLocation.horizontalAccuracy) {
                self.bestLocation = cached;
            }
        }

        [self.locationManager startUpdatingLocation];
        [self scheduleCandidateStepTimer];
        return YES;
    }
    return NO;
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (locations.count == 0) return;

    for (CLLocation *loc in locations) {
        if (loc.horizontalAccuracy < 0) continue;

        if (!self.bestLocation || loc.horizontalAccuracy < self.bestLocation.horizontalAccuracy) {
            self.bestLocation = loc;
        }

        CLLocationAccuracy threshold = MAX(self.requestedAccuracy, 500.0);
        if (loc.horizontalAccuracy <= threshold) {
            LOC_LOG(@"Location fix acquired: lat=%.6f lon=%.6f acc=%.1fm (bundle: %@)",
                    loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy, self.currentBundleId);
            [self finishWithLocation:loc error:nil];
            return;
        }
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    LOC_LOG(@"Location manager error (bundle: %@): domain=%@ code=%ld desc=%@",
            self.currentBundleId, error.domain, (long)error.code, error.localizedDescription);

    // Code 0 = kCLErrorLocationUnknown: transient unknown state, keep waiting for GPS fix
    if ([error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorLocationUnknown) {
        return;
    }

    // Code 1 = kCLErrorDenied: if not explicitly specified by user, try next candidate bundle
    if (!self.userExplicitBundle && [error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorDenied) {
        if ([self tryNextCandidateBundle]) {
            return;
        }
    }

    if (self.bestLocation && self.bestLocation.horizontalAccuracy >= 0) {
        [self finishWithLocation:self.bestLocation error:nil];
    } else {
        NSString *detail = [NSString stringWithFormat:@"Location error (domain: %@, code: %ld, bundle: '%@'): %@",
                            error.domain, (long)error.code, self.currentBundleId ?: @"unknown", error.localizedDescription];
        [self finishWithLocation:nil error:detail];
    }
}

@end
