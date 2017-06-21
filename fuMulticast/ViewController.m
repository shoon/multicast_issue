//
//  ViewController.m
//  fuMulticast
//
//  Created by Michael Davidson on 6/21/17.
//  Copyright © 2017 SNDR. All rights reserved.
//

#import "ViewController.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <stdio.h>      /* for printf() and fprintf() */
#include <stdlib.h>     /* for atoi() and exit() */
#include <string.h>     /* for memset() */
#include <time.h>       /* for timestamps */
#include <unistd.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>

#define IOS_CELLULAR    @"pdp_ip0"
#define IOS_WIFI        @"en0"
#define IOS_VPN         @"utun0"
#define IP_ADDR_IPv4    @"ipv4"
#define IP_ADDR_IPv6    @"ipv6"
@interface ViewController ()

@property (strong, nonatomic) NSMutableDictionary *interfaceScope;
@property (weak, nonatomic) IBOutlet UITextView *textView;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    self.interfaceScope = [NSMutableDictionary new];
    NSDictionary *dic = [self getIPAddresses];
    NSLog(@"%@", dic.debugDescription);
    [self.textView setScrollEnabled:YES];
   runOnNewBgThread(^{
       [self start];
   });
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void) DieWithError:(NSString *) errorMessage
{
    NSLog(@"%@", errorMessage);
    exit(10);
}

- (void)start
{
    int     sock;                     /* Socket */
    char*      multicastIP;              /* Arg: IP Multicast Address */
    char*      multicastPort;            /* Arg: Port */
    struct addrinfo *  multicastAddr;            /* Multicast Address */
    struct addrinfo *  localAddr;                /* Local address to bind to */
    struct addrinfo    hints          = { 0 };   /* Hints for name lookup */
    
    
    multicastIP   = "FF05::C";      /* First arg:  Multicast IP address */
    multicastPort = "1900";      /* Second arg: Multicast port */
    
    /* Resolve the multicast group address */
    hints.ai_family = PF_INET6;
    hints.ai_flags  = AI_NUMERICHOST;
    if ( getaddrinfo(multicastIP, NULL, &hints, &multicastAddr) != 0 )
    {
        [self DieWithError:@"getaddrinfo() failed"];
    }
    
    /* Get a local address with the same family as our multicast group */
    hints.ai_family   = multicastAddr->ai_family;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_flags    = AI_PASSIVE; /* Return an address we can bind to */
    if ( getaddrinfo(NULL, multicastPort, &hints, &localAddr) != 0 )
    {
        [self DieWithError:@"getaddrinfo() failed"];
    }
    
    /* Create socket for receiving datagrams */
    if ( (sock = socket(localAddr->ai_family, localAddr->ai_socktype, 0)) == -1 )
    {
        [self DieWithError:@"socket failed"];
    }
    
    const int trueValue = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (const void *) &trueValue, sizeof(trueValue));
#ifdef __APPLE__
    setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, (const void *) &trueValue, sizeof(trueValue));
