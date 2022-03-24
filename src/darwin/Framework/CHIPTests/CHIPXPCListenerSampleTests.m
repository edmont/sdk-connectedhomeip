//
//  CHIPRemoteDeviceSampleTests.m
//  CHIPTests
/*
 *
 *    Copyright (c) 2022 Project CHIP Authors
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

// module headers
#import <CHIP/CHIP.h>
#import <CHIP/CHIPDevice.h>

#import "CHIPErrorTestUtils.h"

#import <app/util/af-enums.h>

#import <math.h> // For INFINITY

// system dependencies
#import <XCTest/XCTest.h>

// Set the following to 1 in order to run individual test case manually.
#define MANUAL_INDIVIDUAL_TEST 0

//
// Sample XPC Listener implementation that directly communicates with local CHIPDevice instance
//
// Note that real implementation could look almost the same as the sample if the remote device controller object
// is in a separate process in the same machine.
// If the remote device controller object is in a remote machine, the server protocol must implement
// routing the requests to the remote object in a remote machine using implementation specific transport protocol
// between the two machines.

@interface CHIPXPCListenerSample<NSXPCListenerDelegate> : NSObject

@property (nonatomic, readonly, getter=listenerEndpoint) NSXPCListenerEndpoint * listenerEndpoint;

- (void)start;
- (void)stop;

@end

@interface CHIPDeviceControllerServerSample<CHIPDeviceControllerServerProtocol> : NSObject
@property (nonatomic, readonly, strong) NSString * identifier;
- (instancetype)initWithClientProxy:(id<CHIPDeviceControllerClientProtocol>)proxy
           attributeCacheDictionary:(NSMutableDictionary<NSNumber *, CHIPAttributeCacheContainer *> *)cacheDictionary;
@end

@interface CHIPXPCListenerSample ()

@property (nonatomic, readonly, strong) NSString * controllerId;
@property (nonatomic, readonly, strong) NSXPCInterface * serviceInterface;
@property (nonatomic, readonly, strong) NSXPCInterface * clientInterface;
@property (nonatomic, readonly, strong) NSXPCListener * xpcListener;
@property (nonatomic, readonly, strong) NSMutableDictionary<NSString *, CHIPDeviceControllerServerSample *> * servers;
@property (nonatomic, readonly, strong) NSMutableDictionary<NSNumber *, CHIPAttributeCacheContainer *> * attributeCacheDictionary;

@end

@implementation CHIPXPCListenerSample

- (instancetype)init
{
    if ([super init]) {
        _serviceInterface = [NSXPCInterface interfaceWithProtocol:@protocol(CHIPDeviceControllerServerProtocol)];
        _clientInterface = [NSXPCInterface interfaceWithProtocol:@protocol(CHIPDeviceControllerClientProtocol)];
        _servers = [NSMutableDictionary dictionary];
        _attributeCacheDictionary = [NSMutableDictionary dictionary];
        _xpcListener = [NSXPCListener anonymousListener];
        [_xpcListener setDelegate:(id<NSXPCListenerDelegate>) self];
    }
    return self;
}

- (void)start
{
    [_xpcListener resume];
}

- (void)stop
{
    [_xpcListener suspend];
}

- (NSXPCListenerEndpoint *)listenerEndpoint
{
    return _xpcListener.endpoint;
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    NSLog(@"XPC listener accepting connection");
    newConnection.exportedInterface = _serviceInterface;
    newConnection.remoteObjectInterface = _clientInterface;
    __auto_type newServer = [[CHIPDeviceControllerServerSample alloc] initWithClientProxy:[newConnection remoteObjectProxy]
                                                                 attributeCacheDictionary:_attributeCacheDictionary];
    newConnection.exportedObject = newServer;
    [_servers setObject:newServer forKey:newServer.identifier];
    newConnection.invalidationHandler = ^{
        NSLog(@"XPC connection disconnected");
        [self.servers removeObjectForKey:newServer.identifier];
    };
    [newConnection resume];
    return YES;
}

@end

@interface CHIPDeviceControllerServerSample ()
@property (nonatomic, readwrite, strong) id<CHIPDeviceControllerClientProtocol> clientProxy;
@property (nonatomic, readonly, strong) NSMutableDictionary<NSNumber *, CHIPAttributeCacheContainer *> * attributeCacheDictionary;
@end

// This sample does not have multiple controllers and hence controller Id shall be the same.
static NSString * const kCHIPDeviceControllerId = @"CHIPController";

@implementation CHIPDeviceControllerServerSample

- (instancetype)initWithClientProxy:(id<CHIPDeviceControllerClientProtocol>)proxy
           attributeCacheDictionary:(NSMutableDictionary<NSNumber *, CHIPAttributeCacheContainer *> *)cacheDictionary
{
    if ([super init]) {
        _clientProxy = proxy;
        _identifier = [[NSUUID UUID] UUIDString];
        _attributeCacheDictionary = cacheDictionary;
    }
    return self;
}

- (void)getDeviceControllerWithFabricId:(uint64_t)fabricId
                             completion:(void (^)(id _Nullable controller, NSError * _Nullable error))completion
{
    // We are using a shared local device controller and hence no disctinction per fabricId.
    (void) fabricId;
    completion(kCHIPDeviceControllerId, nil);
}

- (void)getAnyDeviceControllerWithCompletion:(void (^)(id _Nullable controller, NSError * _Nullable error))completion
{
    completion(kCHIPDeviceControllerId, nil);
}

- (void)readAttributeWithController:(id)controller
                             nodeId:(uint64_t)nodeId
                         endpointId:(NSNumber * _Nullable)endpointId
                          clusterId:(NSNumber * _Nullable)clusterId
                        attributeId:(NSNumber * _Nullable)attributeId
                             params:(NSDictionary<NSString *, id> * _Nullable)params
                         completion:(void (^)(id _Nullable values, NSError * _Nullable error))completion
{
    (void) controller;
    __auto_type sharedController = [CHIPDeviceController sharedController];
    if (sharedController) {
        [sharedController
            getConnectedDevice:nodeId
                         queue:dispatch_get_main_queue()
             completionHandler:^(CHIPDevice * _Nullable device, NSError * _Nullable error) {
                 if (error) {
                     NSLog(@"Failed to get connected device");
                     completion(nil, error);
                 } else {
                     [device readAttributeWithEndpointId:endpointId
                                               clusterId:clusterId
                                             attributeId:attributeId
                                                  params:[CHIPDeviceController decodeXPCReadParams:params]
                                             clientQueue:dispatch_get_main_queue()
                                              completion:^(NSArray<NSDictionary<NSString *, id> *> * _Nullable values,
                                                  NSError * _Nullable error) {
                                                  completion([CHIPDeviceController encodeXPCResponseValues:values], error);
                                              }];
                 }
             }];
    } else {
        NSLog(@"Failed to get shared controller");
        completion(nil, [NSError errorWithDomain:CHIPErrorDomain code:CHIPErrorCodeGeneralError userInfo:nil]);
    }
}

- (void)writeAttributeWithController:(id)controller
                              nodeId:(uint64_t)nodeId
                          endpointId:(NSNumber *)endpointId
                           clusterId:(NSNumber *)clusterId
                         attributeId:(NSNumber *)attributeId
                               value:(id)value
                   timedWriteTimeout:(NSNumber *)timeoutMs
                          completion:(void (^)(id _Nullable values, NSError * _Nullable error))completion
{
    (void) controller;
    __auto_type sharedController = [CHIPDeviceController sharedController];
    if (sharedController) {
        [sharedController
            getConnectedDevice:nodeId
                         queue:dispatch_get_main_queue()
             completionHandler:^(CHIPDevice * _Nullable device, NSError * _Nullable error) {
                 if (error) {
                     NSLog(@"Failed to get connected device");
                     completion(nil, error);
                 } else {
                     [device writeAttributeWithEndpointId:endpointId
                                                clusterId:clusterId
                                              attributeId:attributeId
                                                    value:value
                                        timedWriteTimeout:timeoutMs
                                              clientQueue:dispatch_get_main_queue()
                                               completion:^(NSArray<NSDictionary<NSString *, id> *> * _Nullable values,
                                                   NSError * _Nullable error) {
                                                   completion([CHIPDeviceController encodeXPCResponseValues:values], error);
                                               }];
                 }
             }];
    } else {
        NSLog(@"Failed to get shared controller");
        completion(nil, [NSError errorWithDomain:CHIPErrorDomain code:CHIPErrorCodeGeneralError userInfo:nil]);
    }
}

- (void)invokeCommandWithController:(id)controller
                             nodeId:(uint64_t)nodeId
                         endpointId:(NSNumber *)endpointId
                          clusterId:(NSNumber *)clusterId
                          commandId:(NSNumber *)commandId
                             fields:(id)fields
                 timedInvokeTimeout:(NSNumber * _Nullable)timeoutMs
                         completion:(void (^)(id _Nullable values, NSError * _Nullable error))completion
{
    (void) controller;
    __auto_type sharedController = [CHIPDeviceController sharedController];
    if (sharedController) {
        [sharedController
            getConnectedDevice:nodeId
                         queue:dispatch_get_main_queue()
             completionHandler:^(CHIPDevice * _Nullable device, NSError * _Nullable error) {
                 if (error) {
                     NSLog(@"Failed to get connected device");
                     completion(nil, error);
                 } else {
                     [device invokeCommandWithEndpointId:endpointId
                                               clusterId:clusterId
                                               commandId:commandId
                                           commandFields:fields
                                      timedInvokeTimeout:nil
                                             clientQueue:dispatch_get_main_queue()
                                              completion:^(NSArray<NSDictionary<NSString *, id> *> * _Nullable values,
                                                  NSError * _Nullable error) {
                                                  completion([CHIPDeviceController encodeXPCResponseValues:values], error);
                                              }];
                 }
             }];
    } else {
        NSLog(@"Failed to get shared controller");
        completion(nil, [NSError errorWithDomain:CHIPErrorDomain code:CHIPErrorCodeGeneralError userInfo:nil]);
    }
}

- (void)subscribeAttributeWithController:(id)controller
                                  nodeId:(uint64_t)nodeId
                              endpointId:(NSNumber * _Nullable)endpointId
                               clusterId:(NSNumber * _Nullable)clusterId
                             attributeId:(NSNumber * _Nullable)attributeId
                             minInterval:(NSNumber *)minInterval
                             maxInterval:(NSNumber *)maxInterval
                                  params:(NSDictionary<NSString *, id> * _Nullable)params
                      establishedHandler:(void (^)(void))establishedHandler
{
    __auto_type sharedController = [CHIPDeviceController sharedController];
    if (sharedController) {
        [sharedController
            getConnectedDevice:nodeId
                         queue:dispatch_get_main_queue()
             completionHandler:^(CHIPDevice * _Nullable device, NSError * _Nullable error) {
                 if (error) {
                     NSLog(@"Failed to get connected device");
                     establishedHandler();
                     // Send an error report so that the client knows of the failure
                     [self.clientProxy handleReportWithController:controller
                                                           nodeId:nodeId
                                                           values:nil
                                                            error:[NSError errorWithDomain:CHIPErrorDomain
                                                                                      code:CHIPErrorCodeGeneralError
                                                                                  userInfo:nil]];
                 } else {
                     [device subscribeAttributeWithEndpointId:endpointId
                                                    clusterId:clusterId
                                                  attributeId:attributeId
                                                  minInterval:minInterval
                                                  maxInterval:maxInterval
                                                       params:[CHIPDeviceController decodeXPCSubscribeParams:params]
                                                  clientQueue:dispatch_get_main_queue()
                                                reportHandler:^(NSArray<NSDictionary<NSString *, id> *> * _Nullable values,
                                                    NSError * _Nullable error) {
                                                    [self.clientProxy handleReportWithController:controller
                                                                                          nodeId:nodeId
                                                                                          values:[CHIPDeviceController
                                                                                                     encodeXPCResponseValues:values]
                                                                                           error:error];
                                                }
                                      subscriptionEstablished:establishedHandler];
                 }
             }];
    } else {
        NSLog(@"Failed to get shared controller");
        establishedHandler();
        // Send an error report so that the client knows of the failure
        [self.clientProxy handleReportWithController:controller
                                              nodeId:nodeId
                                              values:nil
                                               error:[NSError errorWithDomain:CHIPErrorDomain
                                                                         code:CHIPErrorCodeGeneralError
                                                                     userInfo:nil]];
    }
}

- (void)stopReportsWithController:(id _Nullable)controller nodeId:(uint64_t)nodeId completion:(void (^)(void))completion
{
    __auto_type sharedController = [CHIPDeviceController sharedController];
    if (sharedController) {
        [sharedController getConnectedDevice:nodeId
                                       queue:dispatch_get_main_queue()
                           completionHandler:^(CHIPDevice * _Nullable device, NSError * _Nullable error) {
                               if (error) {
                                   NSLog(@"Failed to get connected device");
                               } else {
                                   [device deregisterReportHandlersWithClientQueue:dispatch_get_main_queue() completion:completion];
                               }
                           }];
    } else {
        NSLog(@"Failed to get shared controller");
        completion();
    }
}

- (void)subscribeAttributeCacheWithController:(id _Nullable)controller
                                       nodeId:(uint64_t)nodeId
                                       params:(NSDictionary<NSString *, id> * _Nullable)params
                                   completion:(void (^)(NSError * _Nullable error))completion
{
    __auto_type sharedController = [CHIPDeviceController sharedController];
    if (sharedController) {
        CHIPAttributeCacheContainer * attributeCacheContainer = [[CHIPAttributeCacheContainer alloc] init];
        [attributeCacheContainer
            subscribeWithDeviceController:sharedController
                                 deviceId:nodeId
                                   params:[CHIPDeviceController decodeXPCSubscribeParams:params]
                              clientQueue:dispatch_get_main_queue()
                               completion:^(NSError * _Nullable error) {
                                   NSNumber * nodeIdNumber = [NSNumber numberWithUnsignedLongLong:nodeId];
                                   if (error) {
                                       NSLog(@"Failed to have subscribe attribute by cache");
                                       [self.attributeCacheDictionary removeObjectForKey:nodeIdNumber];
                                   } else {
                                       NSLog(@"Attribute cache for node %llu successfully subscribed attributes", nodeId);
                                       [self.attributeCacheDictionary setObject:attributeCacheContainer forKey:nodeIdNumber];
                                   }
                                   completion(error);
                               }];
    } else {
        NSLog(@"Failed to get shared controller");
        completion([NSError errorWithDomain:CHIPErrorDomain code:CHIPErrorCodeGeneralError userInfo:nil]);
    }
}

- (void)readAttributeCacheWithController:(id _Nullable)controller
                                  nodeId:(uint64_t)nodeId
                              endpointId:(NSNumber * _Nullable)endpointId
                               clusterId:(NSNumber * _Nullable)clusterId
                             attributeId:(NSNumber * _Nullable)attributeId
                              completion:(void (^)(id _Nullable values, NSError * _Nullable error))completion
{
    CHIPAttributeCacheContainer * attributeCacheContainer = _attributeCacheDictionary[[NSNumber numberWithUnsignedLongLong:nodeId]];
    if (attributeCacheContainer) {
        [attributeCacheContainer
            readAttributeWithEndpointId:endpointId
                              clusterId:clusterId
                            attributeId:attributeId
                            clientQueue:dispatch_get_main_queue()
                             completion:^(NSArray<NSDictionary<NSString *, id> *> * _Nullable values, NSError * _Nullable error) {
                                 completion([CHIPDeviceController encodeXPCResponseValues:values], error);
                             }];
    } else {
        NSLog(@"Attribute cache for node ID %llu was not setup", nodeId);
        completion(nil, [NSError errorWithDomain:CHIPErrorDomain code:CHIPErrorCodeGeneralError userInfo:nil]);
    }
}

@end

static const uint16_t kPairingTimeoutInSeconds = 10;
static const uint16_t kCASESetupTimeoutInSeconds = 30;
static const uint16_t kTimeoutInSeconds = 3;
static const uint64_t kDeviceId = 0x12344321;
static const uint16_t kDiscriminator = 3840;
static const uint32_t kSetupPINCode = 20202021;
static const uint16_t kRemotePort = 5540;
static const uint16_t kLocalPort = 5541;
static NSString * kAddress = @"::1";

// This test suite reuses a device object to speed up the test process for CI.
// The following global variable holds the reference to the device object.
static CHIPDevice * mConnectedDevice;
static CHIPDeviceController * mDeviceController;
static CHIPXPCListenerSample * mSampleListener;

static CHIPDevice * GetConnectedDevice(void)
{
    XCTAssertNotNil(mConnectedDevice);
    return mConnectedDevice;
}

static CHIPDeviceController * GetDeviceController(void)
{
    XCTAssertNotNil(mDeviceController);
    return mDeviceController;
}

@interface CHIPRemoteDeviceSampleTestPairingDelegate : NSObject <CHIPDevicePairingDelegate>
@property (nonatomic, strong) XCTestExpectation * expectation;
@end

@implementation CHIPRemoteDeviceSampleTestPairingDelegate
- (id)initWithExpectation:(XCTestExpectation *)expectation
{
    self = [super init];
    if (self) {
        _expectation = expectation;
    }
    return self;
}

- (void)onPairingComplete:(NSError *)error
{
    XCTAssertEqual(error.code, 0);
    [_expectation fulfill];
    _expectation = nil;
}

- (void)onCommissioningComplete:(NSError *)error
{
    XCTAssertEqual(error.code, 0);
    [_expectation fulfill];
    _expectation = nil;
}

- (void)onAddressUpdated:(NSError *)error
{
    XCTAssertEqual(error.code, 0);
    [_expectation fulfill];
    _expectation = nil;
}
@end

@interface CHIPXPCListenerSampleTests : XCTestCase

@end

@implementation CHIPXPCListenerSampleTests

- (void)setUp
{
    [super setUp];
    [self setContinueAfterFailure:NO];
}

- (void)tearDown
{
#if MANUAL_INDIVIDUAL_TEST
    [self shutdownStack];
#endif
    [super tearDown];
}

- (void)initStack
{
    XCTestExpectation * expectation = [self expectationWithDescription:@"Pairing Complete"];

    CHIPDeviceController * controller = [CHIPDeviceController sharedController];
    XCTAssertNotNil(controller);

    CHIPRemoteDeviceSampleTestPairingDelegate * pairing =
        [[CHIPRemoteDeviceSampleTestPairingDelegate alloc] initWithExpectation:expectation];
    dispatch_queue_t callbackQueue = dispatch_queue_create("com.chip.pairing", DISPATCH_QUEUE_SERIAL);

    [controller setListenPort:kLocalPort];
    [controller setPairingDelegate:pairing queue:callbackQueue];

    BOOL started = [controller startup:nil vendorId:0 nocSigner:nil];
    XCTAssertTrue(started);

    NSError * error;
    [controller pairDevice:kDeviceId
                   address:kAddress
                      port:kRemotePort
             discriminator:kDiscriminator
              setupPINCode:kSetupPINCode
                     error:&error];
    XCTAssertEqual(error.code, 0);

    [self waitForExpectationsWithTimeout:kPairingTimeoutInSeconds handler:nil];

    __block XCTestExpectation * connectionExpectation = [self expectationWithDescription:@"CASE established"];
    [controller getConnectedDevice:kDeviceId
                             queue:dispatch_get_main_queue()
                 completionHandler:^(CHIPDevice * _Nullable device, NSError * _Nullable error) {
                     XCTAssertEqual(error.code, 0);
                     [connectionExpectation fulfill];
                     connectionExpectation = nil;
                 }];
    [self waitForExpectationsWithTimeout:kCASESetupTimeoutInSeconds handler:nil];

    mSampleListener = [[CHIPXPCListenerSample alloc] init];
    [mSampleListener start];
}

- (void)shutdownStack
{
    [mSampleListener stop];
    mSampleListener = nil;

    CHIPDeviceController * controller = [CHIPDeviceController sharedController];
    XCTAssertNotNil(controller);

    BOOL stopped = [controller shutdown];
    XCTAssertTrue(stopped);

    mDeviceController = nil;
}

- (void)waitForCommissionee
{
    XCTestExpectation * expectation = [self expectationWithDescription:@"Wait for the commissioned device to be retrieved"];

    dispatch_queue_t queue = dispatch_get_main_queue();
    __auto_type remoteController = [CHIPDeviceController
        sharedControllerWithId:kCHIPDeviceControllerId
               xpcConnectBlock:^NSXPCConnection * _Nonnull {
                   if (mSampleListener.listenerEndpoint) {
                       return [[NSXPCConnection alloc] initWithListenerEndpoint:mSampleListener.listenerEndpoint];
                   }
                   NSLog(@"Listener is not active");
                   return nil;
               }];
    [remoteController getConnectedDevice:kDeviceId
                                   queue:queue
                       completionHandler:^(CHIPDevice * _Nullable device, NSError * _Nullable error) {
                           mConnectedDevice = device;
                           [expectation fulfill];
                       }];
    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
    mDeviceController = remoteController;
}

#if !MANUAL_INDIVIDUAL_TEST
- (void)test000_SetUp
{
    [self initStack];
    [self waitForCommissionee];
}
#endif

- (void)test001_ReadAttribute
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation =
        [self expectationWithDescription:@"read DeviceDescriptor DeviceType attribute for all endpoints"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    [device readAttributeWithEndpointId:nil
                              clusterId:@29
                            attributeId:@0
                                 params:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"read attribute: DeviceType values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPAttributePath * path = result[@"attributePath"];
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 29);
                                         XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
                                         XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
                                         XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"Array"]);
                                     }
                                     XCTAssertTrue([resultArray count] > 0);
                                 }

                                 [expectation fulfill];
                             }];

    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
}

- (void)test002_WriteAttribute
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"write LevelControl Brightness attribute"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    NSDictionary * writeValue = [NSDictionary
        dictionaryWithObjectsAndKeys:@"UnsignedInteger", @"type", [NSNumber numberWithUnsignedInteger:200], @"value", nil];
    [device writeAttributeWithEndpointId:@1
                               clusterId:@8
                             attributeId:@17
                                   value:writeValue
                       timedWriteTimeout:nil
                             clientQueue:queue
                              completion:^(id _Nullable values, NSError * _Nullable error) {
                                  NSLog(@"write attribute: Brightness values: %@, error: %@", values, error);

                                  XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                  {
                                      XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                      NSArray * resultArray = values;
                                      for (NSDictionary * result in resultArray) {
                                          CHIPAttributePath * path = result[@"attributePath"];
                                          XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                          XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
                                          XCTAssertEqual([path.attribute unsignedIntegerValue], 17);
                                          XCTAssertNil(result[@"error"]);
                                      }
                                      XCTAssertEqual([resultArray count], 1);
                                  }

                                  [expectation fulfill];
                              }];

    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
}

- (void)test003_InvokeCommand
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"invoke MoveToLevelWithOnOff command"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    NSDictionary * fields = @{
        @"type" : @"Structure",
        @"value" : @[
            @{ @"contextTag" : @0, @"data" : @ { @"type" : @"UnsignedInteger", @"value" : @0 } },
            @{ @"contextTag" : @1, @"data" : @ { @"type" : @"UnsignedInteger", @"value" : @10 } }
        ]
    };
    [device invokeCommandWithEndpointId:@1
                              clusterId:@8
                              commandId:@4
                          commandFields:fields
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: MoveToLevelWithOnOff values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 4);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }

                                 [expectation fulfill];
                             }];

    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
}

static void (^globalReportHandler)(id _Nullable values, NSError * _Nullable error) = nil;

- (void)test004_Subscribe
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"subscribe OnOff attribute"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    [device subscribeAttributeWithEndpointId:@1
        clusterId:@6
        attributeId:@0
        minInterval:@2
        maxInterval:@10
        params:nil
        clientQueue:queue
        reportHandler:^(id _Nullable values, NSError * _Nullable error) {
            NSLog(@"report attribute: OnOff values: %@, error: %@", values, error);

            if (globalReportHandler) {
                __auto_type callback = globalReportHandler;
                globalReportHandler = nil;
                callback(values, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"subscribe attribute: OnOff established");
            [expectation fulfill];
        }];

    // Wait till establishment
    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];

    // Set up expectation for report
    expectation = [self expectationWithDescription:@"receive OnOff attribute report"];
    globalReportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);
        XCTAssertTrue([values isKindOfClass:[NSArray class]]);

        for (NSDictionary * result in values) {
            CHIPAttributePath * path = result[@"attributePath"];
            XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
            XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
            XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
            XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
            XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"Boolean"]);
            XCTAssertEqual([result[@"data"][@"value"] boolValue], YES);
        }
        [expectation fulfill];
    };

    // Send command to trigger attribute change
    NSDictionary * fields = [NSDictionary dictionaryWithObjectsAndKeys:@"Structure", @"type", [NSArray array], @"value", nil];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@1
                          commandFields:fields
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 1);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                             }];

    // Wait for report
    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];

    XCTestExpectation * clearExpectation = [self expectationWithDescription:@"report handlers deregistered"];
    [device deregisterReportHandlersWithClientQueue:queue
                                         completion:^{
                                             [clearExpectation fulfill];
                                         }];
    [self waitForExpectations:@[ clearExpectation ] timeout:kTimeoutInSeconds];
}

- (void)test005_ReadAttributeFailure
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"read failed"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    [device readAttributeWithEndpointId:@0
                              clusterId:@10000
                            attributeId:@0
                                 params:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"read attribute: DeviceType values: %@, error: %@", values, error);

                                 XCTAssertNil(values);
                                 // Error is copied over XPC and hence cannot use CHIPErrorTestUtils utility which checks against a
                                 // local domain string object.
                                 XCTAssertTrue([error.domain isEqualToString:MatterInteractionErrorDomain]);
                                 XCTAssertEqual(error.code, EMBER_ZCL_STATUS_UNSUPPORTED_CLUSTER);

                                 [expectation fulfill];
                             }];

    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
}

- (void)test006_WriteAttributeFailure
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"write failed"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    NSDictionary * writeValue = [NSDictionary
        dictionaryWithObjectsAndKeys:@"UnsignedInteger", @"type", [NSNumber numberWithUnsignedInteger:200], @"value", nil];
    [device writeAttributeWithEndpointId:@1
                               clusterId:@8
                             attributeId:@10000
                                   value:writeValue
                       timedWriteTimeout:nil
                             clientQueue:queue
                              completion:^(id _Nullable values, NSError * _Nullable error) {
                                  NSLog(@"write attribute: Brightness values: %@, error: %@", values, error);

                                  XCTAssertNil(values);
                                  // Error is copied over XPC and hence cannot use CHIPErrorTestUtils utility which checks against a
                                  // local domain string object.
                                  XCTAssertTrue([error.domain isEqualToString:MatterInteractionErrorDomain]);
                                  XCTAssertEqual(error.code, EMBER_ZCL_STATUS_UNSUPPORTED_ATTRIBUTE);

                                  [expectation fulfill];
                              }];

    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
}

#if 0 // Re-enable test if the crash bug in CHIP stack is fixed to handle bad command Id
- (void)test007_InvokeCommandFailure
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"invoke MoveToLevelWithOnOff command"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    NSDictionary *fields = [NSDictionary dictionaryWithObjectsAndKeys:
                            @"Structure", @"type",
                            [NSArray arrayWithObjects:
                             [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithUnsignedInteger:0], @"tag",
                              [NSDictionary dictionaryWithObjectsAndKeys:
                               @"UnsignedInteger", @"type",
                               [NSNumber numberWithUnsignedInteger:0], @"value", nil], @"value", nil],
                             [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithUnsignedInteger:1], @"tag",
                              [NSDictionary dictionaryWithObjectsAndKeys:
                               @"UnsignedInteger", @"type",
                               [NSNumber numberWithUnsignedInteger:10], @"value", nil], @"value", nil],
                             nil], @"value", nil];
    [device invokeCommandWithEndpointId:@1 clusterId:@8 commandId:@40000 commandFields:fields clientQueue:queue
                     timedInvokeTimeout:nil
                             completion:^(id _Nullable values, NSError * _Nullable error) {
        NSLog(@"invoke command: MoveToLevelWithOnOff values: %@, error: %@", values, error);

        XCTAssertNil(values);
        // Error is copied over XPC and hence cannot use CHIPErrorTestUtils utility which checks against a local domain string object.
        XCTAssertTrue([error.domain isEqualToString:MatterInteractionErrorDomain]);
        XCTAssertEqual(error.code, EMBER_ZCL_STATUS_UNSUPPORTED_COMMAND);

        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
}
#endif

- (void)test008_SubscribeFailure
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"subscribe OnOff attribute"];

    // Set up expectation for report
    XCTestExpectation * errorReportExpectation = [self expectationWithDescription:@"receive OnOff attribute report"];
    globalReportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertNil(values);
        // Error is copied over XPC and hence cannot use CHIPErrorTestUtils utility which checks against a local domain string
        // object.
        XCTAssertTrue([error.domain isEqualToString:MatterInteractionErrorDomain]);
        XCTAssertEqual(error.code, EMBER_ZCL_STATUS_UNSUPPORTED_ENDPOINT);
        [errorReportExpectation fulfill];
    };

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    [device subscribeAttributeWithEndpointId:@10000
        clusterId:@6
        attributeId:@0
        minInterval:@2
        maxInterval:@10
        params:nil
        clientQueue:queue
        reportHandler:^(id _Nullable values, NSError * _Nullable error) {
            NSLog(@"report attribute: OnOff values: %@, error: %@", values, error);

            if (globalReportHandler) {
                __auto_type callback = globalReportHandler;
                globalReportHandler = nil;
                callback(values, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"subscribe attribute: OnOff established");
            [expectation fulfill];
        }];

    // Wait till establishment and error report
    [self waitForExpectations:[NSArray arrayWithObjects:expectation, errorReportExpectation, nil] timeout:kTimeoutInSeconds];
}

- (void)test009_ReadAttributeWithParams
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation =
        [self expectationWithDescription:@"read DeviceDescriptor DeviceType attribute for all endpoints"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    CHIPReadParams * readParams = [[CHIPReadParams alloc] init];
    readParams.fabricFiltered = @NO;
    [device readAttributeWithEndpointId:nil
                              clusterId:@29
                            attributeId:@0
                                 params:readParams
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"read attribute: DeviceType values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPAttributePath * path = result[@"attributePath"];
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 29);
                                         XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
                                         XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
                                         XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"Array"]);
                                     }
                                     XCTAssertTrue([resultArray count] > 0);
                                 }

                                 [expectation fulfill];
                             }];

    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
}

- (void)test010_SubscribeWithNoParams
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    XCTestExpectation * clearExpectation = [self expectationWithDescription:@"report handlers deregistered"];
    [device deregisterReportHandlersWithClientQueue:queue
                                         completion:^{
                                             [clearExpectation fulfill];
                                         }];
    [self waitForExpectations:@[ clearExpectation ] timeout:kTimeoutInSeconds];

    __block void (^firstReportHandler)(id _Nullable values, NSError * _Nullable error) = nil;
    __block void (^secondReportHandler)(id _Nullable values, NSError * _Nullable error) = nil;

    // Subscribe
    XCTestExpectation * subscribeExpectation = [self expectationWithDescription:@"subscribe OnOff attribute"];
    [device subscribeAttributeWithEndpointId:@1
        clusterId:@6
        attributeId:@0
        minInterval:@2
        maxInterval:@10
        params:nil
        clientQueue:queue
        reportHandler:^(id _Nullable values, NSError * _Nullable error) {
            NSLog(@"report attribute: OnOff values: %@, error: %@", values, error);
            XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

            if (firstReportHandler) {
                __auto_type callback = firstReportHandler;
                firstReportHandler = nil;
                callback(values, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"subscribe attribute: OnOff established");
            [subscribeExpectation fulfill];
        }];

    [self waitForExpectations:@[ subscribeExpectation ] timeout:kTimeoutInSeconds];

    // Setup 2nd subscriber
    subscribeExpectation = [self expectationWithDescription:@"subscribe CurrentLevel attribute"];
    [device subscribeAttributeWithEndpointId:@1
        clusterId:@8
        attributeId:@0
        minInterval:@2
        maxInterval:@10
        params:nil
        clientQueue:queue
        reportHandler:^(id _Nullable values, NSError * _Nullable error) {
            NSLog(@"2nd subscriber report attribute: CurrentLevel values: %@, error: %@", values, error);
            XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

            if (secondReportHandler) {
                __auto_type callback = secondReportHandler;
                secondReportHandler = nil;
                callback(values, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"2nd subscribe attribute: CurrentLevel established");
            [subscribeExpectation fulfill];
        }];

    // Wait till establishment
    [self waitForExpectations:@[ subscribeExpectation ] timeout:kTimeoutInSeconds];

    // Send command to clear attribute state
    XCTestExpectation * clearCommandExpectation = [self expectationWithDescription:@"Clearing command invoked"];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@0
                          commandFields:@{ @"type" : @"Structure", @"value" : @[] }
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 0);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                                 [clearCommandExpectation fulfill];
                             }];
    [self waitForExpectations:@[ clearCommandExpectation ] timeout:kTimeoutInSeconds];

    // Set up expectations for report
    XCTestExpectation * reportExpectation =
        [self expectationWithDescription:@"The 1st subscriber unexpectedly received OnOff attribute report"];
    reportExpectation.inverted = YES;
    firstReportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

        {
            XCTAssertTrue([values isKindOfClass:[NSArray class]]);
            NSDictionary * result = values[0];
            CHIPAttributePath * path = result[@"attributePath"];
            XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
            XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
            XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
            XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
            XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"Boolean"]);
            XCTAssertEqual([result[@"data"][@"value"] boolValue], YES);
        }
        [reportExpectation fulfill];
    };

    XCTestExpectation * secondReportExpectation =
        [self expectationWithDescription:@"The 2nd subscriber received CurrentLevel attribute report"];
    secondReportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

        {
            XCTAssertTrue([values isKindOfClass:[NSArray class]]);
            NSDictionary * result = values[0];
            CHIPAttributePath * path = result[@"attributePath"];
            XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
            XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
            XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
            XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
            XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"UnsignedInteger"]);
            XCTAssertNotNil(result[@"data"][@"value"]);
        }
        [secondReportExpectation fulfill];
    };

    // Send command to trigger attribute change
    NSDictionary * fields = [NSDictionary dictionaryWithObjectsAndKeys:@"Structure", @"type", [NSArray array], @"value", nil];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@1
                          commandFields:fields
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 1);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                             }];

    // Wait for report
    [self waitForExpectations:@[ reportExpectation, secondReportExpectation ] timeout:kTimeoutInSeconds];

    clearExpectation = [self expectationWithDescription:@"report handlers deregistered"];
    [device deregisterReportHandlersWithClientQueue:queue
                                         completion:^{
                                             [clearExpectation fulfill];
                                         }];
    [self waitForExpectations:@[ clearExpectation ] timeout:kTimeoutInSeconds];
}

- (void)test011_SubscribeWithParams
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    XCTestExpectation * clearExpectation = [self expectationWithDescription:@"report handlers deregistered"];
    [device deregisterReportHandlersWithClientQueue:queue
                                         completion:^{
                                             [clearExpectation fulfill];
                                         }];
    [self waitForExpectations:@[ clearExpectation ] timeout:kTimeoutInSeconds];

    __block void (^firstReportHandler)(id _Nullable values, NSError * _Nullable error) = nil;
    __block void (^secondReportHandler)(id _Nullable values, NSError * _Nullable error) = nil;

    // Subscribe
    XCTestExpectation * subscribeExpectation = [self expectationWithDescription:@"subscribe OnOff attribute"];
    [device subscribeAttributeWithEndpointId:@1
        clusterId:@6
        attributeId:@0
        minInterval:@2
        maxInterval:@10
        params:nil
        clientQueue:queue
        reportHandler:^(id _Nullable values, NSError * _Nullable error) {
            NSLog(@"report attribute: OnOff values: %@, error: %@", values, error);
            XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

            if (firstReportHandler) {
                __auto_type callback = firstReportHandler;
                firstReportHandler = nil;
                callback(values, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"subscribe attribute: OnOff established");
            [subscribeExpectation fulfill];
        }];

    [self waitForExpectations:@[ subscribeExpectation ] timeout:kTimeoutInSeconds];

    // Setup 2nd subscriber
    CHIPSubscribeParams * myParams = [[CHIPSubscribeParams alloc] init];
    myParams.keepPreviousSubscriptions = @NO;
    subscribeExpectation = [self expectationWithDescription:@"subscribe CurrentLevel attribute"];
    [device subscribeAttributeWithEndpointId:@1
        clusterId:@8
        attributeId:@0
        minInterval:@2
        maxInterval:@10
        params:myParams
        clientQueue:queue
        reportHandler:^(id _Nullable values, NSError * _Nullable error) {
            NSLog(@"2nd subscriber report attribute: CurrentLevel values: %@, error: %@", values, error);
            XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

            if (secondReportHandler) {
                __auto_type callback = secondReportHandler;
                secondReportHandler = nil;
                callback(values, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"2nd subscribe attribute: CurrentLevel established");
            [subscribeExpectation fulfill];
        }];

    // Wait till establishment
    [self waitForExpectations:@[ subscribeExpectation ] timeout:kTimeoutInSeconds];

    // Send command to clear attribute state
    XCTestExpectation * clearCommandExpectation = [self expectationWithDescription:@"Clearing command invoked"];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@0
                          commandFields:@{ @"type" : @"Structure", @"value" : @[] }
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 0);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                                 [clearCommandExpectation fulfill];
                             }];
    [self waitForExpectations:@[ clearCommandExpectation ] timeout:kTimeoutInSeconds];

    // Set up expectations for report
    XCTestExpectation * reportExpectation =
        [self expectationWithDescription:@"The 1st subscriber unexpectedly received OnOff attribute report"];
    reportExpectation.inverted = YES;
    firstReportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

        {
            XCTAssertTrue([values isKindOfClass:[NSArray class]]);
            NSDictionary * result = values[0];
            CHIPAttributePath * path = result[@"attributePath"];
            XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
            XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
            XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
            XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
            XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"Boolean"]);
            XCTAssertEqual([result[@"data"][@"value"] boolValue], YES);
        }
        [reportExpectation fulfill];
    };

    XCTestExpectation * secondReportExpectation =
        [self expectationWithDescription:@"The 2nd subscriber received CurrentLevel attribute report"];
    secondReportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

        {
            XCTAssertTrue([values isKindOfClass:[NSArray class]]);
            NSDictionary * result = values[0];
            CHIPAttributePath * path = result[@"attributePath"];
            XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
            XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
            XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
            XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
            XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"UnsignedInteger"]);
            XCTAssertNotNil(result[@"data"][@"value"]);
        }
        [secondReportExpectation fulfill];
    };

    // Send command to trigger attribute change
    NSDictionary * fields = [NSDictionary dictionaryWithObjectsAndKeys:@"Structure", @"type", [NSArray array], @"value", nil];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@1
                          commandFields:fields
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 1);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                             }];

    // Wait for report
    [self waitForExpectations:@[ reportExpectation, secondReportExpectation ] timeout:kTimeoutInSeconds];

    clearExpectation = [self expectationWithDescription:@"report handlers deregistered"];
    [device deregisterReportHandlersWithClientQueue:queue
                                         completion:^{
                                             [clearExpectation fulfill];
                                         }];
    [self waitForExpectations:@[ clearExpectation ] timeout:kTimeoutInSeconds];

    clearExpectation = [self expectationWithDescription:@"report handlers deregistered"];
    [device deregisterReportHandlersWithClientQueue:queue
                                         completion:^{
                                             [clearExpectation fulfill];
                                         }];
    [self waitForExpectations:@[ clearExpectation ] timeout:kTimeoutInSeconds];
}

- (void)test012_SubscribeKeepingPreviousSubscription
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    XCTestExpectation * clearExpectation = [self expectationWithDescription:@"report handlers deregistered"];
    [device deregisterReportHandlersWithClientQueue:queue
                                         completion:^{
                                             [clearExpectation fulfill];
                                         }];
    [self waitForExpectations:@[ clearExpectation ] timeout:kTimeoutInSeconds];

    __block void (^firstReportHandler)(id _Nullable values, NSError * _Nullable error) = nil;
    __block void (^secondReportHandler)(id _Nullable values, NSError * _Nullable error) = nil;

    // Subscribe
    XCTestExpectation * subscribeExpectation = [self expectationWithDescription:@"subscribe OnOff attribute"];
    [device subscribeAttributeWithEndpointId:@1
        clusterId:@6
        attributeId:@0
        minInterval:@2
        maxInterval:@10
        params:nil
        clientQueue:queue
        reportHandler:^(id _Nullable values, NSError * _Nullable error) {
            NSLog(@"report attribute: OnOff values: %@, error: %@", values, error);
            XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

            if (firstReportHandler) {
                __auto_type callback = firstReportHandler;
                firstReportHandler = nil;
                callback(values, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"subscribe attribute: OnOff established");
            [subscribeExpectation fulfill];
        }];

    [self waitForExpectations:@[ subscribeExpectation ] timeout:kTimeoutInSeconds];

    // Setup 2nd subscriber
    subscribeExpectation = [self expectationWithDescription:@"subscribe CurrentLevel attribute"];
    CHIPSubscribeParams * myParams = [[CHIPSubscribeParams alloc] init];
    myParams.keepPreviousSubscriptions = @YES;
    [device subscribeAttributeWithEndpointId:@1
        clusterId:@8
        attributeId:@0
        minInterval:@2
        maxInterval:@10
        params:myParams
        clientQueue:queue
        reportHandler:^(id _Nullable values, NSError * _Nullable error) {
            NSLog(@"2nd subscriber report attribute: CurrentLevel values: %@, error: %@", values, error);
            XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

            if (secondReportHandler) {
                __auto_type callback = secondReportHandler;
                secondReportHandler = nil;
                callback(values, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"2nd subscribe attribute: CurrentLevel established");
            [subscribeExpectation fulfill];
        }];

    // Wait till establishment
    [self waitForExpectations:@[ subscribeExpectation ] timeout:kTimeoutInSeconds];

    // Send command to clear attribute state
    XCTestExpectation * clearCommandExpectation = [self expectationWithDescription:@"Clearing command invoked"];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@0
                          commandFields:@{ @"type" : @"Structure", @"value" : @[] }
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 0);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                                 [clearCommandExpectation fulfill];
                             }];
    [self waitForExpectations:@[ clearCommandExpectation ] timeout:kTimeoutInSeconds];

    // Set up expectations for report
    XCTestExpectation * reportExpectation = [self expectationWithDescription:@"The 1st subscriber received OnOff attribute report"];
    firstReportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

        {
            XCTAssertTrue([values isKindOfClass:[NSArray class]]);
            NSDictionary * result = values[0];
            CHIPAttributePath * path = result[@"attributePath"];
            XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
            XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
            XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
            XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
            XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"Boolean"]);
            XCTAssertEqual([result[@"data"][@"value"] boolValue], YES);
        }
        [reportExpectation fulfill];
    };

    XCTestExpectation * secondReportExpectation =
        [self expectationWithDescription:@"The 2nd subscriber received CurrentLevel attribute report"];
    secondReportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

        {
            XCTAssertTrue([values isKindOfClass:[NSArray class]]);
            NSDictionary * result = values[0];
            CHIPAttributePath * path = result[@"attributePath"];
            XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
            XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
            XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
            XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
            XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"UnsignedInteger"]);
            XCTAssertNotNil(result[@"data"][@"value"]);
        }
        [secondReportExpectation fulfill];
    };

    // Send command to trigger attribute change
    NSDictionary * fields = [NSDictionary dictionaryWithObjectsAndKeys:@"Structure", @"type", [NSArray array], @"value", nil];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@1
                          commandFields:fields
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 1);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                             }];

    // Wait for report
    [self waitForExpectations:@[ reportExpectation, secondReportExpectation ] timeout:kTimeoutInSeconds];

    clearExpectation = [self expectationWithDescription:@"report handlers deregistered"];
    [device deregisterReportHandlersWithClientQueue:queue
                                         completion:^{
                                             [clearExpectation fulfill];
                                         }];
    [self waitForExpectations:@[ clearExpectation ] timeout:kTimeoutInSeconds];
}

- (void)test013_TimedWriteAttribute
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    // Write an initial value
    NSDictionary * writeValue = [NSDictionary
        dictionaryWithObjectsAndKeys:@"UnsignedInteger", @"type", [NSNumber numberWithUnsignedInteger:200], @"value", nil];
    XCTestExpectation * expectation = [self expectationWithDescription:@"Wrote LevelControl Brightness attribute"];
    [device writeAttributeWithEndpointId:@1
                               clusterId:@8
                             attributeId:@17
                                   value:writeValue
                       timedWriteTimeout:nil
                             clientQueue:queue
                              completion:^(id _Nullable values, NSError * _Nullable error) {
                                  NSLog(@"write attribute: Brightness values: %@, error: %@", values, error);

                                  XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                  {
                                      XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                      NSArray * resultArray = values;
                                      for (NSDictionary * result in resultArray) {
                                          CHIPAttributePath * path = result[@"attributePath"];
                                          XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                          XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
                                          XCTAssertEqual([path.attribute unsignedIntegerValue], 17);
                                          XCTAssertNil(result[@"error"]);
                                      }
                                      XCTAssertEqual([resultArray count], 1);
                                  }

                                  [expectation fulfill];
                              }];
    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];

    // Request a timed write with a new value
    writeValue = [NSDictionary
        dictionaryWithObjectsAndKeys:@"UnsignedInteger", @"type", [NSNumber numberWithUnsignedInteger:100], @"value", nil];
    expectation = [self expectationWithDescription:@"Requested timed write on LevelControl Brightness attribute"];
    [device writeAttributeWithEndpointId:@1
                               clusterId:@8
                             attributeId:@17
                                   value:writeValue
                       timedWriteTimeout:@1000
                             clientQueue:queue
                              completion:^(id _Nullable values, NSError * _Nullable error) {
                                  NSLog(@"Timed-write attribute: Brightness values: %@, error: %@", values, error);

                                  XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                  {
                                      XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                      NSArray * resultArray = values;
                                      for (NSDictionary * result in resultArray) {
                                          CHIPAttributePath * path = result[@"attributePath"];
                                          XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                          XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
                                          XCTAssertEqual([path.attribute unsignedIntegerValue], 17);
                                          XCTAssertNil(result[@"error"]);
                                      }
                                      XCTAssertEqual([resultArray count], 1);
                                  }

                                  [expectation fulfill];
                              }];
    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];

#if 0 // The above attribute isn't for timed interaction. Hence, no verification till we have a capable attribute.
    // subscribe, which should get the new value at the timeout
    expectation = [self expectationWithDescription:@"Subscribed"];
    __block void (^reportHandler)(id _Nullable values, NSError * _Nullable error);
    [device subscribeAttributeWithEndpointId:@1
        clusterId:@8
        attributeId:@17
        minInterval:@2
        maxInterval:@10
        params:nil
        clientQueue:queue
        reportHandler:^(id _Nullable value, NSError * _Nullable error) {
            NSLog(@"report attribute: Brightness values: %@, error: %@", value, error);

            if (reportHandler) {
                __auto_type callback = reportHandler;
                callback = nil;
                callback(value, error);
            }
        }
        subscriptionEstablished:^{
            NSLog(@"subscribe attribute: Brightness established");
            [expectation fulfill];
        }];
    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];

    // Setup report expectation
    expectation = [self expectationWithDescription:@"Report received"];
    reportHandler = ^(id _Nullable values, NSError * _Nullable error) {
        XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);
        XCTAssertTrue([values isKindOfClass:[NSArray class]]);
        NSDictionary * result = values[0];
        CHIPAttributePath * path = result[@"attributePath"];
        XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
        XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
        XCTAssertEqual([path.attribute unsignedIntegerValue], 17);
        XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
        XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"UnsignedInteger"]);
        XCTAssertEqual([result[@"data"][@"value"] unsignedIntegerValue], 100);
        [expectation fulfill];
    };
    // Wait for report
    [self waitForExpectationsWithTimeout:(kTimeoutInSeconds + 1) handler:nil];
#endif

    // Read back to see if the timed write has taken effect
    expectation = [self expectationWithDescription:@"Read LevelControl Brightness attribute after pause"];
    [device readAttributeWithEndpointId:@1
                              clusterId:@8
                            attributeId:@17
                                 params:nil
                            clientQueue:queue
                             completion:^(NSArray<NSDictionary<NSString *, id> *> * _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"read attribute: LevelControl Brightness values: %@, error: %@", values, error);
                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);
                                 for (NSDictionary<NSString *, id> * value in values) {
                                     CHIPAttributePath * path = value[@"attributePath"];
                                     XCTAssertEqual([path.endpoint unsignedShortValue], 1);
                                     XCTAssertEqual([path.cluster unsignedLongValue], 8);
                                     XCTAssertEqual([path.attribute unsignedLongValue], 17);
                                     XCTAssertTrue([value[@"data"][@"type"] isEqualToString:@"UnsignedInteger"]);
                                     XCTAssertEqual([value[@"data"][@"value"] unsignedIntegerValue], 100);
                                 }
                                 [expectation fulfill];
                             }];
    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
}

- (void)test014_TimedInvokeCommand
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"invoke MoveToLevelWithOnOff command"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    NSDictionary * fields = @{
        @"type" : @"Structure",
        @"value" : @[
            @{ @"contextTag" : @0, @"data" : @ { @"type" : @"UnsignedInteger", @"value" : @0 } },
            @{ @"contextTag" : @1, @"data" : @ { @"type" : @"UnsignedInteger", @"value" : @10 } }
        ]
    };
    [device invokeCommandWithEndpointId:@1
                              clusterId:@8
                              commandId:@4
                          commandFields:fields
                     timedInvokeTimeout:@1000
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoke command: MoveToLevelWithOnOff values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 8);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 4);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }

                                 [expectation fulfill];
                             }];

    [self waitForExpectationsWithTimeout:kTimeoutInSeconds handler:nil];
    sleep(1);
}

- (void)test900_SubscribeAttributeCache
{
#if MANUAL_INDIVIDUAL_TEST
    [self initStack];
    [self waitForCommissionee];
#endif
    XCTestExpectation * expectation = [self expectationWithDescription:@"subscribe attributes by cache"];

    CHIPDevice * device = GetConnectedDevice();
    dispatch_queue_t queue = dispatch_get_main_queue();

    __auto_type * deviceController = GetDeviceController();
    CHIPAttributeCacheContainer * attributeCacheContainer = [[CHIPAttributeCacheContainer alloc] init];
    NSLog(@"Setting up attribute cache...");
    [attributeCacheContainer subscribeWithDeviceController:deviceController
                                                  deviceId:kDeviceId
                                                    params:nil
                                               clientQueue:queue
                                                completion:^(NSError * _Nullable error) {
                                                    NSLog(@"Attribute cache subscribed attributes");
                                                    [expectation fulfill];
                                                }];
    [self waitForExpectations:@[ expectation ] timeout:kTimeoutInSeconds];

    // Wait for initial report to be collected. This can take very long.
    NSLog(@"Waiting for initial report...");
    expectation = [self expectationWithDescription:@"Must not jump out while waiting for initial report"];
    expectation.inverted = YES;
    [self waitForExpectations:@[ expectation ] timeout:120];

    // Send command to reset attribute state
    NSLog(@"Invoking clearing command...");
    expectation = [self expectationWithDescription:@"Clearing command invoked"];
    NSDictionary * fields = [NSDictionary dictionaryWithObjectsAndKeys:@"Structure", @"type", [NSArray array], @"value", nil];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@0
                          commandFields:fields
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoked command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 0);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                                 [expectation fulfill];
                             }];
    [self waitForExpectations:@[ expectation ] timeout:kTimeoutInSeconds];

    // Send command to trigger attribute change
    NSLog(@"Invoking command to trigger report...");
    expectation = [self expectationWithDescription:@"Command invoked"];
    fields = [NSDictionary dictionaryWithObjectsAndKeys:@"Structure", @"type", [NSArray array], @"value", nil];
    [device invokeCommandWithEndpointId:@1
                              clusterId:@6
                              commandId:@1
                          commandFields:fields
                     timedInvokeTimeout:nil
                            clientQueue:queue
                             completion:^(id _Nullable values, NSError * _Nullable error) {
                                 NSLog(@"invoked command: On values: %@, error: %@", values, error);

                                 XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);

                                 {
                                     XCTAssertTrue([values isKindOfClass:[NSArray class]]);
                                     NSArray * resultArray = values;
                                     for (NSDictionary * result in resultArray) {
                                         CHIPCommandPath * path = result[@"commandPath"];
                                         XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                         XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                         XCTAssertEqual([path.command unsignedIntegerValue], 1);
                                         XCTAssertNil(result[@"error"]);
                                     }
                                     XCTAssertEqual([resultArray count], 1);
                                 }
                                 [expectation fulfill];
                             }];
    [self waitForExpectations:@[ expectation ] timeout:kTimeoutInSeconds];

    // Read attribute cache
    sleep(1);
    NSLog(@"Reading from attribute cache...");
    expectation = [self expectationWithDescription:@"Cache read"];
    [attributeCacheContainer
        readAttributeWithEndpointId:@1
                          clusterId:@6
                        attributeId:@0
                        clientQueue:queue
                         completion:^(NSArray<NSDictionary<NSString *, id> *> * _Nullable values, NSError * _Nullable error) {
                             NSLog(@"Cached attribute read: %@, error: %@", values, error);
                             XCTAssertEqual([CHIPErrorTestUtils errorToZCLErrorCode:error], 0);
                             XCTAssertEqual([values count], 1);
                             for (NSDictionary<NSString *, id> * value in values) {
                                 XCTAssertTrue([value isKindOfClass:[NSDictionary class]]);
                                 NSDictionary * result = value;
                                 CHIPAttributePath * path = result[@"attributePath"];
                                 XCTAssertEqual([path.endpoint unsignedIntegerValue], 1);
                                 XCTAssertEqual([path.cluster unsignedIntegerValue], 6);
                                 XCTAssertEqual([path.attribute unsignedIntegerValue], 0);
                                 XCTAssertTrue([result[@"data"] isKindOfClass:[NSDictionary class]]);
                                 XCTAssertTrue([result[@"data"][@"type"] isEqualToString:@"Boolean"]);
                                 XCTAssertEqual([result[@"data"][@"value"] boolValue], YES);
                             }
                             [expectation fulfill];
                         }];
    [self waitForExpectations:@[ expectation ] timeout:kTimeoutInSeconds];
}

#if !MANUAL_INDIVIDUAL_TEST
- (void)test999_TearDown
{
    [self shutdownStack];
}
#endif

@end