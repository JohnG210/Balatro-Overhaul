/**
 * Balatro Overhaul for iOS: native import bridge.
 *
 * Copyright (C) 2026 Balatro Overhaul iOS port contributors.
 * GNU GPL-3.0-or-later (same licence as Balatro Overhaul). See LICENSE.
 *
 * This file is #included at the end of LOVE's src/common/ios.mm by
 * scripts/prepare_love.sh, so no Xcode project edit is needed. It adds a
 * Lua module "overhaul_ios" (registered in package.preload by love.cpp):
 *
 *   ios.pick(dest_path)   -> true | false, err   open the Files picker; the
 *                                               chosen file is copied to
 *                                               dest_path (absolute).
 *   ios.poll()            -> state, a, b         state is "idle", "pending",
 *                                               "done" (a = dest path,
 *                                               b = original file name),
 *                                               "cancelled" or "error"
 *                                               (a = message).
 *   ios.reset()                                  back to "idle".
 *   ios.documents()       -> path               the app's Documents folder
 *                                               (shown in Files, because
 *                                               UIFileSharingEnabled and
 *                                               LSSupportsOpeningDocumentsInPlace
 *                                               are set).
 *
 * The picker never sends anything off the device. It only copies the file
 * the user chose (their own Balatro copy) into this app's sandbox.
 **/

#ifdef LOVE_IOS

#include "common/runtime.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

enum OverhaulPickState
{
	OVERHAUL_PICK_IDLE = 0,
	OVERHAUL_PICK_PENDING,
	OVERHAUL_PICK_DONE,
	OVERHAUL_PICK_CANCELLED,
	OVERHAUL_PICK_ERROR,
};

static OverhaulPickState overhaulPickState = OVERHAUL_PICK_IDLE;
static NSString *overhaulPickDest = nil;
static NSString *overhaulPickName = nil;
static NSString *overhaulPickError = nil;

@interface OverhaulPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

static OverhaulPickerDelegate *overhaulPickerDelegate = nil;

static void overhaulFinishError(NSString *msg)
{
	overhaulPickError = [msg copy];
	overhaulPickState = OVERHAUL_PICK_ERROR;
}

static bool overhaulCopy(NSURL *url, NSString *dest, NSString **err)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dir = [dest stringByDeletingLastPathComponent];
	NSError *e = nil;

	if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&e])
	{
		*err = [NSString stringWithFormat:@"cannot create %@: %@", dir, e.localizedDescription];
		return false;
	}

	BOOL isDir = NO;
	if ([fm fileExistsAtPath:url.path isDirectory:&isDir] && isDir)
	{
		*err = @"folder";
		return false;
	}

	[fm removeItemAtPath:dest error:nil];

	__block BOOL ok = NO;
	__block NSError *copyError = nil;
	NSError *coordError = nil;
	NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coord coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordError byAccessor:^(NSURL *readURL) {
		ok = [fm copyItemAtURL:readURL toURL:[NSURL fileURLWithPath:dest] error:&copyError];
	}];

	if (!ok)
	{
		NSError *why = copyError ? copyError : coordError;
		*err = [NSString stringWithFormat:@"copy failed: %@", why ? why.localizedDescription : @"unknown error"];
		return false;
	}

	return true;
}

@implementation OverhaulPickerDelegate

