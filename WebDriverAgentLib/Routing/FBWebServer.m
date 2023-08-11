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

- (NSString*) clientEvent:(ClientEvents) whichEvent {
    NSString *result = nil;
    switch(whichEvent) {
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

- (BOOL)wdaKeys:(NSData *)data event:(NSString *)event eventData:(NSDictionary *)eventData {
  NSString *textToType = [eventData[@"value"] componentsJoinedByString:@""];
  NSUInteger frequency = [eventData[@"frequency"] unsignedIntegerValue] ?: [FBConfiguration maxTypingFrequency];
  NSError *eventError;
  if (![FBKeyboard typeText:textToType frequency:frequency error:&eventError]) {
    return false;
  }
  return true;
}

- (BOOL)wdaTouchPerform:(NSData *)data eventData:(NSDictionary *)eventData {
  XCUIApplication *application =  FBApplication.fb_activeApplication;
  NSArray *actions = (NSArray *)eventData[@"actions"];
  NSError *eventError;
  if (![application fb_performAppiumTouchActions:actions elementCache:nil error:&eventError]) {
    return false;
  }
  return true;
}

- (BOOL)wdaPressButton:(NSData *)data eventData:(NSDictionary *)eventData {
  NSError *eventError;
  if (![XCUIDevice.sharedDevice fb_pressButton:(id)eventData[@"name"]
                                   forDuration:(NSNumber *)eventData[@"duration"]
                                         error:&eventError]) {
    return false;
  }
  return true;
}

- (void)initWebsocketBroadcasterWithBlWebsocket
{
  //every request made by a client will trigger the execution of this block.
  [[BLWebSocketsServer sharedInstance] setHandleRequestBlock:^NSData *(NSData *data) {
    //data received
    NSError* error = nil;
    BOOL success = false;
    NSString *strISOLatin = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSData *dataUTF8 = [strISOLatin dataUsingEncoding:NSUTF8StringEncoding];
    id dict = [NSJSONSerialization JSONObjectWithData:dataUTF8 options:0 error:&error];
    NSMutableDictionary *mutableDictionary = [dict mutableCopy];
    
    if (dict != nil) {
      NSString *event = dict[@"event"];
      NSDictionary *eventData = dict[@"data"];
      if ([event isEqualToString: [self clientEvent:(WDA_KEYS)]]) {
        success = [self wdaKeys:data event:event eventData:eventData];
      } else if ([event isEqualToString: [self clientEvent:(WDA_TOUCH_PERFORM)]]) {
        success = [self wdaTouchPerform:data eventData:eventData];
      } else if ([event isEqualToString: [self clientEvent:WDA_PRESS_BUTTON]]) {
        success = [self wdaPressButton:data eventData:eventData];
      }
    }
    
    if (success) {
      [mutableDictionary setValue:@"success" forKey:@"status"];
    } else {
      [mutableDictionary setValue:@"fail" forKey:@"status"];
    }
    NSData *responseData = [NSKeyedArchiver archivedDataWithRootObject:mutableDictionary];
    return data;
  }];
  //Start the server
  [[BLWebSocketsServer sharedInstance] startListeningOnPort:9330 withProtocolName:@"my-protocol-name" andCompletionBlock:^(NSError *error) {
      if (!error) {
          NSLog(@"Server started");
      }
      else {
          NSLog(@"%@", error);
      }
  }];
  //Push a message to every connected clients
  [[BLWebSocketsServer sharedInstance] pushToAll:[@"pushed message" dataUsingEncoding:NSUTF8StringEncoding]];
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
