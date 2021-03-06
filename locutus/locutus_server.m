#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <syslog.h>
#import <UIKit/UIKit.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <dispatch/dispatch.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/param.h>
#include <sys/mount.h>

static NSString *bundle_identifier;
static id existing_icon;

static int tokens[3];

static Class MyIcon;

static id application_controller;
static id icon;
static id icon_controller;
static id icon_model;
// Remove Cancel
// Cancel Retry
// quit   pause
static UIAlertView *alert_view;
static bool dont_hide_alert;
static NSString *display_name, *old_display_key;
static bool is_installing;
static int sock;

static inline NSString *_(NSString *key) {
    NSString *r = [[NSBundle mainBundle] localizedStringForKey:key value:nil table:@"SpringBoard"];
    //NSLog(@"_(%@) = %@", key, r);
    return r;
}

@interface SBIconLabel {
}
-(void)setText:(id)text;
@end

@interface SBDownloadingIcon : NSObject {
}
-(id)initWithLeafIdentifier:(id)leafIdentifier;
-(void)setDisplayedIconImage:(id)image; // new
-(void)remove;
-(void)setDelegate:(id)delegate;
-(void)setDownload:(id)download;
-(void)updateDisplayName;
-(id)darkenedIconImage:(id)image alpha:(float)alpha;
-(void)setShowsCloseBox:(BOOL)showsCloseBox;
-(void)reloadIconImage;
@end

@interface SBIconController {
}
+(id)sharedInstance;
-(void)addNewIconToDesignatedLocation:(id)icon animate:(BOOL)animate scrollToList:(BOOL)list saveIconState:(BOOL)save;
-(void)setIconToReveal:(id)icon;
//-(void)iconUninstall:(id)icon; // also uninstallIcon:, uninstallIcon:animated:; lots of choice!  this works but we want remove above instead
-(void)scrollToIconListContainingIcon:(id)icon animate:(BOOL)animate;
@end

@interface SBApplicationController {
}
+(id)sharedInstance;
#if VERSION >= 0x040300
-(void)loadApplicationsAndIcons:(id)identifier reveal:(BOOL)reveal popIn:(BOOL)popIn reloadAllIcons:(BOOL)reloadAllIcons;
#else
-(void)loadApplicationsAndIcons:(id)identifier reveal:(BOOL)reveal popIn:(BOOL)popIn;
#endif
@end

@interface SBIconModel {
}
+(id)sharedInstance;
-(void)loadAllIcons;
-(void)addIcon:(id)icon;
//-(void)removeIcon:(id)icon;
-(id)applicationIconForDisplayIdentifier:(id)displayIdentifier;
@end

@interface SBPlatformController {
}
+(id)sharedInstance;
-(void)setValue:(id)value forCapability:(id)capability;
@end

@interface SpringBoard : UIApplication {
}
-(void)quitTopApplication:(void *)application;
@end

static void do_alert(NSString *title, NSString *message, NSString *cancel, NSString *retry) {
    [alert_view dismissWithClickedButtonIndex:0 animated:YES]; // shouldn't happen!
    alert_view = [[UIAlertView alloc] initWithTitle:title message:message delegate:icon cancelButtonTitle:cancel otherButtonTitles:retry, nil];
    [alert_view show];
}

static void (^sk)() = ^{
    if(!dont_hide_alert) [alert_view dismissWithClickedButtonIndex:0 animated:YES];
    [alert_view setDelegate:nil];
    [icon remove];
    [icon release];
    icon = nil;
    [icon_controller setIconToReveal:nil];
    close(sock);
    sock = 0;
};

static NSString *MyIcon_displayName(id self, SEL sel) {
    return display_name;
}

static NSString *MyIcon_applicationBundleID(id self, SEL sel) {
    return bundle_identifier;
}

static void MyIcon_launch(id self, SEL sel) {
    write(sock, "p", 1);
}