- (void)overhaulTake:(NSURL *)url
{
	if (url == nil)
	{
		overhaulFinishError(@"no file was chosen");
		return;
	}

	BOOL scoped = [url startAccessingSecurityScopedResource];
	NSString *err = nil;
	bool ok = overhaulCopy(url, overhaulPickDest, &err);
	if (scoped)
		[url stopAccessingSecurityScopedResource];

	if (!ok)
	{
		overhaulFinishError(err);
		return;
	}

	overhaulPickName = [url.lastPathComponent copy];
	overhaulPickState = OVERHAUL_PICK_DONE;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	#pragma unused(controller)
	[self overhaulTake:urls.firstObject];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url
{
	#pragma unused(controller)
	[self overhaulTake:url];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
	#pragma unused(controller)
	overhaulPickState = OVERHAUL_PICK_CANCELLED;
}

@end

static UIViewController *overhaulTopViewController()
{
	UIWindow *window = nil;
	for (UIWindow *w in [UIApplication sharedApplication].windows)
	{
		if (w.isKeyWindow)
		{
			window = w;
			break;
		}
	}
	if (window == nil)
		window = [UIApplication sharedApplication].windows.firstObject;

	UIViewController *vc = window.rootViewController;
	while (vc.presentedViewController != nil)
		vc = vc.presentedViewController;
	return vc;
}

static int w_overhaul_pick(lua_State *L)
{
	const char *dest = luaL_checkstring(L, 1);

	if (overhaulPickState == OVERHAUL_PICK_PENDING)
	{
		lua_pushboolean(L, 0);
		lua_pushstring(L, "busy");
		return 2;
	}

	@autoreleasepool
	{
		UIViewController *top = overhaulTopViewController();
		if (top == nil)
		{
			lua_pushboolean(L, 0);
			lua_pushstring(L, "no view controller");
			return 2;
		}

		if (overhaulPickerDelegate == nil)
			overhaulPickerDelegate = [[OverhaulPickerDelegate alloc] init];

		overhaulPickDest = [NSString stringWithUTF8String:dest];
		overhaulPickName = nil;
		overhaulPickError = nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		// Import mode: iOS hands us a private copy of the file. public.item
		// lets the user pick Balatro.exe, Balatro.love or a .zip.
		UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
			initWithDocumentTypes:@[@"public.item", @"public.data", @"public.zip-archive"]
			inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop

		picker.delegate = overhaulPickerDelegate;
		if (@available(iOS 11.0, *))
			picker.allowsMultipleSelection = NO;
		picker.modalPresentationStyle = UIModalPresentationFormSheet;

		overhaulPickState = OVERHAUL_PICK_PENDING;
		[top presentViewController:picker animated:YES completion:nil];
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int w_overhaul_poll(lua_State *L)
{
	switch (overhaulPickState)
	{
	case OVERHAUL_PICK_PENDING:
		lua_pushstring(L, "pending");
		return 1;
	case OVERHAUL_PICK_DONE:
		lua_pushstring(L, "done");
		lua_pushstring(L, overhaulPickDest ? overhaulPickDest.UTF8String : "");
		lua_pushstring(L, overhaulPickName ? overhaulPickName.UTF8String : "");
		return 3;
	case OVERHAUL_PICK_CANCELLED:
		lua_pushstring(L, "cancelled");
		return 1;
	case OVERHAUL_PICK_ERROR:
		lua_pushstring(L, "error");
		lua_pushstring(L, overhaulPickError ? overhaulPickError.UTF8String : "unknown error");
		return 2;
	case OVERHAUL_PICK_IDLE:
	default:
		lua_pushstring(L, "idle");
		return 1;
	}
}

static int w_overhaul_reset(lua_State *L)
{
	#pragma unused(L)
	if (overhaulPickState != OVERHAUL_PICK_PENDING)
		overhaulPickState = OVERHAUL_PICK_IDLE;
	return 0;
}

static int w_overhaul_documents(lua_State *L)
{
	@autoreleasepool
	{
		NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		NSString *path = dirs.firstObject;
		if (path == nil)
			lua_pushnil(L);
		else
			lua_pushstring(L, path.UTF8String);
	}
	return 1;
}

/*
 * Multiplayer TLS tunnel.
 *
 * The Overhaul's multiplayer client (multiplayer/android_ws.lua) speaks
 * WebSocket over plain luasocket. On every platform except Windows it
 * expects a local helper on 127.0.0.1:44380 to add TLS: the Android app runs
 * one in Java, Linux runs linux/tls_tunnel.py. This is the same helper for
 * iOS, with the same protocol:
 *
 *   client -> "host:port\n"   (only port 443 is allowed)
 *   tunnel -> "OK\n"          then raw bytes are piped both ways over TLS
 *          or "ERROR:<why>\n" and the connection is closed.
 *
 * It listens on the loopback address only, so nothing outside the phone can
 * reach it. TLS uses the system trust store with host-name checking.
 */

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <atomic>

static const int OVERHAUL_TUNNEL_PORT = 44380;
static std::atomic<bool> overhaulTunnelStarted(false);

static bool overhaulSendAll(int fd, const uint8_t *buf, size_t len)
{
	while (len > 0)
	{
		ssize_t n = send(fd, buf, len, 0);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return false;
		buf += n;
		len -= (size_t) n;
	}
	return true;
}

static void overhaulReply(int fd, NSString *text)
{
	NSData *d = [[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	overhaulSendAll(fd, (const uint8_t *) d.bytes, d.length);
}

static void overhaulTunnelHandle(int fd)
{
	@autoreleasepool
	{
		int one = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
		struct timeval tv = {10, 0};
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

		// Read the "host:port" line one byte at a time (it is short).
		char line[512];
		size_t used = 0;
		bool gotLine = false;
		while (used < sizeof(line) - 1)
		{
			char c;
			ssize_t n = recv(fd, &c, 1, 0);
			if (n < 0 && errno == EINTR)
				continue;
			if (n <= 0)
				break;
			if (c == '\n') { gotLine = true; break; }
			if (c != '\r')
				line[used++] = c;
		}
		line[used] = 0;
		if (!gotLine)
		{
			overhaulReply(fd, @"ERROR:no target line");
			close(fd);
			return;
		}

		NSString *target = [NSString stringWithUTF8String:line];
		NSRange colon = target ? [target rangeOfString:@":" options:NSBackwardsSearch] : NSMakeRange(NSNotFound, 0);
		NSString *host = colon.location != NSNotFound ? [target substringToIndex:colon.location] : nil;
		NSInteger port = colon.location != NSNotFound ? [[target substringFromIndex:colon.location + 1] integerValue] : 0;
		if (host.length == 0 || port != 443)
		{
			overhaulReply(fd, [NSString stringWithFormat:@"ERROR:target not allowed: %@", target]);
			close(fd);
			return;
		}

		NSInputStream *in = nil;
		NSOutputStream *out = nil;
		[NSStream getStreamsToHostWithName:host port:port inputStream:&in outputStream:&out];
		if (in == nil || out == nil)
		{
			overhaulReply(fd, @"ERROR:could not create streams");
			close(fd);
			return;
		}
		[in setProperty:NSStreamSocketSecurityLevelNegotiatedSSL forKey:NSStreamSocketSecurityLevelKey];
		[out setProperty:NSStreamSocketSecurityLevelNegotiatedSSL forKey:NSStreamSocketSecurityLevelKey];
		[in open];
		[out open];

		// Wait (up to 15 s) for both streams to open.
		for (int i = 0; i < 150; i++)
		{
			NSStreamStatus a = in.streamStatus, b = out.streamStatus;
			if (a == NSStreamStatusError || b == NSStreamStatusError)
				break;
			if (a >= NSStreamStatusOpen && b >= NSStreamStatusOpen)
				break;
			usleep(100000);
		}
		if (in.streamStatus != NSStreamStatusOpen || out.streamStatus != NSStreamStatusOpen)
		{
			NSError *err = in.streamError ?: out.streamError;
			overhaulReply(fd, [NSString stringWithFormat:@"ERROR:connect failed: %@",
				err ? err.localizedDescription : @"timeout"]);
			[in close];
			[out close];
			close(fd);
			return;
		}

		struct timeval none = {0, 0};
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof(none));
		overhaulReply(fd, @"OK");

		// Server -> client on a second thread; client -> server here.
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			uint8_t buf[16384];
			while (true)
			{
				NSInteger n = [in read:buf maxLength:sizeof(buf)];
				if (n <= 0 || !overhaulSendAll(fd, buf, (size_t) n))
					break;
			}
			shutdown(fd, SHUT_RDWR);
			dispatch_semaphore_signal(done);
		});

		uint8_t buf[16384];
		while (true)
		{
			ssize_t n = recv(fd, buf, sizeof(buf), 0);
			if (n < 0 && errno == EINTR)
				continue;
			if (n <= 0)
				break;
			ssize_t off = 0;
			bool ok = true;
			while (off < n)
			{
				NSInteger w = [out write:buf + off maxLength:(NSUInteger) (n - off)];
				if (w <= 0) { ok = false; break; }
				off += w;
			}
			if (!ok)
				break;
		}

		[out close];
		[in close];
		shutdown(fd, SHUT_RDWR);
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
		close(fd);
	}
}

static int overhaulTunnelListen()
{
	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0)
		return -1;
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
	struct sockaddr_in addr = {};
	addr.sin_len = sizeof(addr);
	addr.sin_family = AF_INET;
	addr.sin_port = htons(OVERHAUL_TUNNEL_PORT);
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(s, (struct sockaddr *) &addr, sizeof(addr)) != 0 || listen(s, 8) != 0)
	{
		close(s);
		return -1;
	}
	return s;
}

