#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

#define SRO_CEF_EXPORT __attribute__((visibility("default")))

@protocol SroCefPackProvider <NSObject>

- (BOOL)wantsMethod:(NSString *)method url:(NSString *)url rangeHeader:(nullable NSString *)rangeHeader;
- (void)serveUrl:(NSString *)url
     rangeHeader:(NSString *)rangeHeader
          source:(NSString *)source
      completion:(void (^)(NSData *_Nullable body, NSDictionary<NSString *, NSString *> *_Nullable headers))completion;

@end

SRO_CEF_EXPORT
@interface SroCefApplication : NSApplication

@property(nonatomic, copy, nullable) void (^terminationHandler)(void);

@end

SRO_CEF_EXPORT
@interface SroCefRuntime : NSObject

+ (BOOL)loadFramework;
+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath logFile:(NSString *)logFile ready:(void (^)(void))ready;
+ (void)runMessageLoop;
+ (void)quitMessageLoop;
+ (void)shutdown;
+ (NSString *)cefVersion;
+ (void)setPackProvider:(nullable id<SroCefPackProvider>)provider;

@end

typedef NS_ENUM(NSInteger, SroCefEditCommand) {
  SroCefEditCommandUndo,
  SroCefEditCommandRedo,
  SroCefEditCommandCut,
  SroCefEditCommandCopy,
  SroCefEditCommandPaste,
  SroCefEditCommandSelectAll,
};

@class SroCefBrowser;

@protocol SroCefBrowserDelegate <NSObject>

- (void)cefBrowser:(SroCefBrowser *)browser didReceivePageMessage:(NSString *)json fromMainFrame:(BOOL)mainFrame pageUrl:(NSString *)pageUrl;
- (void)cefBrowser:(SroCefBrowser *)browser didFinishLoadingUrl:(NSString *)url;
- (void)cefBrowser:(SroCefBrowser *)browser didFailLoadingUrl:(NSString *)url description:(NSString *)description;
- (void)cefBrowser:(SroCefBrowser *)browser rendererDidTerminate:(NSString *)reason;
- (void)cefBrowser:(SroCefBrowser *)browser wantsToOpenPopupToUrl:(NSString *)url;
- (void)cefBrowser:(SroCefBrowser *)browser didLogConsoleMessage:(NSString *)message level:(int)level;
- (void)cefBrowser:(SroCefBrowser *)browser didReportScriptError:(NSString *)description;
- (void)cefBrowserDidClose:(SroCefBrowser *)browser;

@end

SRO_CEF_EXPORT
@interface SroCefBrowser : NSObject

@property(nonatomic, weak, nullable) id<SroCefBrowserDelegate> delegate;
@property(nonatomic, readonly) BOOL isClosed;
@property(nonatomic, readonly) int identifier;
@property(nonatomic, readonly, nullable) NSString *currentUrl;
@property(nonatomic, readonly) NSUInteger rejectedMessageCount;
@property(nonatomic, readonly) int rendererProcessId;

- (nullable instancetype)initWithParentView:(NSView *)parentView
                                  cachePath:(NSString *)cachePath
                                        url:(NSString *)url
                                    scripts:(NSArray<NSString *> *)scripts
                              allowEvaluate:(BOOL)allowEvaluate
                                   delegate:(id<SroCefBrowserDelegate>)delegate;

- (void)loadUrl:(NSString *)url;
- (void)reload;
- (void)updateScripts:(NSArray<NSString *> *)scripts;
- (void)sendMessageJson:(NSString *)json;
- (void)evaluate:(NSString *)code completion:(void (^)(BOOL ok, NSString *text))completion;
- (void)captureScreenshot:(void (^)(NSData *_Nullable png))completion;
- (void)perform:(SroCefEditCommand)command;
- (void)setAudioMuted:(BOOL)muted;
- (BOOL)isAudioMuted;
- (void)close;

@end

NS_ASSUME_NONNULL_END
