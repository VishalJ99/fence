//
//  PacketFilter.m
//  SelfControl
//
//  Created by Charles Stigler on 6/29/14.
//
//

#import "PacketFilter.h"
#import "SCDebugUtilities.h"

NSString* const kPfctlExecutablePath = @"/sbin/pfctl";
NSString* const kPFConfPath = @"/etc/pf.conf";
NSString* const kPFAnchorCommand = @"anchor \"org.eyebeam\"";
NSString* const kPFAnchorConfigurationPath = @"/etc/pf.anchors/org.eyebeam";
NSErrorDomain const SCPacketFilterErrorDomain = @"SCPacketFilterErrorDomain";

@interface PacketFilter ()

@property (nonatomic, strong) NSFileHandle* appendFileHandle;
@property (nonatomic, readwrite) BOOL lastAnchorOpenSucceeded;
@property (nonatomic, readwrite) BOOL lastConfigurationWriteSucceeded;
@property (nonatomic, readwrite) BOOL lastMainConfigurationWriteSucceeded;
@property (nonatomic, readwrite) NSInteger lastCommandExitCode;
@property (nonatomic, readwrite) BOOL lastVerificationSucceeded;
@property (nonatomic, strong, readwrite) NSError* lastApplyError;

@end

@implementation PacketFilter

+ (BOOL)blockFoundInPF {
    // Check if actual PF rules are loaded in our anchor (not just config file presence)
    // Run: pfctl -a org.eyebeam -sr 2>/dev/null
    // If there's any output, rules are active
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = kPfctlExecutablePath;
    task.arguments = @[@"-a", @"org.eyebeam", @"-sr"];

    NSPipe* outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    // Only stdout contains rules. pfctl can emit benign platform warnings on
    // stderr even when the anchor is empty, so stderr must not count as a block.
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    @try {
        [task launch];
        NSData* outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        NSString* output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

        // Require pfctl success so an error message cannot masquerade as rules.
        if (task.terminationStatus == 0 && output &&
            [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0) {
            return YES;
        }
    } @catch (NSException* exception) {
        // If pfctl fails, fall back to config file check
        NSString* pfConfContents = [NSString stringWithContentsOfFile: kPFConfPath encoding: NSUTF8StringEncoding error: NULL];
        if(pfConfContents != nil && [pfConfContents rangeOfString: kPFAnchorCommand].location != NSNotFound) {
            return YES;
        }
    }

    return NO;
}

- (PacketFilter*)initAsAllowlist: (BOOL)allowlist {
	if (self = [super init]) {
		isAllowlist = allowlist;
		rules = [NSMutableString stringWithCapacity: 1000];
        _lastCommandExitCode = -1;
	}
	return self;
}

- (void)addBlockHeader:(NSMutableString*)configText {
	[configText appendString: @"# Options\n"
	 "set block-policy drop\n"
	 "set fingerprints \"/etc/pf.os\"\n"
	 "set ruleset-optimization basic\n"
	 "set skip on lo0\n"
	 "\n"
	 "#\n"
	 "# org.eyebeam ruleset for SelfControl blocks\n"
	 "#\n"];

	if (isAllowlist) {
		[configText appendString: @"block return out proto tcp from any to any\n"
		 "block return out proto udp from any to any\n"
		 "\n"];
	}
}
- (void)addAllowlistFooter:(NSMutableString*)configText {
	[configText appendString: @"pass out proto tcp from any to any port 53\n"];
	[configText appendString: @"pass out proto udp from any to any port 53\n"];
	[configText appendString: @"pass out proto udp from any to any port 123\n"];
	[configText appendString: @"pass out proto udp from any to any port 67\n"];
	[configText appendString: @"pass out proto tcp from any to any port 67\n"];
	[configText appendString: @"pass out proto udp from any to any port 68\n"];
	[configText appendString: @"pass out proto tcp from any to any port 68\n"];
	[configText appendString: @"pass out proto udp from any to any port 5353\n"];
	[configText appendString: @"pass out proto tcp from any to any port 5353\n"];
}

- (NSArray<NSString*>*)ruleStringsForIP:(NSString*)ip port:(NSInteger)port maskLen:(NSInteger)maskLen {
    NSMutableString* rule = [NSMutableString stringWithString: @"from any to "];

    if (ip) {
        [rule appendString: ip];
    } else {
        [rule appendString: @"any"];
    }

    if (maskLen) {
        [rule appendString: [NSString stringWithFormat: @"/%ld", (long)maskLen]];
    }

    if (port) {
        [rule appendString: [NSString stringWithFormat: @" port %ld", (long)port]];
    }

    if (isAllowlist) {
        return @[
            [NSString stringWithFormat: @"pass out proto tcp %@\n", rule],
            [NSString stringWithFormat: @"pass out proto udp %@\n", rule]
        ];
    } else {
        return @[
            [NSString stringWithFormat: @"block return out proto tcp %@\n", rule],
            [NSString stringWithFormat: @"block return out proto udp %@\n", rule]
        ];
    }
}
- (void)addRuleWithIP:(NSString*)ip port:(NSInteger)port maskLen:(NSInteger)maskLen {
    @synchronized(self) {
        NSArray<NSString*>* ruleStrings = [self ruleStringsForIP: ip port: port maskLen: maskLen];
        for (NSString* ruleString in ruleStrings) {
            if (self.appendFileHandle) {
                @try {
                    [self.appendFileHandle writeData:[ruleString dataUsingEncoding:NSUTF8StringEncoding]];
                } @catch (NSException* exception) {
                    self.lastConfigurationWriteSucceeded = NO;
                    if (self.lastApplyError == nil) {
                        self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                                  code:SCPacketFilterErrorAnchorWriteFailed
                                                              userInfo:nil];
                    }
                    NSLog(@"ERROR: Failed writing appended PF rule");
                }
            } else {
                [rules appendString: ruleString];
            }
        }
    }
}