static void overhaulTunnelStart()
{
	bool expected = false;
	if (!overhaulTunnelStarted.compare_exchange_strong(expected, true))
		return;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		while (true)
		{
			int s = overhaulTunnelListen();
			if (s < 0)
			{
				sleep(1);
				continue;
			}
			while (true)
			{
				int c = accept(s, nullptr, nullptr);
				if (c < 0)
				{
					if (errno == EINTR || errno == ECONNABORTED)
						continue;
					break; // iOS can reclaim the socket after suspension; re-listen.
				}
				dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
					overhaulTunnelHandle(c);
				});
			}
			close(s);
			sleep(1);
		}
	});
}

static int w_overhaul_tunnel_start(lua_State *L)
{
	overhaulTunnelStart();
	lua_pushinteger(L, OVERHAUL_TUNNEL_PORT);
	return 1;
}

/*
 * Haptics. The Overhaul only drives haptics on Android (love.system.vibrate
 * with a duration). iOS can't buzz for a duration, so map the game's four
 * haptic levels to Taptic Engine impacts instead:
 *   ios.haptic(level 1..4, intensity 0..1)
 */
static void overhaulHapticNow(int level, double intensity)
{
	static UIImpactFeedbackGenerator *gens[4];
	static const UIImpactFeedbackStyle styles[4] = {
		UIImpactFeedbackStyleLight, UIImpactFeedbackStyleMedium,
		UIImpactFeedbackStyleHeavy, UIImpactFeedbackStyleRigid,
	};
	int i = level < 1 ? 0 : (level > 4 ? 3 : level - 1);
	if (gens[i] == nil)
		gens[i] = [[UIImpactFeedbackGenerator alloc] initWithStyle:styles[i]];
	CGFloat v = (CGFloat) (intensity < 0 ? 0 : (intensity > 1 ? 1 : intensity));
	[gens[i] impactOccurredWithIntensity:v];
	[gens[i] prepare];
}