static BOOL MyIcon_allowsUninstall(id self, SEL sel) {
    return !is_installing;
}

static void MyIcon_closeBoxTapped(id self, SEL sel) {
    // don't download behind the user's back
    write(sock, "p", 1);
    do_alert(_(@"Remove Download"), @"Are you sure you want to remove “Cydia”?", _(@"GAMECENTER_DELETE_STATS_DELETE"), _(@"UNINSTALL_ICON_CANCEL"));
}


static void MyIcon_alertView_clickedButtonAtIndex(id self, SEL sel, UIAlertView *alertView, NSInteger buttonIndex) {
    if(buttonIndex == 0) {
        sk();
    } else {
		NSLog(@"%d", write(sock, "p", 1));
    }
    [alert_view release];
    alert_view = nil;
}

static void set_progress(float progress) {
    id _progress = nil;
    object_getInstanceVariable(icon, "_progressView", (void **) &_progress);
    [_progress setProgress:progress];
}

static void installed() {
    NSLog(@"installed; existing_icon = %@", existing_icon);
    if(existing_icon) {
        [icon remove];
        [icon_controller scrollToIconListContainingIcon:existing_icon animate:YES];
    } else {
#if VERSION >= 0x040300
        [application_controller loadApplicationsAndIcons:@"com.saurik.Cydia" reveal:YES popIn:NO reloadAllIcons:NO];
#else
        [application_controller loadApplicationsAndIcons:@"com.saurik.Cydia" reveal:YES popIn:NO];
#endif
        [[icon_model applicationIconForDisplayIdentifier:@"com.saurik.Cydia"] reloadIconImage];
    }
    [icon release];
    icon = nil;
    sk();
}
    
static void *read_state(void *fp_) {
    FILE *fp = fp_;
    while(1) {
        float progress;
        // in a struct for block's benefit
        struct { char state[128], errs[256]; } s;
        char buf[1024];
        if(!fgets(buf, sizeof(buf), fp) ||
            sscanf(buf, "%128s\t%f\t%256[^\t]", s.state, &progress, s.errs) != 3) {
            dispatch_async(dispatch_get_main_queue(), (dispatch_block_t) sk);
            return NULL;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if(s.state[0] == '`') {
                installed();
                return;
            }
            
            if(icon) {
                set_progress(progress);
            }

            if(s.errs[0] != '`') {
                NSString *err = [NSString stringWithUTF8String:s.errs];
                if(!strcmp(s.state, "INSTALLING_ICON_LABEL")) {
                    do_alert(@"There was a problem installing the jailbreak.", err, _(@"OK"), nil);
                    dont_hide_alert = true;
                    sk();
                } else {
                    do_alert(@"There was a problem downloading the jailbreak files.", err, _(@"DATA_PLAN_FAILED_TRY_LATER"), _(@"DATA_PLAN_FAILED_TRY_AGAIN"));
                }
            }

            NSString *display_key = [NSString stringWithCString:s.state encoding:NSUTF8StringEncoding];

            if([display_key isEqualToString:old_display_key]) return;
            [old_display_key release];
            old_display_key = [display_key retain];
            display_name = _(display_key);
            [icon updateDisplayName];


            if(is_installing = [display_key isEqualToString:@"INSTALLING_ICON_LABEL"]) {
                [icon setShowsCloseBox:NO];
            }
        });
    }
}

static void do_nothing() { }

