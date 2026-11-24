#import "ScriptingReplyBridge.h"

BOOL OneAgentResumeScriptCommand(NSScriptCommand *command, id result, NSString *conversionError) {
    @try {
        [command resumeExecutionWithResult:result];
        return YES;
    } @catch (NSException *exception) {
        // An exception escaping a Swift Task poisons its executor context. Cocoa Scripting
        // must receive a failed command rather than unwinding through the async dispatcher.
        command.scriptErrorNumber = -1708;
        command.scriptErrorString = conversionError;
        @try {
            [command resumeExecutionWithResult:nil];
        } @catch (NSException *replyException) {
            NSLog(@"1Agent scripting reply failed (%@)", replyException.name);
        }
        return NO;
    }
}