static int w_overhaul_haptic(lua_State *L)
{
	int level = (int) luaL_optinteger(L, 1, 1);
	double intensity = luaL_optnumber(L, 2, 0.5);
	if (intensity <= 0)
		return 0;
	if ([NSThread isMainThread])
		overhaulHapticNow(level, intensity);
	else
		dispatch_async(dispatch_get_main_queue(), ^{ overhaulHapticNow(level, intensity); });
	return 0;
}

/**
 * UIScene lifecycle bridge.
 *
 * Apps built with the iOS 27 SDK must use the UIScene lifecycle or they are
 * not launched. SDL2 (used by LOVE 11.5) only knows the old app-delegate
 * lifecycle: it creates UIWindows with -initWithFrame: and listens for
 * applicationWillResignActive: etc. on its app delegate. This bridge:
 *   - declares a single window scene (Info.plist UIApplicationSceneManifest
 *     names OverhaulSceneDelegate),
 *   - attaches every UIWindow to that scene (windows made before the scene
 *     connects are attached when it does),
 *   - forwards scene foreground/background events to SDL's app delegate, so
 *     audio and GL rendering still pause in the background,
 *   - forwards opened URLs to the app delegate.
 * The scene's size follows the display, so folding or unfolding an iPhone
 * Duo resizes the SDL window and LOVE calls love.resize.
 */
