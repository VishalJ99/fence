//
//  HostFileBlockerSet.m
//  SelfControl
//
//  Created by Charlie Stigler on 3/7/21.
//

#import "HostFileBlockerSet.h"

@implementation HostFileBlockerSet

- (instancetype)init {
    return [self initWithCommonFiles];
}
- (instancetype)initWithCommonFiles {
    NSFileManager* fileMan = [NSFileManager defaultManager];
    NSArray<NSString*>* commonBackupHostFilePaths = @[
        // Juniper Pulse
        @"/etc/pulse-hosts.bak",
        @"/etc/jnpr-pulse-hosts.bak",
        @"/etc/pulse.hosts.bak",
        @"/etc/jnpr-nc-hosts.bak",
        
        // Cisco AnyConnect
        @"/etc/hosts.ac"
    ];
    
    NSMutableArray* hostFileBlockers = [NSMutableArray arrayWithCapacity: commonBackupHostFilePaths.count + 1];
    
    _defaultBlocker = [HostFileBlocker new];
    [hostFileBlockers addObject: _defaultBlocker];
    
    for (NSString* path in commonBackupHostFilePaths) {
        if ([fileMan isReadableFileAtPath: path]) {
            NSLog(@"INFO: found backup VPN host file at %@", path);
            HostFileBlocker* blocker = [[HostFileBlocker alloc] initWithPath: path];
            [hostFileBlockers addObject: blocker];
        }
    }
    
    _blockers = hostFileBlockers;
    
    return self;
}

- (BOOL)deleteBackupHostsFile {
    BOOL ret = YES;
    for (HostFileBlocker* blocker in self.blockers) {
        BOOL blockerSucceeded = [blocker deleteBackupHostsFile];
        ret = blockerSucceeded && ret;
    }
    return ret;
}

- (void)revertFileContentsToDisk {
    for (HostFileBlocker* blocker in self.blockers) {
        [blocker revertFileContentsToDisk];
    }
}

- (BOOL)writeNewFileContents {
    return [self writeNewFileContentsWithError:NULL];
}

- (BOOL)writeNewFileContentsWithError:(NSError**)error {
    BOOL ret = YES;
    NSError* firstError = nil;
    for (HostFileBlocker* blocker in self.blockers) {
        NSError* blockerError = nil;
        BOOL blockerSucceeded = [blocker writeNewFileContentsWithError:&blockerError];
        if (!blockerSucceeded && firstError == nil) firstError = blockerError;
        ret = blockerSucceeded && ret;
    }
    if (error) *error = firstError;
    return ret;
}

- (BOOL)verifyNewFileContentsWithError:(NSError**)error {
    BOOL ret = YES;
    NSError* firstError = nil;
    for (HostFileBlocker* blocker in self.blockers) {
        NSError* blockerError = nil;
        BOOL blockerSucceeded = [blocker verifyNewFileContentsWithError:&blockerError];
        if (!blockerSucceeded && firstError == nil) firstError = blockerError;
        ret = blockerSucceeded && ret;
    }
    if (error) *error = firstError;
    return ret;
}

- (void)addSelfControlBlockHeader {
    for (HostFileBlocker* blocker in self.blockers) {
        [blocker addSelfControlBlockHeader];
    }
}

- (void)addSelfControlBlockFooter {
    for (HostFileBlocker* blocker in self.blockers) {
        [blocker addSelfControlBlockFooter];
    }
}

- (BOOL)createBackupHostsFile {
    return [self createBackupHostsFileWithError:NULL];
}

- (BOOL)createBackupHostsFileWithError:(NSError**)error {
    BOOL ret = YES;
    NSError* firstError = nil;
    for (HostFileBlocker* blocker in self.blockers) {
        NSError* blockerError = nil;
        BOOL blockerSucceeded = [blocker createBackupHostsFileWithError:&blockerError];
        if (!blockerSucceeded && firstError == nil) firstError = blockerError;
        ret = blockerSucceeded && ret;
    }
    if (error) *error = firstError;
    return ret;
}

- (BOOL)restoreBackupHostsFile {
    BOOL ret = YES;
    for (HostFileBlocker* blocker in self.blockers) {
        BOOL blockerSucceeded = [blocker restoreBackupHostsFile];
        ret = blockerSucceeded && ret;
    }
    return ret;
}

- (void)addRuleBlockingDomain:(NSString*)domainName {
    for (HostFileBlocker* blocker in self.blockers) {
        [blocker addRuleBlockingDomain: domainName];
    }
}
- (BOOL)appendExistingBlockWithRuleForDomain:(NSString*)domainName {
    BOOL ret = YES;
    for (HostFileBlocker* blocker in self.blockers) {
        BOOL blockerSucceeded = [blocker appendExistingBlockWithRuleForDomain:domainName];
        ret = blockerSucceeded && ret;
    }
    return ret;
}

- (BOOL)containsSelfControlBlock {
    BOOL ret = NO;
    for (HostFileBlocker* blocker in self.blockers) {
        ret = ret || [blocker containsSelfControlBlock];
    }
    return ret;
}

- (BOOL)containsCompleteSelfControlBlock {
    BOOL ret = NO;
    for (HostFileBlocker* blocker in self.blockers) {
        ret = [blocker containsCompleteSelfControlBlock] || ret;
    }
    return ret;
}

- (void)removeSelfControlBlock {
    for (HostFileBlocker* blocker in self.blockers) {
        [blocker removeSelfControlBlock];
    }
}

@end
