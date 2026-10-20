// Private simulator-only fixture. Calls the actual UN delegate, never selection or routing.
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <notify.h>
@interface FixtureResponse : NSObject
@property(nonatomic,strong) UNNotification *notification;
@property(nonatomic,copy) NSString *actionIdentifier;
@end
@implementation FixtureResponse
@end
static void deliver(void) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    NSString *topic = NSProcessInfo.processInfo.environment[@"NTFY_NAV_TOPIC"] ?: @"zz-nav-118-regression";
    content.userInfo = @{@"id": NSUUID.UUID.UUIDString, @"time": @"1792515000", @"event": @"message", @"topic": topic, @"message": @"Navigation fixture", @"base_url": @"https://ntfy-me.com"};
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
    UNNotification *notification = [NSClassFromString(@"UNNotification") new];
    [notification setValue:request forKey:@"request"];
    FixtureResponse *response = [FixtureResponse new];
    response.notification = notification;
    response.actionIdentifier = UNNotificationDefaultActionIdentifier;
    id<UNUserNotificationCenterDelegate> delegate = UNUserNotificationCenter.currentNotificationCenter.delegate;
    [delegate userNotificationCenter:UNUserNotificationCenter.currentNotificationCenter didReceiveNotificationResponse:(id)response withCompletionHandler:^{ NSLog(@"NAV_FIXTURE_RESPONSE_COMPLETED"); }];
}
__attribute__((constructor)) static void setup(void) {
    int token;
    notify_register_dispatch("ntfy.navigation.fixture.response", &token, dispatch_get_main_queue(), ^(int t){ deliver(); });
    if ([NSProcessInfo.processInfo.environment[@"NTFY_NAV_COLD_RESPONSE"] isEqual:@"1"]) {
        __block id observer;
        observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            dispatch_async(dispatch_get_main_queue(), ^{ deliver(); });
        }];
    }
}
