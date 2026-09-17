// The slice of WebKit's C SPI the harness needs to receive a page's `new Notification` natively.
// Declarations copied from WebKit's Source/WebKit/UIProcess/API/C (WKNotificationProvider.h and
// friends); every symbol was checked against `dyld_info -exports` on macOS 27 beta.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

typedef const struct OpaqueWKType* WKTypeRef;
typedef const struct OpaqueWKPage* WKPageRef;
typedef const struct OpaqueWKContext* WKContextRef;
typedef const struct OpaqueWKNotification* WKNotificationRef;
typedef const struct OpaqueWKNotificationManager* WKNotificationManagerRef;
typedef const struct OpaqueWKSecurityOrigin* WKSecurityOriginRef;
typedef const struct OpaqueWKString* WKStringRef;
typedef const struct OpaqueWKDictionary* WKDictionaryRef;
typedef struct OpaqueWKDictionary* WKMutableDictionaryRef;
typedef const struct OpaqueWKArray* WKArrayRef;
typedef const struct OpaqueWKBoolean* WKBooleanRef;

typedef void (*WKNotificationProviderShowCallback)(WKPageRef page, WKNotificationRef notification, const void* clientInfo);
typedef void (*WKNotificationProviderCancelCallback)(WKNotificationRef notification, const void* clientInfo);
typedef void (*WKNotificationProviderDidDestroyNotificationCallback)(WKNotificationRef notification, const void* clientInfo);
typedef void (*WKNotificationProviderAddNotificationManagerCallback)(WKNotificationManagerRef manager, const void* clientInfo);
typedef void (*WKNotificationProviderRemoveNotificationManagerCallback)(WKNotificationManagerRef manager, const void* clientInfo);
typedef WKDictionaryRef (*WKNotificationProviderNotificationPermissionsCallback)(const void* clientInfo);
typedef void (*WKNotificationProviderClearNotificationsCallback)(WKArrayRef notificationIDs, const void* clientInfo);

typedef struct WKNotificationProviderBase {
    int version;
    const void* clientInfo;
} WKNotificationProviderBase;

typedef struct WKNotificationProviderV0 {
    WKNotificationProviderBase base;
    WKNotificationProviderShowCallback show;
    WKNotificationProviderCancelCallback cancel;
    WKNotificationProviderDidDestroyNotificationCallback didDestroyNotification;
    WKNotificationProviderAddNotificationManagerCallback addNotificationManager;
    WKNotificationProviderRemoveNotificationManagerCallback removeNotificationManager;
    WKNotificationProviderNotificationPermissionsCallback notificationPermissions;
    WKNotificationProviderClearNotificationsCallback clearNotifications;
} WKNotificationProviderV0;

WKContextRef WKPageGetContext(WKPageRef page);
WKNotificationManagerRef WKContextGetNotificationManager(WKContextRef context);
void WKNotificationManagerSetProvider(WKNotificationManagerRef manager, const WKNotificationProviderBase* provider);
void WKNotificationManagerProviderDidShowNotification(WKNotificationManagerRef manager, uint64_t notificationID);
void WKNotificationManagerProviderDidClickNotification(WKNotificationManagerRef manager, uint64_t notificationID);
void WKNotificationManagerProviderDidUpdateNotificationPolicy(WKNotificationManagerRef manager, WKSecurityOriginRef origin, bool allowed);

WKStringRef WKNotificationCopyTitle(WKNotificationRef notification);
WKStringRef WKNotificationCopyBody(WKNotificationRef notification);
WKStringRef WKNotificationCopyTag(WKNotificationRef notification);
WKStringRef WKNotificationCopyIconURL(WKNotificationRef notification);
WKStringRef WKNotificationCopyLang(WKNotificationRef notification);
uint64_t WKNotificationGetID(WKNotificationRef notification);
WKSecurityOriginRef WKNotificationGetSecurityOrigin(WKNotificationRef notification);

WKStringRef WKSecurityOriginCopyToString(WKSecurityOriginRef origin);
WKSecurityOriginRef WKSecurityOriginCreateFromString(WKStringRef string);
WKStringRef WKStringCreateWithCFString(CFStringRef string);
CFStringRef WKStringCopyCFString(CFAllocatorRef allocator, WKStringRef string);
WKMutableDictionaryRef WKMutableDictionaryCreate(void);
bool WKDictionarySetItem(WKMutableDictionaryRef dictionary, WKStringRef key, WKTypeRef item);
WKBooleanRef WKBooleanCreate(bool value);
void WKRelease(WKTypeRef type);