- (BOOL)writeConfiguration {
	NSMutableString* filterConfiguration = [NSMutableString stringWithCapacity: 1000];

	[self addBlockHeader: filterConfiguration];
	[filterConfiguration appendString: rules];

	if (isAllowlist) {
		[self addAllowlistFooter: filterConfiguration];
	}

	NSError* writeError = nil;
	BOOL success = [filterConfiguration writeToFile:kPFAnchorConfigurationPath
                                          atomically:YES
                                            encoding:NSUTF8StringEncoding
                                               error:&writeError];
    self.lastConfigurationWriteSucceeded = success;
    if (!success && self.lastApplyError == nil) {
        self.lastApplyError = writeError ?: [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                             code:SCPacketFilterErrorAnchorWriteFailed
                                                         userInfo:nil];
    }
    return success;
}

- (BOOL)enterAppendMode {
    self.lastApplyError = nil;
    self.lastAnchorOpenSucceeded = NO;
    self.lastConfigurationWriteSucceeded = NO;
    self.lastMainConfigurationWriteSucceeded = NO;
    self.lastCommandExitCode = -1;
    self.lastVerificationSucceeded = NO;

    if (isAllowlist) {
        NSLog(@"WARNING: Can't append rules to allowlist blocks - ignoring");
        return NO;
    }

    // open the file and prepare to write to the very bottom (no footer since it's not an allowlist)
    self.appendFileHandle = [NSFileHandle fileHandleForWritingAtPath:kPFAnchorConfigurationPath];
    if (!self.appendFileHandle) {
        self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                  code:SCPacketFilterErrorAnchorUnavailable
                                              userInfo:nil];
        NSLog(@"ERROR: Failed to get handle for pf.anchors file while attempting to append rules");
        return NO;
    }

    @try {
        [self.appendFileHandle seekToEndOfFile];
        self.lastAnchorOpenSucceeded = YES;
        self.lastConfigurationWriteSucceeded = YES;
        return YES;
    } @catch (NSException* exception) {
        self.appendFileHandle = nil;
        self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                  code:SCPacketFilterErrorAnchorUnavailable
                                              userInfo:nil];
        return NO;
    }
}
- (BOOL)finishAppending {
    if (!self.appendFileHandle) {
        self.lastConfigurationWriteSucceeded = NO;
        if (self.lastApplyError == nil) {
            self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                      code:SCPacketFilterErrorAnchorUnavailable
                                                  userInfo:nil];
        }
        return NO;
    }

    @try {
        [self.appendFileHandle synchronizeFile];
        [self.appendFileHandle closeFile];
        self.appendFileHandle = nil;
        return self.lastConfigurationWriteSucceeded;
    } @catch (NSException* exception) {
        self.appendFileHandle = nil;
        self.lastConfigurationWriteSucceeded = NO;
        if (self.lastApplyError == nil) {
            self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                      code:SCPacketFilterErrorAnchorWriteFailed
                                                  userInfo:nil];
        }
        return NO;
    }
}

