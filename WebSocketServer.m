#import "WebSocketServer.h"
#import <CommonCrypto/CommonDigest.h>

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

    // Send a welcome message to the newly connected client
    NSString *welcomeMessage = @"You are connected WDA WebSocket server!\r\n";
    NSData *welcomeData = [welcomeMessage dataUsingEncoding:NSUTF8StringEncoding];
    [newSocket writeData:welcomeData withTimeout:-1 tag:0];

    // Start reading data from the socket
    [newSocket readDataWithTimeout:-1 tag:0];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    NSLog(@"WebSocket connection from %@ disconnected", [sock connectedHost]);
    [self.connectedClients removeObject:sock];
}

//- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
//    // Convert the raw data to a plain text string using UTF-8 encoding
//    NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
//
//    if (message) {
//        NSLog(@"Received message from WebSocket client: %@", message);
//        // Handle the received plain text message as needed
//    } else {
//        NSLog(@"Received raw data from WebSocket client: %@", data);
//        // Handle the received raw data as needed
//    }
//
//    // Continue reading data from the socket for WebSocket communication
//    [sock readDataWithTimeout:-1 tag:0];
//}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (message) {
        [self.delegate didReceiveMessageFromWebSocket:message];
    }
    
    [sock readDataWithTimeout:-1 tag:0];
}


@end