__attribute__((constructor))
static void init() {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSLog(@"i'm alive");

    [[objc_getClass("SBPlatformController") sharedInstance] setValue:[NSNumber numberWithBool:NO] forCapability:@"hide-non-default-apps"];
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(1021);
    addr.sin_addr.s_addr = htonl(0x7f000001);

    sock = socket(PF_INET, SOCK_STREAM, 0);
    if(sock == -1) return;

    if(connect(sock, (void *) &addr, sizeof(addr))) return;

    FILE *fp = fdopen(sock, "r");
        
    pthread_t thread;
    pthread_create(&thread, NULL, read_state, fp);
    
    application_controller = [objc_getClass("SBApplicationController") sharedInstance];

    icon_model = [objc_getClass("SBIconModel") sharedInstance];
    bundle_identifier = (existing_icon = [icon_model applicationIconForDisplayIdentifier:@"com.saurik.Cydia"]) ? @"com.saurik.Cydia.notreally" : @"com.saurik.Cydia";

    Class SBDownloadingIcon = objc_getClass("SBDownloadingIcon");

    char name[32];
    sprintf(name, "MyIcon_%p", &init);
    MyIcon = objc_allocateClassPair(SBDownloadingIcon, name, 0);
#define OVERRIDE(x) class_replaceMethod(MyIcon, @selector(x), (IMP) MyIcon_##x, "")
    OVERRIDE(displayName);
    OVERRIDE(applicationBundleID);
    OVERRIDE(launch);
    OVERRIDE(allowsUninstall);
    OVERRIDE(closeBoxTapped);
    IMP setDisplayedIconImage = class_getMethodImplementation(SBDownloadingIcon, @selector(setDisplayedIconImage:));
    class_replaceMethod(MyIcon, @selector(setDisplayedIconImage:), (IMP) do_nothing, "");
    class_addMethod(MyIcon, @selector(alertView:clickedButtonAtIndex:), (IMP) MyIcon_alertView_clickedButtonAtIndex, "@:@l");
    objc_registerClassPair(MyIcon);

    icon_controller = [objc_getClass("SBIconController") sharedInstance];
    NSLog(@"icon_controller = %@", icon_controller);

    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"done, MyIcon is now %p", MyIcon);

        [(SpringBoard *) [UIApplication sharedApplication] quitTopApplication:NULL];

        icon = [[MyIcon alloc] initWithLeafIdentifier:bundle_identifier];
        [icon setDelegate:icon_controller];
        display_name = _(@"WAITING_ICON_LABEL");
        [icon_model addIcon:icon];
        [icon_controller addNewIconToDesignatedLocation:icon animate:NO scrollToList:NO saveIconState:YES];
        [icon_controller setIconToReveal:icon];
        
        struct statfs sfs;
        if(!statfs("/private/var", &sfs) && sfs.f_bavail < 20*1024*1024/sfs.f_bsize) {
            do_alert(@"Can't jailbreak.", @"There is not enough free disk space.  Please delete some photos or videos.", _(@"OK"), nil);
            dont_hide_alert = true;
            sk();
            return;
        }

        if(existing_icon) {
            write(sock, "p", 1);
            do_alert(@"Re-jailbreak?", @"Are you sure you want to install the bootstrap package even though a jailbreak is already installed?  It will cause Cydia to forget which packages you have installed.", _(@"UNINSTALL_ICON_CANCEL"), @"Jailbreak");
        }
        
        bool _2x = [[UIScreen mainScreen] scale] > 1.5;
        bool ipad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
        
        NSString *icon_url = _2x ? @"http://www.jailbreakme.com/saffron/_/Cydia@2x.png" : @"http://www.jailbreakme.com/saffron/_/Cydia.png";
        if(ipad) icon_url = @"http://www.jailbreakme.com/saffron/_/Cydia-72.png";
        UIImage *icon_image = [UIImage imageWithData:[NSData dataWithContentsOfURL:[NSURL URLWithString:icon_url]]];
        if(icon_image) {
            icon_image = [icon darkenedIconImage:icon_image alpha:0.5];
            if(_2x) icon_image = [UIImage imageWithCGImage:[icon_image CGImage] scale:2.0 orientation:UIImageOrientationUp];
            ((void (*)(id self, SEL sel, id image)) setDisplayedIconImage)(icon, nil, icon_image);
        }
    });
    
    [pool release];
}