- (void)appendRulesToCurrentBlockConfiguration:(NSArray<NSDictionary*>*)newEntryDicts {
    if (newEntryDicts.count < 1) return;
    if (isAllowlist) {
        NSLog(@"WARNING: Can't append rules to allowlist blocks - ignoring");
        return;
    }

    // open the file and prepare to write to the very bottom (no footer since it's not an allowlist)
    // NOTE FOR FUTURE: NSFileHandle can't append lines to the middle of the file anyway,
    // would need to read in the whole thing + write out again
    NSFileHandle* fileHandle = [NSFileHandle fileHandleForWritingAtPath: @"/etc/pf.anchors/org.eyebeam"];
    if (!fileHandle) {
        NSLog(@"ERROR: Failed to get handle for pf.anchors file while attempting to append rules");
        return;
    }

    [fileHandle seekToEndOfFile];
    for (NSDictionary* entryHostInfo in newEntryDicts) {
        NSString* hostName = entryHostInfo[@"hostName"];
        int portNum = [entryHostInfo[@"port"] intValue];
        int maskLen = [entryHostInfo[@"maskLen"] intValue];

        NSArray<NSString*>* ruleStrings = [self ruleStringsForIP: hostName port: portNum maskLen: maskLen];
        for (NSString* ruleString in ruleStrings) {
            [fileHandle writeData: [ruleString dataUsingEncoding:NSUTF8StringEncoding]];
        }
    }
    [fileHandle closeFile];
}

- (BOOL)anchorConfigurationContainsRules {
    NSError* readError = nil;
    NSString* anchorContents = [NSString stringWithContentsOfFile:kPFAnchorConfigurationPath
                                                          encoding:NSUTF8StringEncoding
                                                             error:&readError];
    if (anchorContents == nil) {
        if (self.lastApplyError == nil) {
            self.lastApplyError = readError ?: [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                                    code:SCPacketFilterErrorAnchorUnavailable
                                                                userInfo:nil];
        }
        return NO;
    }

    for (NSString* line in [anchorContents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"block "] || [trimmed hasPrefix:@"pass "]) return YES;
    }
    return NO;
}

- (BOOL)verifyStartedConfiguration {
    if (![self containsSelfControlBlock]) return NO;
    if (![[NSFileManager defaultManager] isReadableFileAtPath:kPFAnchorConfigurationPath]) return NO;

    // An app-only block intentionally has an empty PF anchor. In that case the
    // successfully-loaded main configuration is the expected physical state.
    BOOL expectsLoadedRules = [self anchorConfigurationContainsRules];
    return !expectsLoadedRules || [PacketFilter blockFoundInPF];
}

- (int)startBlock {
    self.lastApplyError = nil;
    self.lastAnchorOpenSucceeded = NO;
    self.lastConfigurationWriteSucceeded = NO;
    self.lastMainConfigurationWriteSucceeded = NO;
    self.lastCommandExitCode = -1;
    self.lastVerificationSucceeded = NO;

#ifdef DEBUG
    // Check debug override - if blocking is disabled, skip PF configuration
    if ([SCDebugUtilities isDebugBlockingDisabled]) {
        NSLog(@"DEBUG: Skipping PF block activation - debug override enabled");
        self.lastCommandExitCode = 0;
        self.lastVerificationSucceeded = YES;
        return 0;
    }
#endif

	BOOL mainConfigurationWritten = [self addSelfControlConfig];
	BOOL anchorConfigurationWritten = [self writeConfiguration];
    if (!mainConfigurationWritten || !anchorConfigurationWritten) {
        return -1;
    }

	NSArray* args = [@"-E -f /etc/pf.conf -F states" componentsSeparatedByString: @" "];

	NSTask* task = [[NSTask alloc] init];
	[task setLaunchPath: kPfctlExecutablePath];
	[task setArguments: args];

	NSPipe* inPipe = [[NSPipe alloc] init];
	NSFileHandle* readHandle = [inPipe fileHandleForReading];
	[task setStandardOutput: inPipe];
	[task setStandardError: inPipe];

	NSString* pfctlOutput = @"";
    @try {
        [task launch];
        pfctlOutput = [[NSString alloc] initWithData:[readHandle readDataToEndOfFile]
                                           encoding:NSUTF8StringEncoding] ?: @"";
        [readHandle closeFile];
        [task waitUntilExit];
        self.lastCommandExitCode = [task terminationStatus];
    } @catch (NSException* exception) {
        self.lastCommandExitCode = -1;
        if (self.lastApplyError == nil) {
            self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                      code:SCPacketFilterErrorCommandLaunchFailed
                                                  userInfo:nil];
        }
        return -1;
    }

	NSArray* lines = [pfctlOutput componentsSeparatedByString: @"\n"];
	for (NSString* line in lines) {
		if ([line hasPrefix: @"Token : "]) {
			[self writePFToken: [line substringFromIndex: [@"Token : " length]] error: nil];
			break;
		}
	}

	self.lastVerificationSucceeded = (self.lastCommandExitCode == 0) && [self verifyStartedConfiguration];
    if (!self.lastVerificationSucceeded && self.lastApplyError == nil) {
        self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                  code:SCPacketFilterErrorCommandVerificationFailed
                                              userInfo:nil];
    }

	return (int)self.lastCommandExitCode;
}
- (int)refreshPFRules {
    NSArray* args = [@"-f /etc/pf.conf -F states" componentsSeparatedByString: @" "];

    NSTask* task = [[NSTask alloc] init];
    [task setLaunchPath: kPfctlExecutablePath];
    [task setArguments: args];
    @try {
        [task launch];
        [task waitUntilExit];
        self.lastCommandExitCode = [task terminationStatus];
    } @catch (NSException* exception) {
        self.lastCommandExitCode = -1;
        if (self.lastApplyError == nil) {
            self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                      code:SCPacketFilterErrorCommandLaunchFailed
                                                  userInfo:nil];
        }
        self.lastVerificationSucceeded = NO;
        return -1;
    }

    self.lastVerificationSucceeded = (self.lastCommandExitCode == 0) && [self verifyStartedConfiguration];
    if (!self.lastVerificationSucceeded && self.lastApplyError == nil) {
        self.lastApplyError = [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                  code:SCPacketFilterErrorCommandVerificationFailed
                                              userInfo:nil];
    }

    return (int)self.lastCommandExitCode;
}

