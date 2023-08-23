#import <Foundation/Foundation.h>
#import "GCDAsyncSocket.h"

@protocol WebSocketServerDelegate <NSObject>
- (void)didReceiveMessageFromWebSocket:(NSString *)message;
@end

@interface WebSocketServer : NSObject

@property (nonatomic, weak) id<WebSocketServerDelegate> delegate;

- (instancetype)init;
- (void)startWebSocketServerOnPort:(uint16_t)port;
- (void)stopWebSocketServer;

@end
