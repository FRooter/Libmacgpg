#import <Cocoa/Cocoa.h>
#import "LPXTTask.h"

@class GPGTask;

@protocol GPGTaskDelegate
@optional
//Should return NSData or NSString, it is passed to GPG.
- (id)gpgTask:(GPGTask *)gpgTask statusCode:(NSInteger)status prompt:(NSString *)prompt;


- (void)gpgTaskWillStart:(GPGTask *)gpgTask;
- (void)gpgTaskDidTerminate:(GPGTask *)gpgTask;


@end


@interface GPGTask : NSObject {
	NSString *gpgPath;
	NSMutableArray *arguments;
	BOOL batchMode;
	NSObject <GPGTaskDelegate> *delegate;
	NSDictionary *userInfo;
	NSInteger exitcode;
	int errorCode;
	BOOL getAttributeData;
	
    LPXTTask *gpgTask;
    
	NSMutableArray *inDatas;
	
	NSData *outData;
	NSData *errData;
	NSData *statusData;
	NSData *attributeData;
	
	NSString *outText;
	NSString *errText;
	NSString *statusText;
	NSPipe *cmdPipe;
    
	NSDictionary *lastUserIDHint;
	NSDictionary *lastNeedPassphrase;
	
	char passphraseStatus;
	
	pid_t childPID;
	BOOL cancelled;
	BOOL isRunning;
    BOOL verbose;
}

@property (readonly) BOOL cancelled;
@property (readonly) BOOL isRunning;
@property BOOL batchMode;
@property BOOL getAttributeData;
@property (assign) NSObject <GPGTaskDelegate> *delegate;
@property (retain) NSDictionary *userInfo;
@property (readonly) NSInteger exitcode;
@property (readonly) int errorCode;
@property (retain) NSString *gpgPath;
@property (readonly) NSData *outData;
@property (readonly) NSData *errData;
@property (readonly) NSData *statusData;
@property (readonly) NSData *attributeData;
@property (readonly) NSString *outText;
@property (readonly) NSString *errText;
@property (readonly) NSString *statusText;
@property (readonly) NSArray *arguments;
@property (retain) NSDictionary *lastUserIDHint;
@property (retain) NSDictionary *lastNeedPassphrase;
@property (readonly) LPXTTask *gpgTask;
@property (assign) BOOL verbose;


+ (NSString *)gpgAgentSocket;
+ (NSString *)pinentryPath;
+ (NSString *)findExecutableWithName:(NSString *)executable;
+ (NSString *)findExecutableWithName:(NSString *)executable atPaths:(NSArray *)paths;
+ (NSString *)nameOfStatusCode:(NSInteger)statusCode;

- (void)addArgument:(NSString *)argument;
- (void)addArguments:(NSArray *)args;

- (NSInteger)start;

- (void)cancel;


- (void)addInData:(NSData *)data;
- (void)addInText:(NSString *)string;



+ (id)gpgTaskWithArguments:(NSArray *)args batchMode:(BOOL)batch;
+ (id)gpgTaskWithArguments:(NSArray *)args;
+ (id)gpgTaskWithArgument:(NSString *)arg;
+ (id)gpgTask;


- (id)initWithArguments:(NSArray *)args batchMode:(BOOL)batch;
- (id)initWithArguments:(NSArray *)args;
- (id)initWithArgument:(NSString *)arg;

- (void)processStatusLine:(NSString *)line;
- (void)logDataContent:(NSData *)data message:(NSString *)message;

@end