#endif
    
    /* Bind to the multicast port */
    if ( bind(sock, localAddr->ai_addr, localAddr->ai_addrlen) != 0 )
    {
        [self DieWithError:@"bind failed"];
    }
    
    /* Join the multicast group.  */
    if ((multicastAddr->ai_family == PF_INET6)&&(multicastAddr->ai_addrlen == sizeof(struct sockaddr_in6)))
    {
        struct ipv6_mreq multicastRequest;  /* Multicast address join structure */
        
        /* Specify the multicast group */
        memcpy(&multicastRequest.ipv6mr_multiaddr, &((struct sockaddr_in6*)(multicastAddr->ai_addr))->sin6_addr, sizeof(multicastRequest.ipv6mr_multiaddr));
        
        /* Accept multicast from en0 */
        NSNumber *scope = [self.interfaceScope objectForKey:IOS_WIFI];
        const int scope_id = [scope intValue];
        
        multicastRequest.ipv6mr_interface = scope_id;
        
        int result = setsockopt(sock, IPPROTO_IPV6, IPV6_JOIN_GROUP, (char*) &multicastRequest, sizeof(multicastRequest));
        /* Join the multicast address */
        if (result != 0 )
        {
            int e = errno;
            [self DieWithError:@"setsockopt(IPV6_JOIN_GROUP) failed"];
        }
    }
    else
    {
        [self DieWithError:@"Not IPv6"];
    }
    
    freeaddrinfo(localAddr);
    freeaddrinfo(multicastAddr);
    
    for (;;) /* Run forever */
    {
        char   recvString[500];      /* Buffer for received string */
        int    recvStringLen;        /* Length of received string */
        
        /* Receive a single datagram from the server */
        if ((recvStringLen = (int)recvfrom(sock, recvString, sizeof(recvString) - 1, 0, NULL, 0)) < 0)
        {
            [self DieWithError:@"recvfrom() failed"];
        }
        recvString[recvStringLen] = '\0';
        
        /* Print the received string */
        printf("Received string [%s]\n", recvString);
        NSString *log = @"Received string [";
        NSString *msg = [NSString stringWithUTF8String:recvString];
        NSString *output = [NSString stringWithFormat:@"%@%@]\n", log, msg];
        runOnMainQueueAsync(^{
            [self.textView insertText:output];
            if(self.textView.text.length > 0 ) {
                NSRange bottom = NSMakeRange(self.textView.text.length -1, 1);
                [self.textView scrollRangeToVisible:bottom];
            }
        });
    }
    
    /* NOT REACHED */
    close(sock);
    exit(EXIT_SUCCESS);
}

- (NSDictionary *)getIPAddresses
{
    NSMutableDictionary *addresses = [NSMutableDictionary dictionaryWithCapacity:8];
    
    // retrieve the current interfaces - returns 0 on success
    struct ifaddrs *interfaces;
    if(!getifaddrs(&interfaces)) {
        // Loop through linked list of interfaces
        struct ifaddrs *interface;
        for(interface=interfaces; interface; interface=interface->ifa_next) {
            if(!(interface->ifa_flags & IFF_UP) /* || (interface->ifa_flags & IFF_LOOPBACK) */ ) {
                continue; // deeply nested code harder to read
            }
            const struct sockaddr_in *addr = (const struct sockaddr_in*)interface->ifa_addr;
            char addrBuf[ MAX(INET_ADDRSTRLEN, INET6_ADDRSTRLEN) ];
            if(addr && (addr->sin_family==AF_INET || addr->sin_family==AF_INET6)) {
                NSString *name = [NSString stringWithUTF8String:interface->ifa_name];
                NSString *type;
                if(addr->sin_family == AF_INET) {
                    if(inet_ntop(AF_INET, &addr->sin_addr, addrBuf, INET_ADDRSTRLEN)) {
                        type = IP_ADDR_IPv4;
                    }
                } else {
                    const struct sockaddr_in6 *addr6 = (const struct sockaddr_in6*)interface->ifa_addr;
                    if(inet_ntop(AF_INET6, &addr6->sin6_addr, addrBuf, INET6_ADDRSTRLEN)) {
                        type = IP_ADDR_IPv6;
                        if(name)
                        {
                            NSNumber *scope = [NSNumber numberWithInt:addr6->sin6_scope_id];
                            [self.interfaceScope setObject:scope forKey:name];
                        }
                    }
                }
                if(type) {
                    NSString *key = [NSString stringWithFormat:@"%@/%@", name, type];
                    addresses[key] = [NSString stringWithUTF8String:addrBuf];
                }
            }
        }
        // Free memory
        freeifaddrs(interfaces);
    }
    return [addresses count] ? addresses : nil;
}

void runOnNewBgThread(void (^block)(void)) {
    //    dispatch_async(dispatch_get_main_queue(), ^{    // Always create bg thread from main thread to prevent ARC cleaning up bg thread too early (aka __destroy_helper_block_)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
    //    });
    
}

void runOnMainQueueAsync(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}

@end
