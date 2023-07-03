#import "FBKeyboard.h"
#import "FBConfiguration.h"
#import "FBXCTestDaemonsProxy.h"
#import "FBErrorBuilder.h"
#import "FBRunLoopSpinner.h"
#import "FBMacros.h"
#import "FBXCodeCompatibility.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBIsVisible.h"
#import "XCTestDriver.h"
#import "FBLogger.h"
#import "FBConfiguration.h"

@implementation FBKeyboard

+ (BOOL)typeText:(NSString *)text error:(NSError **)error
{
    return [self typeText:text frequency:[FBConfiguration maxTypingFrequency] error:error];
}

//+ (BOOL)typeText:(NSString *)text frequency:(NSUInteger)frequency error:(NSError **)error
//{
//    __block BOOL didSucceed = NO;
//    __block NSError *innerError;
//
//    dispatch_semaphore_t typingSemaphore = dispatch_semaphore_create(0);
//
//    [[FBXCTestDaemonsProxy testRunnerProxy]
//     _XCT_sendString:text
//     maximumFrequency:frequency
//     completion:^(NSError *typingError) {
//         didSucceed = (typingError == nil);
//         innerError = typingError;
//         dispatch_semaphore_signal(typingSemaphore);
//     }];
//
//    dispatch_semaphore_wait(typingSemaphore, DISPATCH_TIME_FOREVER);
//
//    if (error) {
//        *error = innerError;
//    }
//
//    return didSucceed;
//}

//+ (BOOL)typeText:(NSString *)text frequency:(NSUInteger)frequency error:(NSError **)error
//{
//    static dispatch_queue_t typingQueue;
//    static NSMutableString *typingQueueText;
//    static dispatch_source_t typingTimer;
//    static BOOL isTyping = NO;
//
//    static dispatch_once_t onceToken;
//    dispatch_once(&onceToken, ^{
//        typingQueue = dispatch_queue_create("com.example.typing", DISPATCH_QUEUE_SERIAL);
//        typingQueueText = [NSMutableString string];
//
//        typingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
//        dispatch_source_set_timer(typingTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
//        dispatch_source_set_event_handler(typingTimer, ^{
//            if ([typingQueueText length] > 0 && !isTyping) {
//                NSString *queuedText = [typingQueueText copy];
//                [typingQueueText setString:@""];
//                [self typeText:queuedText frequency:frequency error:nil];
//            }
//        });
//        dispatch_resume(typingTimer);
//    });
//
//    __block BOOL didSucceed = NO;
//    __block NSError *innerError;
//
//    dispatch_semaphore_t typingSemaphore = dispatch_semaphore_create(0);
//
//    dispatch_async(typingQueue, ^{
//        if (!isTyping) {
//            isTyping = YES;
//
//            [[FBXCTestDaemonsProxy testRunnerProxy]
//             _XCT_sendString:text
//             maximumFrequency:frequency
//             completion:^(NSError *typingError) {
//                 didSucceed = (typingError == nil);
//                 innerError = typingError;
//                 dispatch_semaphore_signal(typingSemaphore);
//                 isTyping = NO;
//             }];
//        } else {
//            dispatch_sync(typingQueue, ^{
//                [typingQueueText appendString:text];
//            });
//            dispatch_semaphore_signal(typingSemaphore);
//        }
//    });
//
//    dispatch_semaphore_wait(typingSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));
//
//    if (didSucceed) {
//        dispatch_sync(typingQueue, ^{
//            [typingQueueText appendString:text];
//        });
//    }
//
//    if (error) {
//        *error = innerError;
//    }
//
//    return didSucceed;
//}


+ (BOOL)typeText:(NSString *)text frequency:(NSUInteger)frequency error:(NSError **)error
{
    static dispatch_queue_t typingQueue;
    static NSMutableString *typingQueueText;
    static dispatch_source_t typingTimer;
    static BOOL isTyping = NO;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        typingQueue = dispatch_queue_create("com.example.typing", DISPATCH_QUEUE_SERIAL);
        typingQueueText = [NSMutableString string];
        
        typingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(typingTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
        dispatch_source_set_event_handler(typingTimer, ^{
            if ([typingQueueText length] > 0 && !isTyping) {
                NSString *queuedText = [typingQueueText copy];
                [typingQueueText setString:@""];
                [self typeText:queuedText frequency:frequency error:nil];
            }
        });
        dispatch_resume(typingTimer);
    });
    
    __block BOOL didSucceed = NO;
    __block NSError *innerError;
    
    dispatch_semaphore_t typingSemaphore = dispatch_semaphore_create(0);
    
    dispatch_async(typingQueue, ^{
        if (!isTyping) {
            isTyping = YES;
            
            NSString *queuedText = [typingQueueText stringByAppendingString:text];
            [typingQueueText setString:@""];
            
            [[FBXCTestDaemonsProxy testRunnerProxy]
             _XCT_sendString:queuedText
             maximumFrequency:frequency
             completion:^(NSError *typingError) {
                 didSucceed = (typingError == nil);
                 innerError = typingError;
                 dispatch_semaphore_signal(typingSemaphore);
                 isTyping = NO;
             }];
        } else {
            dispatch_sync(typingQueue, ^{
                [typingQueueText appendString:text];
            });
            dispatch_semaphore_signal(typingSemaphore);
        }
    });
    
    dispatch_semaphore_wait(typingSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));
    
    if (didSucceed) {
        dispatch_sync(typingQueue, ^{
            if ([typingQueueText length] > 0 && !isTyping) {
                NSString *queuedText = [typingQueueText copy];
                [typingQueueText setString:@""];
                [self typeText:queuedText frequency:frequency error:nil];
            }
        });
    } else {
        [typingQueueText setString:@""];
    }
    
    if (error) {
        *error = innerError;
    }
    
    return didSucceed;
}



+ (BOOL)waitUntilVisibleForApplication:(XCUIApplication *)app timeout:(NSTimeInterval)timeout error:(NSError **)error
{
    BOOL (^isKeyboardVisible)(void) = ^BOOL(void) {
        if (!app.keyboard.exists) {
            return NO;
        }
        
        NSPredicate *keySearchPredicate = [NSPredicate predicateWithBlock:^BOOL(id<FBXCElementSnapshot> snapshot,
                                                                                NSDictionary *bindings) {
            return snapshot.label.length > 0;
        }];
        XCUIElement *firstKey = [[app.keyboard descendantsMatchingType:XCUIElementTypeKey]
                                 matchingPredicate:keySearchPredicate].allElementsBoundByIndex.firstObject;
        return firstKey.exists
        && (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"13.0") ? firstKey.hittable : firstKey.fb_isVisible);
    };
    NSString* errMessage = @"The on-screen keyboard must be present to send keys";
    if (timeout <= 0) {
        if (!isKeyboardVisible()) {
            return [[[FBErrorBuilder builder] withDescription:errMessage] buildError:error];
        }
        return YES;
    }
    return
    [[[[FBRunLoopSpinner new]
       timeout:timeout]
      timeoutErrorMessage:errMessage]
     spinUntilTrue:isKeyboardVisible
     error:error];
}

@end
