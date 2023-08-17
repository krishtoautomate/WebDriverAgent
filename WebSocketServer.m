#import "WebSocketServer.h"

@interface WebSocketServer () <GCDAsyncSocketDelegate>

@property (nonatomic, strong) GCDAsyncSocket *listenSocket;
@property (nonatomic, strong) NSMutableArray<GCDAsyncSocket *> *connectedClients;

@end

@implementation WebSocketServer

- (instancetype)init {
    self = [super init];
    if (self) {
        self.listenSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
        self.connectedClients = [NSMutableArray array];
    }
    return self;
}

- (void)startWebSocketServerOnPort:(uint16_t)port {
    NSError *error = nil;
    if (![self.listenSocket acceptOnPort:port error:&error]) {
        NSLog(@"Error starting WebSocket server: %@", error);
    } else {
        NSLog(@"WebSocket server started on port %hu", [self.listenSocket localPort]);
    }
}

- (void)stopWebSocketServer {
    [self.listenSocket disconnect];
    for (GCDAsyncSocket *clientSocket in self.connectedClients) {
        [clientSocket disconnect];
    }
    [self.connectedClients removeAllObjects];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
    NSLog(@"New WebSocket connection from %@", [newSocket connectedHost]);
    [self.connectedClients addObject:newSocket];
    [newSocket readDataWithTimeout:-1 tag:0]; // Start reading data from the socket
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    NSLog(@"WebSocket connection from %@ disconnected", [sock connectedHost]);
    [self.connectedClients removeObject:sock];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"Received message from WebSocket client: %@", message);
    
    // You can handle incoming WebSocket messages here and send responses back if needed.
    // To send data back to the client, use [sock writeData:data withTimeout:-1 tag:0];
    
    [sock readDataWithTimeout:-1 tag:0]; // Continue reading data from the socket
}

@end
