/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBWebServer.h"

#import "RoutingConnection.h"
#import "RoutingHTTPServer.h"

#import "FBCommandHandler.h"
#import "FBErrorBuilder.h"
#import "FBExceptionHandler.h"
#import "FBMjpegServer.h"
#import "FBRouteRequest.h"
#import "FBRuntimeUtils.h"
#import "FBSession.h"
#import "FBTCPSocket.h"
#import "FBUnknownCommands.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "BLWebSocketsServer.h"
#import "FBKeyboard.h"
#import "FBApplication.h"

#import "XCUIDevice+FBHelpers.h"
#import "XCUIApplication+FBTouchAction.h"


static NSString *const FBServerURLBeginMarker = @"ServerURLHere->";
static NSString *const FBServerURLEndMarker = @"<-ServerURLHere";

/**
 Enumerates the different client event types for WebDriverAgent.

 - WDA_KEYS: Represents the "keys" event type.
 - WDA_TOUCH_PERFORM: Represents the "touch perform" event type.
 - WDA_PRESS_BUTTON: Represents the "press button" event type.
 */
typedef NS_ENUM(NSUInteger, ClientEvents) {
    WDA_KEYS,
    WDA_TOUCH_PERFORM,
    WDA_PRESS_BUTTON,
};

@interface FBHTTPConnection : RoutingConnection
@end

@implementation FBHTTPConnection

- (void)handleResourceNotFound
{
  [FBLogger logFmt:@"Received request for %@ which we do not handle", self.requestURI];
  [super handleResourceNotFound];
}

@end


@interface FBWebServer ()
@property (nonatomic, strong) FBExceptionHandler *exceptionHandler;
@property (nonatomic, strong) RoutingHTTPServer *server;
@property (atomic, assign) BOOL keepAlive;
@property (nonatomic, nullable) FBTCPSocket *screenshotsBroadcaster;
@end

@implementation FBWebServer

+ (NSArray<Class<FBCommandHandler>> *)collectCommandHandlerClasses
{
  NSArray *handlersClasses = FBClassesThatConformsToProtocol(@protocol(FBCommandHandler));
  NSMutableArray *handlers = [NSMutableArray array];
  for (Class aClass in handlersClasses) {
    if ([aClass respondsToSelector:@selector(shouldRegisterAutomatically)]) {
      if (![aClass shouldRegisterAutomatically]) {
        continue;
      }
    }
    [handlers addObject:aClass];
  }
  return handlers.copy;
}

/**
 Returns the corresponding event name for a given client event type.

 @param whichEvent The client event type.
 @return The event name as a string.
 */
- (NSString *)clientEvent:(ClientEvents)whichEvent {
    NSString *result = nil;
    
    switch (whichEvent) {
        case WDA_KEYS:
            result = @"WDA_KEYS";
            break;
        case WDA_TOUCH_PERFORM:
            result = @"WDA_TOUCH_PERFORM";
            break;
        case WDA_PRESS_BUTTON:
            result = @"WDA_PRESS_BUTTON";
            break;
        default:
            result = @"unknown";
            break;
    }
    
    return result;
}


