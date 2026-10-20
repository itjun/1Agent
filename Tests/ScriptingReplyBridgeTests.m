#import "ScriptingReplyBridge.h"

@interface ReplyCommandFixture : NSScriptCommand
@property BOOL rejectResult;
@property NSUInteger replyCount;
@property id received;
@end
@implementation ReplyCommandFixture
- (void)resumeExecutionWithResult:(id)result {
    self.replyCount += 1;
    if (self.rejectResult && result != nil) {
        [NSException raise:NSInternalInconsistencyException format:@"Reply descriptor conversion failed"];
    }
    self.received = result;
}
@end

int main(void) {
    @autoreleasepool {
        ReplyCommandFixture *normal = [ReplyCommandFixture new];
        if (!OneAgentResumeScriptCommand(normal, @YES, @"conversion failed") || normal.replyCount != 1 || ![normal.received isEqual:@YES]) return 1;
        ReplyCommandFixture *invalid = [ReplyCommandFixture new];
        invalid.rejectResult = YES;
        @try {
            if (OneAgentResumeScriptCommand(invalid, @"invalid result", @"conversion failed")) return 1;
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: reply conversion exception escaped the Objective-C boundary\n");
            return 1;
        }
        if (invalid.replyCount != 2 || invalid.received != nil || invalid.scriptErrorNumber != -1708 || ![invalid.scriptErrorString isEqual:@"conversion failed"]) return 1;
        puts("ScriptingReplyBridgeTests passed: successful reply and conversion exception isolation");
    }
    return 0;
}