#import <objc/runtime.h>
#include <SDL_hints.h>
#import <objc/message.h>

static NSHashTable *overhaulEarlyWindows = nil;
static __weak UIWindowScene *overhaulScene = nil;
static IMP overhaulOrigWindowInit = NULL;

static void overhaulAttachWindow(UIWindow *w, UIWindowScene *scene) API_AVAILABLE(ios(13.0))
{
	if (w.windowScene != scene)
		w.windowScene = scene;
	w.frame = scene.coordinateSpace.bounds;
}

static id overhaulWindowInitWithFrame(id self, SEL cmd, CGRect frame)
{
	id w = ((id (*)(id, SEL, CGRect)) overhaulOrigWindowInit)(self, cmd, frame);
	if (w == nil || ![w isKindOfClass:[UIWindow class]])
		return w;
	if (@available(iOS 13.0, *))
	{
		UIWindowScene *scene = overhaulScene;
		if (scene != nil)
			overhaulAttachWindow((UIWindow *) w, scene);
		else
		{
			if (overhaulEarlyWindows == nil)
				overhaulEarlyWindows = [NSHashTable weakObjectsHashTable];
			[overhaulEarlyWindows addObject:w];
		}
	}
	return w;
}

static IMP overhaulOrigMakeKey = NULL;

