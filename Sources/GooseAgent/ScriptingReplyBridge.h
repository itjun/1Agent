#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Cocoa Scripting may throw while converting a reply. Keep that exception in Objective-C.
FOUNDATION_EXPORT BOOL OneAgentResumeScriptCommand(NSScriptCommand *command, id _Nullable result, NSString *conversionError);
NS_ASSUME_NONNULL_END