- (void)startServing
{
  [FBLogger logFmt:@"Built at %s %s", __DATE__, __TIME__];
  self.exceptionHandler = [FBExceptionHandler new];
  [self startHTTPServer];
  [self initScreenshotsBroadcaster];
  [self initWebsocketBroadcasterWithBlWebsocket];

  self.keepAlive = YES;
  NSRunLoop *runLoop = [NSRunLoop mainRunLoop];
  while (self.keepAlive &&
         [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
}

- (void)startHTTPServer
{
  self.server = [[RoutingHTTPServer alloc] init];
  [self.server setRouteQueue:dispatch_get_main_queue()];
  [self.server setDefaultHeader:@"Server" value:@"WebDriverAgent/1.0"];
  [self.server setDefaultHeader:@"Access-Control-Allow-Origin" value:@"*"];
  [self.server setDefaultHeader:@"Access-Control-Allow-Headers" value:@"Content-Type, X-Requested-With"];
  
//  (void)setDefaultHeader:(NSString *)field value:(NSString *)value;
  
  [self.server setConnectionClass:[FBHTTPConnection self]];

  [self registerRouteHandlers:[self.class collectCommandHandlerClasses]];
  [self registerServerKeyRouteHandlers];

  NSRange serverPortRange = FBConfiguration.bindingPortRange;
  NSError *error;
  BOOL serverStarted = NO;

  for (NSUInteger index = 0; index < serverPortRange.length; index++) {
    NSInteger port = serverPortRange.location + index;
    [self.server setPort:(UInt16)port];

    serverStarted = [self attemptToStartServer:self.server onPort:port withError:&error];
    if (serverStarted) {
      break;
    }

    [FBLogger logFmt:@"Failed to start web server on port %ld with error %@", (long)port, [error description]];
  }

  if (!serverStarted) {
    [FBLogger logFmt:@"Last attempt to start web server failed with error %@", [error description]];
    abort();
  }
  [FBLogger logFmt:@"%@http://%@:%d%@", FBServerURLBeginMarker, [XCUIDevice sharedDevice].fb_wifiIPAddress ?: @"localhost", [self.server port], FBServerURLEndMarker];
}

- (void)initScreenshotsBroadcaster
{
  [self readMjpegSettingsFromEnv];
  self.screenshotsBroadcaster = [[FBTCPSocket alloc]
                                 initWithPort:(uint16_t)FBConfiguration.mjpegServerPort];
  self.screenshotsBroadcaster.delegate = [[FBMjpegServer alloc] init];
  NSError *error;
  if (![self.screenshotsBroadcaster startWithError:&error]) {
    [FBLogger logFmt:@"Cannot init screenshots broadcaster service on port %@. Original error: %@", @(FBConfiguration.mjpegServerPort), error.description];
    self.screenshotsBroadcaster = nil;
  } else {
    [FBLogger logFmt:@"init screenshots broadcaster service on port %@.", @(FBConfiguration.mjpegServerPort)];
  }
}

- (void)stopScreenshotsBroadcaster
{
  if (nil == self.screenshotsBroadcaster) {
    return;
  }

  [self.screenshotsBroadcaster stop];
}
/**
 Executes the "wdaKeys" client event.

 @param eventData A dictionary containing event data.
 @return YES if the event was successfully executed, NO otherwise.
 */
- (BOOL)wdaKeys:(NSDictionary *)eventData {
    // Check for nil values
    if (!eventData || !eventData[@"value"]) {
        NSLog(@"Invalid eventData or value.");
        return false;
    }

    id valueObject = eventData[@"value"];
    if (![valueObject isKindOfClass:[NSArray class]]) {
        NSLog(@"'value' is not an array.");
        return false;
    }

    NSArray *valueArray = (NSArray *)valueObject;
    NSString *textToType = [valueArray componentsJoinedByString:@""];
    NSUInteger frequency = [eventData[@"frequency"] unsignedIntegerValue] ?: [FBConfiguration maxTypingFrequency];
    NSError *eventError;

    // Perform the typing action and handle errors
    if (![FBKeyboard typeText:textToType frequency:frequency error:&eventError]) {
        NSLog(@"Error typing text: %@", eventError);
        return false;
    }
    return true;
}

/**
 Executes the "wdaTouchPerform" client event.

 @param eventData A dictionary containing event data.
 @return YES if the event was successfully executed, NO otherwise.
 */
- (BOOL)wdaTouchPerform:(NSDictionary *)eventData {
    // Check for nil values
    if (!eventData || !eventData[@"actions"] || ![eventData[@"actions"] isKindOfClass:[NSArray class]]) {
        NSLog(@"Invalid eventData or actions.");
        return false;
    }

    XCUIApplication *application = FBApplication.fb_activeApplication;
    NSArray *actions = eventData[@"actions"];
    NSError *eventError;

    // Perform the touch actions and handle errors
    if (![application fb_performAppiumTouchActions:actions elementCache:nil error:&eventError]) {
        NSLog(@"Error performing touch actions: %@", eventError);
        return false;
    }
    return true;
}

/**
 Executes the "wdaPressButton" client event.

 @param eventData A dictionary containing event data.
 @return YES if the event was successfully executed, NO otherwise.
 */
- (BOOL)wdaPressButton:(NSDictionary *)eventData {
    // Check for nil values
    if (!eventData || !eventData[@"name"]) {
        NSLog(@"Invalid eventData or button name.");
        return false;
    }

    id nameObject = eventData[@"name"];
    if (![nameObject isKindOfClass:[NSString class]]) {
        NSLog(@"'name' is not a string.");
        return false;
    }

    NSError *eventError;

    // Perform the button press action and handle errors
    if (![XCUIDevice.sharedDevice fb_pressButton:(NSString *)nameObject
                                     forDuration:eventData[@"duration"]
                                           error:&eventError]) {
        NSLog(@"Error pressing button: %@", eventError);
        return false;
    }
    return true;
}

/**
 Initializes the WebSocket broadcaster with BLWebsocket and sets up request handling.
 */
- (void)initWebsocketBroadcasterWithBlWebsocket {
    // Every request made by a client will trigger the execution of this block.
    [[BLWebSocketsServer sharedInstance] setHandleRequestBlock:^NSData *(NSData *data) {
        // Data received
        return runOnMainQueueWithoutDeadlocking(^{
            
            NSError *error = nil;
            BOOL success = NO;
            
            // Step 1: Convert NSData to NSString using ISO Latin-1 encoding
            NSString *strISOLatin = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            
            // Step 2: Convert NSString back to NSData using UTF-8 encoding
            NSData *dataUTF8 = [strISOLatin dataUsingEncoding:NSUTF8StringEncoding];
            
            // Step 3: Deserialize the UTF-8 encoded NSData as JSON to create an NSDictionary
            id dict = [NSJSONSerialization JSONObjectWithData:dataUTF8 options:0 error:&error];
            NSMutableDictionary *mutableDictionary = [dict isKindOfClass:[NSDictionary class]] ? [dict mutableCopy] : nil;
            
            if (error) {
                NSLog(@"JSON Serialization Error: %@", error);
            } else if (mutableDictionary) {
                NSString *event = mutableDictionary[@"event"];
                NSDictionary *eventData = mutableDictionary[@"data"];
                
                if (event && eventData) {
                    if ([event isEqualToString:[self clientEvent:(WDA_KEYS)]]) {
                        success = [self wdaKeys:eventData];
                    } else if ([event isEqualToString:[self clientEvent:(WDA_TOUCH_PERFORM)]]) {
                        success = [self wdaTouchPerform:eventData];
                    } else if ([event isEqualToString:[self clientEvent:WDA_PRESS_BUTTON]]) {
                        success = [self wdaPressButton:eventData];
                    }
                } else {
                    NSLog(@"Event or eventData is nil.");
                }
            } else {
                NSLog(@"Unexpected JSON data structure.");
            }
            
            // Update response status based on success
            NSString *status = success ? @"success" : @"fail";
            [mutableDictionary setValue:status forKey:@"status"];
            
            // Convert the updated dictionary back to NSData
            NSData *responseData = nil;
            if (mutableDictionary) {
                responseData = [NSJSONSerialization dataWithJSONObject:mutableDictionary options:NSJSONWritingPrettyPrinted error:&error];
                if (error) {
                    NSLog(@"JSON Serialization Error: %@", error);
                }
            }
            
            return responseData;
        });
        
    }];
    
    // Start the server
    [[BLWebSocketsServer sharedInstance] startListeningOnPort:9330 withProtocolName:@"BLWebSocketProtocol" andCompletionBlock:^(NSError *error) {
        if (!error) {
            NSLog(@"Server started");
        } else {
            NSLog(@"%@", error);
        }
    }];
    
    // Push a message to every connected client
    [[BLWebSocketsServer sharedInstance] pushToAll:[@"pushed message" dataUsingEncoding:NSUTF8StringEncoding]];
}

/**
 Executes a block on the main queue, ensuring it doesn't deadlock.
 
 This function is designed to execute a block on the main queue, either immediately if the current
 thread is already the main thread, or synchronously if called from a background thread. It helps
 avoid deadlocks that can occur when synchronously dispatching to the main queue from a background thread.
 
 @param block A block that returns an NSData object. This block will be executed on the main queue.
 @return The NSData object returned by the executed block.
 */
NSData *runOnMainQueueWithoutDeadlocking(NSData *(^block)(void))
{
    if ([NSThread isMainThread])
    {
        // If already on the main thread, execute the block immediately
        return block();
    }
    else
    {
        __block NSData *result = nil;
        
        // Synchronously dispatch the block to the main queue
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = block();
        });
        
        return result;
    }
}

