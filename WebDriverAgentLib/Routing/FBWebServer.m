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
#import "WebSocketServer.h"

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
#import "FBKeyboard.h"
#import "FBApplication.h"

#import "XCUIApplication+FBTouchAction.h"

#import "XCUIDevice+FBHelpers.h"

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
@property (nonatomic, strong) WebSocketServer *webSocketServer;
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

- (void)startServing
{
  [FBLogger logFmt:@"Built at %s %s", __DATE__, __TIME__];
  self.exceptionHandler = [FBExceptionHandler new];
  [self startWSServer];
  [self startHTTPServer];
  [self initScreenshotsBroadcaster];

  self.keepAlive = YES;
  NSRunLoop *runLoop = [NSRunLoop mainRunLoop];
  while (self.keepAlive &&
         [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
}

//- (void)startWSServer
//{
//    // Initialize and start the WebSocket server
//    self.webSocketServer = [[WebSocketServer alloc] init];
//    self.webSocketServer.delegate = (id<WebSocketServerDelegate>)self; // Cast to the correct delegate type
////    [self.webSocketServer startWebSocketServerOnPort:FBConfiguration.wsServerPort]; // Change the port as needed
//    [self.webSocketServer startWebSocketServerOnPort:(uint16_t)FBConfiguration.wsServerPort];
//}

- (void)startWSServer {
    // Initialize and start the WebSocket server
    self.webSocketServer = [[WebSocketServer alloc] init];
    self.webSocketServer.delegate = (id<WebSocketServerDelegate>)self; // Cast to the correct delegate type

    // Start the server
    [self startServer];
}

- (void)startServer {
    [self.webSocketServer startWebSocketServerOnPort:(uint16_t)FBConfiguration.wsServerPort];
}

- (void)stopServer {
    [self.webSocketServer stopWebSocketServer];
}

- (void)checkServerStatus {
    // Send a ping or health check request to the server
    // Wait for a response within a reasonable timeframe
    // If no response, consider the server as crashed and restart it
    if (![self isServerHealthy]) {
        NSLog(@"Server is not healthy. Restarting...");
        [self restartServer];
    }
}

- (void)restartServer {
    // Stop the current server instance
    [self stopServer];
    
    // Start a new server instance
    [self startServer];
}

- (BOOL)isServerHealthy {
    // Implement your logic to check if the server is healthy
    // For example, send a ping and wait for a response
    // Return YES if the server is healthy, NO otherwise
    return YES; // Placeholder value
}

- (void)didReceiveMessageFromWebSocket:(NSString *)text {
    // Handle the received message from the WebSocket server
//    NSLog(@"Received message from WebSocket server: %@", text);
    
    // Split the received text into individual messages using newline delimiter
    NSArray *messages = [text componentsSeparatedByString:@"\n"];
  
    if ([messages count] == 1 && [text isEqualToString:messages[0]]) {
        NSLog(@"No newline-delimited messages found.");
        return;
    }
    
    for (NSString *message in messages) {
        if ([message length] > 0) {
            [self processReceivedMessage:message];
        }
    }
}

- (void)processReceivedMessage:(NSString *)message {
    // Handle the received message from the WebSocket server
//    NSLog(@"Received message from WebSocket server: %@", text);
  
    // First, parse the outer JSON
    NSData *outerJSONData = [message dataUsingEncoding:NSUTF8StringEncoding];
  
    NSError *outerError = nil;
    NSDictionary *outerJSONDict = [NSJSONSerialization JSONObjectWithData:outerJSONData options:0 error:&outerError];

    if (outerError) {
        NSLog(@"Error parsing outer JSON message: %@", outerError);
        return;
    }

    // Now, parse the inner JSON string within the "data" field
    NSString *dataJSONString = outerJSONDict[@"data"];
    
//    if (dataJSONString) {
        NSData *dataJSONData = [dataJSONString dataUsingEncoding:NSUTF8StringEncoding];
      
        NSError *innerError = nil;
        NSDictionary *dataDict = [NSJSONSerialization JSONObjectWithData:dataJSONData options:0 error:&innerError];
        if (innerError) {
            NSLog(@"Error parsing inner JSON message: %@", innerError);
            return;
        }

        // Now you can access the values from both the outer and inner JSON dictionaries
        NSString *event = outerJSONDict[@"event"];
        NSLog(@"event: %@", event);

        if (event) {
            if ([event isEqualToString:[self clientEvent:(WDA_KEYS)]]) {
                [self keys:dataDict];
            } else if ([event isEqualToString:[self clientEvent:(WDA_TOUCH_PERFORM)]]) {
                [self touchPerform:dataDict];
            } else if ([event isEqualToString:[self clientEvent:WDA_PRESS_BUTTON]]) {
                [self pressButton:dataDict];
            } else {
                NSLog(@"Unknown event: %@", event);
                return;
            }
        } else {
            NSLog(@"Event is nil.");
        }

//    } else {
//        NSLog(@"Inner JSON string is nil.");
//    }
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

- (void)keys:(NSDictionary *)eventData {
    // Check for nil values
    if (!eventData || !eventData[@"value"]) {
        NSLog(@"Invalid eventData or value.");
      return;
    }

    id valueObject = eventData[@"value"];
    if (![valueObject isKindOfClass:[NSArray class]]) {
        NSLog(@"'value' is not an array.");
      return;
    }

    NSArray *valueArray = (NSArray *)valueObject;
    NSString *textToType = [valueArray componentsJoinedByString:@""];
    NSUInteger frequency = [eventData[@"frequency"] unsignedIntegerValue] ?: [FBConfiguration maxTypingFrequency];
    NSError *eventError;

    // Perform the typing action and handle errors
    if (![FBKeyboard typeText:textToType frequency:frequency error:&eventError]) {
        NSLog(@"Error typing text: %@", eventError);
    }
}

- (void)touchPerform:(NSDictionary *)eventData {
    // Check for nil values
    if (!eventData || !eventData[@"actions"] || ![eventData[@"actions"] isKindOfClass:[NSArray class]]) {
        NSLog(@"Invalid eventData or actions.");
      return;
    }

    XCUIApplication *application = FBApplication.fb_activeApplication;
    NSArray *actions = eventData[@"actions"];
    NSError *eventError;

    // Perform the touch actions and handle errors
    if (![application fb_performAppiumTouchActions:actions elementCache:nil error:&eventError]) {
        NSLog(@"Error performing touch actions: %@", eventError);
      return;
    }
}

- (void)pressButton:(NSDictionary *)eventData {
    // Check for nil values
    if (!eventData || !eventData[@"name"]) {
        NSLog(@"Invalid eventData or button name.");
        return;
    }

    id nameObject = eventData[@"name"];
    if (![nameObject isKindOfClass:[NSString class]]) {
        NSLog(@"'name' is not a string.");
        return;
    }

    NSError *eventError;

    // Perform the button press action and handle errors
    if (![XCUIDevice.sharedDevice fb_pressButton:(NSString *)nameObject
                                     forDuration:nil
                                           error:&eventError]) {
        NSLog(@"Error pressing button: %@", eventError);
        return;
    }
    return;
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
  }
}

- (void)stopScreenshotsBroadcaster
{
  if (nil == self.screenshotsBroadcaster) {
    return;
  }

  [self.screenshotsBroadcaster stop];
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
//    [response respondWithString:@"I-AM-ALIVE"];
    NSDictionary *jsonResponse = @{@"message": @"I-AM-ALIVE"};
    NSData *responseData = [NSJSONSerialization dataWithJSONObject:jsonResponse options:0 error:nil];
    [response setHeader:@"Content-Type" value:@"application/json"];
    [response respondWithData:responseData];
  }];

  [self.server get:@"/wda/shutdown" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"Shutting down"];
    [self.delegate webServerDidRequestShutdown:self];
  }];

  [self registerRouteHandlers:@[FBUnknownCommands.class]];
}

@end
