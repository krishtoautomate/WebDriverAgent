const net = require('net');

const serverAddress = '127.0.0.1'; // Replace with the server's IP address
const serverPort = 2100;

const client = net.connect({ port: serverPort, serverAddress: serverAddress }, () => {
    console.log('Connected to WebSocket server');

    setInterval(() => {
      client.write("{\"event\":\"WDA_TOUCH_PERFORM\", \"data\":\"{\\\"actions\\\":[{ \\\"action\\\": \\\"press\\\", \\\"options\\\": { \\\"x\\\": 200, \\\"y\\\": 200 } }, \
      { \\\"action\\\": \\\"wait\\\", \\\"options\\\": { \\\"ms\\\": 500 } }, \
      { \\\"action\\\": \\\"moveTo\\\", \\\"options\\\": { \\\"x\\\": 200, \\\"y\\\": 500 } }, \
      { \\\"action\\\": \\\"release\\\", \\\"options\\\": {} }]}\"}\n");
      console.log('Sent event :', "WDA_TOUCH_PERFORM");
    }, 1000);

    setInterval(() => {
      client.write("{\"event\":\"WDA_KEYS\", \"data\":\"{\\\"value\\\":[\\\"hi\\\"],\\\"frequency\\\":60}\"}\n");

      console.log('Sent event :', "WDA_KEYS");
    }, 500);

    // setInterval(() => {
    //   client.write("{\"event\":\"WDA_TOUCH_PERFORM\", \"data\":\"{\\\"actions\\\":[{\\\"action\\\":\\\"tap\\\",\\\"options\\\":{\\\"x\\\":146,\\\"y\\\":500,\\\"duration\\\":1}}]}\"}\n");
    //   console.log('Sent message:', "WDA_TOUCH_PERFORM");
    // }, 2000);

    setInterval(() => {
    //   // client.write("{\"event\":\"WDA_PRESS_BUTTON\", \"data\":\"{\\\"name\\\":\\\"home\\\"}\"}");

      client.write(`{"event":"WDA_PRESS_BUTTON", "data":"{\\\"name\\\":\\\"home\\\"}"}\n`);

    }, 2000);

    //   const appiumWdaPressButtonPayload = {
    //     event: 'WDA_PRESS_BUTTON',
    //     data: {
    //         name: 'home',
    //     },
    //     // eventId,
    // };
    // client.write(appiumWdaPressButtonPayload);



  //   var payload = {
  //     name: 'Home'
  // }

    // client.write(`{"event":"WDA_PRESS_BUTTON", "data":"${payload}"}\n`);

      // console.log('Sent event :', "WDA_PRESS_BUTTON");
    // }, 2000);

    // client.destroy();
    // Close the connection
    // client.end();
});

// Handle when the client receives data from the server
client.on('data', (data) => {
  console.log('Received data from server:', data.toString());
});

// Handle when the client closes the connection
client.on('close', () => {
  console.log('Connection to server closed.');
});

// Handle when an error occurs
client.on('error', (error) => {
  console.error('Connection error:', error.message);
});
