#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QEMUBridge : NSObject

+ (BOOL)startWithLibraryURL:(NSURL *)libraryURL
                  arguments:(NSArray<NSString *> *)arguments
                      error:(NSError **)error;

+ (BOOL)sendCommand:(NSDictionary<NSString *, id> *)command
           toSocket:(NSString *)socketPath
           response:(NSDictionary<NSString *, id> * _Nullable * _Nullable)response
              error:(NSError **)error;

+ (BOOL)isRunning;

@end

NS_ASSUME_NONNULL_END