// With scenes, iOS picks the interface orientation when the scene connects,
// usually from the launch window. SDL's game window arrives later with its
// own (landscape) orientation mask, so ask iOS to re-read it.
static void overhaulRefreshOrientation(UIWindow *w)
{
	if (@available(iOS 16.0, *))
	{
		UIViewController *vc = w.rootViewController;
		UIWindowScene *scene = w.windowScene;
		if (vc == nil || scene == nil)
			return;
		[vc setNeedsUpdateOfSupportedInterfaceOrientations];
		UIInterfaceOrientationMask mask = vc.supportedInterfaceOrientations;
		UIWindowSceneGeometryPreferencesIOS *prefs =
			[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
		[scene requestGeometryUpdateWithPreferences:prefs errorHandler:nil];
	}
}

static void overhaulWindowMakeKeyAndVisible(id self, SEL cmd)
{
	((void (*)(id, SEL)) overhaulOrigMakeKey)(self, cmd);
	UIWindow *w = (UIWindow *) self;
	dispatch_async(dispatch_get_main_queue(), ^{ overhaulRefreshOrientation(w); });
}

__attribute__((constructor)) static void overhaulInstallWindowHook()
{
	// Let the game rotate freely (SDL otherwise locks to the aspect of the
	// window size it was first given).
	SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight Portrait PortraitUpsideDown");
	if (@available(iOS 13.0, *))
	{
		NSDictionary *manifest = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIApplicationSceneManifest"];
		if (manifest == nil)
			return;
		Class cls = [UIWindow class];
		SEL sel = @selector(initWithFrame:);
		Method m = class_getInstanceMethod(cls, sel);
		overhaulOrigWindowInit = method_getImplementation(m);
		// UIWindow may inherit -initWithFrame: from UIView: add an override on
		// UIWindow instead of replacing UIView's (which every view uses).
		if (!class_addMethod(cls, sel, (IMP) overhaulWindowInitWithFrame, method_getTypeEncoding(m)))
			method_setImplementation(m, (IMP) overhaulWindowInitWithFrame);

		SEL mk = @selector(makeKeyAndVisible);
		Method mm = class_getInstanceMethod(cls, mk);
		overhaulOrigMakeKey = method_getImplementation(mm);
		if (!class_addMethod(cls, mk, (IMP) overhaulWindowMakeKeyAndVisible, method_getTypeEncoding(mm)))
			method_setImplementation(mm, (IMP) overhaulWindowMakeKeyAndVisible);
	}
}

/* Keep SDL's idea of the window size in step with the real view size. On a
 * fold/unfold, rotation or a LOVE setMode, SDL can be left with a stale or
 * swapped size (it reads UIScreen sizes, which are per display and can be
 * out of date under scenes). Re-send the real size as a resize event. */
extern "C" int SDL_SendWindowEvent(SDL_Window *window, Uint8 windowevent, int data1, int data2);

static UIView *overhaulSDLView(SDL_Window **out)
{
	SDL_Window *sw = SDL_GL_GetCurrentWindow();
	if (out) *out = sw;
	if (sw == nullptr)
		return nil;
	SDL_SysWMinfo info;
	SDL_VERSION(&info.version);
	if (!SDL_GetWindowWMInfo(sw, &info) || info.info.uikit.window == nil)
		return nil;
	return info.info.uikit.window.rootViewController.view;
}

// Returns true if the GL drawable had to be rebuilt.
static bool overhaulSyncSDLSize(bool force = false)
{
	SDL_Window *sw = nullptr;
	UIView *v = overhaulSDLView(&sw);
	if (v == nil)
		return false;
	// Under the scene lifecycle UIKit rotates/resizes the window but can
	// leave SDL's root view at the old size (portrait view in a landscape
	// window), so the game only covers part of the screen. Make the view
	// fill its window again.
	UIWindow *win = v.window;
	bool reframed = false;
	if (win != nil && !CGSizeEqualToSize(v.bounds.size, win.bounds.size))
	{
		reframed = true;
		NSLog(@"overhaul: view %@ -> window %@", NSStringFromCGRect(v.bounds), NSStringFromCGRect(win.bounds));
		// bounds/center, not frame: frame is undefined under a transform.
		v.bounds = CGRectMake(0, 0, win.bounds.size.width, win.bounds.size.height);
		v.center = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds));
		[v setNeedsLayout];
		[v layoutIfNeeded];
	}
	CGSize s = v.bounds.size;
	CGFloat scale = v.contentScaleFactor;
	int dw = 0, dh = 0, w = 0, h = 0;
	SDL_GL_GetDrawableSize(sw, &dw, &dh);
	SDL_GetWindowSize(sw, &w, &h);
	int ew = (int) lround(s.width * scale), eh = (int) lround(s.height * scale);
	bool stale = force || reframed || abs(dw - ew) > 2 || abs(dh - eh) > 2 || abs(w - (int) s.width) > 1 || abs(h - (int) s.height) > 1;
	if (!stale)
		return false;
	NSLog(@"overhaul: sync view %.0fx%.0f@%.0f drawable %dx%d sdl %dx%d", s.width, s.height, scale, dw, dh, w, h);
	// SDL's GL view rebuilds its renderbuffer in -layoutSubviews when the
	// size changed; a rotation/fold can finish after that ran mid-animation.
	[v setNeedsLayout];
	[v layoutIfNeeded];
	// RESIZED is dropped when SDL already has this size, but LOVE may still
	// hold the old one; SIZE_CHANGED always reaches LOVE (Window::onSizeChanged).
	SDL_SendWindowEvent(sw, SDL_WINDOWEVENT_RESIZED, (int) s.width, (int) s.height);
	SDL_SendWindowEvent(sw, SDL_WINDOWEVENT_SIZE_CHANGED, (int) s.width, (int) s.height);
	return true;
}