- (void)readMjpegSettingsFromEnv
{
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *scalingFactor = [env objectForKey:@"MJPEG_SCALING_FACTOR"];
  if (scalingFactor != nil && [scalingFactor length] > 0) {
    [FBConfiguration setMjpegScalingFactor:[scalingFactor integerValue]];
  }
  NSString *screenshotQuality = [env objectForKey:@"MJPEG_SERVER_SCREENSHOT_QUALITY"];
  if (screenshotQuality != nil && [screenshotQuality length] > 0) {
    [FBConfiguration setMjpegServerScreenshotQuality:[screenshotQuality integerValue]];
  }
}

- (void)stopServing
{
  [FBSession.activeSession kill];
  [self stopScreenshotsBroadcaster];
  if (self.server.isRunning) {
    [self.server stop:NO];
  }
  self.keepAlive = NO;
}

- (BOOL)attemptToStartServer:(RoutingHTTPServer *)server onPort:(NSInteger)port withError:(NSError **)error
{
  server.port = (UInt16)port;
  NSError *innerError = nil;
  BOOL started = [server start:&innerError];
  if (!started) {
    if (!error) {
      return NO;
    }

    NSString *description = @"Unknown Error when Starting server";
    if ([innerError.domain isEqualToString:NSPOSIXErrorDomain] && innerError.code == EADDRINUSE) {
      description = [NSString stringWithFormat:@"Unable to start web server on port %ld", (long)port];
    }
    return
    [[[[FBErrorBuilder builder]
       withDescription:description]
      withInnerError:innerError]
     buildError:error];
  }
  return YES;
}

- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses
{
  for (Class<FBCommandHandler> commandHandler in commandHandlerClasses) {
    NSArray *routes = [commandHandler routes];
    for (FBRoute *route in routes) {
      [self.server handleMethod:route.verb withPath:route.path block:^(RouteRequest *request, RouteResponse *response) {
        NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:request.body options:NSJSONReadingMutableContainers error:NULL];
        FBRouteRequest *routeParams = [FBRouteRequest
          routeRequestWithURL:request.url
          parameters:request.params
          arguments:arguments ?: @{}
        ];

        [FBLogger verboseLog:routeParams.description];

        @try {
          [route mountRequest:routeParams intoResponse:response];
        }
        @catch (NSException *exception) {
          [self handleException:exception forResponse:response];
        }
      }];
    }
  }
}

- (void)handleException:(NSException *)exception forResponse:(RouteResponse *)response
{
  [self.exceptionHandler handleException:exception forResponse:response];
}

- (void)registerServerKeyRouteHandlers
{
  [self.server get:@"/health" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"I-AM-ALIVE"];
  }];

  [self.server get:@"/wda/shutdown" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"Shutting down"];
    [self.delegate webServerDidRequestShutdown:self];
  }];

  [self registerRouteHandlers:@[FBUnknownCommands.class]];
}

@end