- (void)writePFToken:(NSString*)token error:(NSError**)error {
	[token writeToFile: @"/etc/SelfControlPFToken" atomically: YES encoding: NSUTF8StringEncoding error: error];
}
- (NSString*)readPFToken:(NSError**)error {
	return [NSString stringWithContentsOfFile: @"/etc/SelfControlPFToken" encoding: NSUTF8StringEncoding error: error];
}

- (int)stopBlock:(BOOL)force {
	NSError* err;
	NSString* token = [self readPFToken: &err];

	[@"" writeToFile: @"/etc/pf.anchors/org.eyebeam" atomically: true encoding: NSUTF8StringEncoding error: nil];

	// Flush anchor rules from kernel memory
	NSTask* flushTask = [NSTask launchedTaskWithLaunchPath: kPfctlExecutablePath
	                                             arguments: @[@"-a", @"org.eyebeam", @"-F", @"all"]];
	[flushTask waitUntilExit];

	NSString* mainConf = [NSString stringWithContentsOfFile: @"/etc/pf.conf" encoding: NSUTF8StringEncoding error: nil];
	NSArray* lines = [mainConf componentsSeparatedByString: @"\n"];
	NSMutableString* newConf = [NSMutableString stringWithCapacity: [mainConf length]];
	for (NSString* line in lines) {
		if ([line rangeOfString: @"org.eyebeam"].location == NSNotFound) {
			[newConf appendFormat: @"%@\n", line];
		}
	}
	newConf = [[newConf stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]] mutableCopy];
	[newConf appendString: @"\n"];
	[newConf writeToFile: @"/etc/pf.conf" atomically: true encoding: NSUTF8StringEncoding error: nil];

	NSString* commandString;
	if ([token length] && !force) {
		commandString = [NSString stringWithFormat: @"-X %@ -f /etc/pf.conf", token];
	} else {
		commandString = @"-d -f /etc/pf.conf";
	}
	NSArray* args = [commandString componentsSeparatedByString: @" "];

	NSTask* task = [NSTask launchedTaskWithLaunchPath: kPfctlExecutablePath arguments: args];
	[task waitUntilExit];
	return [task terminationStatus];
}

- (BOOL)addSelfControlConfig {
    NSError* readError = nil;
	NSMutableString* pfConf = [NSMutableString stringWithContentsOfFile:kPFConfPath
                                                              encoding:NSUTF8StringEncoding
                                                                 error:&readError];
    if (pfConf == nil) {
        self.lastMainConfigurationWriteSucceeded = NO;
        if (self.lastApplyError == nil) {
            self.lastApplyError = readError ?: [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                                code:SCPacketFilterErrorMainConfigurationUnavailable
                                                            userInfo:nil];
        }
        return NO;
    }

	if ([pfConf rangeOfString: @"/etc/pf.anchors/org.eyebeam"].location == NSNotFound) {
		[pfConf appendString: @"\n"
		 "anchor \"org.eyebeam\"\n"
		 "load anchor \"org.eyebeam\" from \"/etc/pf.anchors/org.eyebeam\"\n"];
	}

	NSError* writeError = nil;
    BOOL success = [pfConf writeToFile:kPFConfPath
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:&writeError];
    self.lastMainConfigurationWriteSucceeded = success;
    if (!success && self.lastApplyError == nil) {
        self.lastApplyError = writeError ?: [NSError errorWithDomain:SCPacketFilterErrorDomain
                                                             code:SCPacketFilterErrorMainConfigurationUnavailable
                                                         userInfo:nil];
    }
    return success;
}

- (BOOL)containsSelfControlBlock {
	NSString* mainConf = [NSString stringWithContentsOfFile: @"/etc/pf.conf" encoding: NSUTF8StringEncoding error: nil];
	return mainConf != nil && [mainConf rangeOfString: @"org.eyebeam"].location != NSNotFound;
}

@end