static int w_overhaul_view_size(lua_State *L)
{
	UIView *v = overhaulSDLView(nullptr);
	if (v == nil)
		return 0;
	lua_pushnumber(L, v.bounds.size.width);
	lua_pushnumber(L, v.bounds.size.height);
	return 2;
}

static int w_overhaul_sync_size(lua_State *L)
{
	lua_pushboolean(L, overhaulSyncSDLSize(lua_toboolean(L, 1)));
	return 1;
}

API_AVAILABLE(ios(13.0))
@interface OverhaulSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation OverhaulSceneDelegate

- (void)forward:(SEL)sel
{
	UIApplication *app = [UIApplication sharedApplication];
	id<UIApplicationDelegate> d = app.delegate;
	if ([d respondsToSelector:sel])
		((void (*)(id, SEL, id)) objc_msgSend)(d, sel, app);
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
	if (![scene isKindOfClass:[UIWindowScene class]])
		return;
	UIWindowScene *ws = (UIWindowScene *) scene;
	overhaulScene = ws;

	UIWindow *key = nil;
	for (UIWindow *w in overhaulEarlyWindows.allObjects)
	{
		overhaulAttachWindow(w, ws);
		if (!w.hidden && (key == nil || [NSStringFromClass([w class]) hasPrefix:@"SDL"]))
			key = w;
	}
	overhaulEarlyWindows = nil;
	if (key != nil)
		[key makeKeyAndVisible];
	self.window = key;

	if (options.URLContexts.count > 0)
		[self scene:scene openURLContexts:options.URLContexts];
}

- (void)windowScene:(UIWindowScene *)ws didUpdateCoordinateSpace:(id<UICoordinateSpace>)prev
	interfaceOrientation:(UIInterfaceOrientation)o traitCollection:(UITraitCollection *)t
{
	// Fold/unfold or rotation. Don't touch window frames here: UIKit is
	// mid-animation and windows carry a rotation transform, so setting a
	// frame freezes them part-rotated. Fix SDL's view once it settles.
	for (double delay : {0.05, 0.35, 0.8})
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay * NSEC_PER_SEC)),
			dispatch_get_main_queue(), ^{ overhaulSyncSDLSize(); });
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts
{
	UIApplication *app = [UIApplication sharedApplication];
	id<UIApplicationDelegate> d = app.delegate;
	if (![d respondsToSelector:@selector(application:openURL:options:)])
		return;
	for (UIOpenURLContext *c in contexts)
		[d application:app openURL:c.URL options:@{}];
}

- (void)sceneWillResignActive:(UIScene *)scene      { [self forward:@selector(applicationWillResignActive:)]; }
- (void)sceneDidEnterBackground:(UIScene *)scene    { [self forward:@selector(applicationDidEnterBackground:)]; }
- (void)sceneWillEnterForeground:(UIScene *)scene   { [self forward:@selector(applicationWillEnterForeground:)]; }
- (void)sceneDidBecomeActive:(UIScene *)scene       { [self forward:@selector(applicationDidBecomeActive:)]; }

@end

extern "C" int luaopen_overhaul_ios(lua_State *L)
{
	static const luaL_Reg functions[] =
	{
		{ "haptic", w_overhaul_haptic },
		{ "pick", w_overhaul_pick },
		{ "poll", w_overhaul_poll },
		{ "reset", w_overhaul_reset },
		{ "documents", w_overhaul_documents },
		{ "tunnel_start", w_overhaul_tunnel_start },
		{ "view_size", w_overhaul_view_size },
		{ "sync_size", w_overhaul_sync_size },
		{ 0, 0 }
	};

	lua_newtable(L);
	for (const luaL_Reg *f = functions; f->name != nullptr; f++)
	{
		lua_pushcfunction(L, f->func);
		lua_setfield(L, -2, f->name);
	}
	return 1;
}

#endif // LOVE_IOS
