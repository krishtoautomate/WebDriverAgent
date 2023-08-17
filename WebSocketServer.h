#import <Foundation/Foundation.h>
#import "GCDAsyncSocket.h"

@interface WebSocketServer : NSObject

- (void)startWebSocketServerOnPort:(uint16_t)port;
- (void)stopWebSocketServer;

@end
