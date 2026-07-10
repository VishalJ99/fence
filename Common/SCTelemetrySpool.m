//
//  SCTelemetrySpool.m
//  Fence
//


#import "SCTelemetrySpool.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

NSString * const SCTelemetrySpoolErrorDomain = @"org.eyebeam.Fence.TelemetrySpool";

static NSString * const SCTelemetryDefaultBaseDirectory = @"/usr/local/etc/fence-telemetry";
static NSString * const SCTelemetryConsentFilename = @"consent.json";
static NSString * const SCTelemetryEventsFilename = @"events.ndjson";
static NSString * const SCTelemetryLockFilename = @".lock";

static const NSUInteger SCTelemetrySchemaVersion = 1;
static const NSUInteger SCTelemetryMaximumRecords = 100;
static const NSUInteger SCTelemetryMaximumFetchRecords = 25;
static const NSUInteger SCTelemetryMaximumFileBytes = 256 * 1024;
static const NSUInteger SCTelemetryMaximumEventBytes = 16 * 1024;
static const NSUInteger SCTelemetryMaximumConsentBytes = 4 * 1024;
static const NSTimeInterval SCTelemetryRetentionSeconds = 14 * 24 * 60 * 60;
static const NSTimeInterval SCTelemetryMaximumFutureSkewSeconds = 5 * 60;
static NSString * const SCTelemetryZeroUUID = @"00000000-0000-0000-0000-000000000000";

static NSError *SCTelemetrySpoolError(SCTelemetrySpoolErrorCode code, NSString *description) {
    return [NSError errorWithDomain:SCTelemetrySpoolErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL SCTelemetryNumberIsInteger(NSNumber *number) {
    if (![number isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
        return NO;
    }
    double value = number.doubleValue;
    return isfinite(value) && floor(value) == value && value >= 0;
}

static NSString *SCTelemetryCanonicalNonzeroUUIDString(id candidate) {
    if (![candidate isKindOfClass:[NSString class]]) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:candidate];
    if (uuid == nil) return nil;
    NSString *canonical = uuid.UUIDString.lowercaseString;
    return [canonical isEqualToString:SCTelemetryZeroUUID] ? nil : canonical;
}

@interface SCTelemetrySpool ()

@property (nonatomic, copy, readwrite) NSString *baseDirectory;
@property (nonatomic, assign, readwrite) BOOL requiresRootOwnership;

- (BOOL)appendEventName:(NSString *)eventName
                  level:(SCTelemetryEventLevel)level
                 fields:(nullable NSDictionary<NSString *, id> *)fields
                 origin:(SCTelemetryOrigin)origin
                 forUID:(uid_t)uid
requiredConsentGeneration:(nullable NSNumber *)requiredConsentGeneration
                  error:(NSError * _Nullable * _Nullable)error;

@end

@implementation SCTelemetrySpool

- (instancetype)init {
    return [self initWithBaseDirectory:SCTelemetryDefaultBaseDirectory];
}

- (instancetype)initWithBaseDirectory:(NSString *)baseDirectory {
    self = [super init];
    if (self) {
        NSString *standardized = [baseDirectory stringByStandardizingPath];
        if (![standardized isAbsolutePath] || standardized.length <= 1) {
            return nil;
        }
        _baseDirectory = [standardized copy];
        _requiresRootOwnership = [standardized isEqualToString:SCTelemetryDefaultBaseDirectory];
    }
    return self;
}

#pragma mark - Paths and locked storage

- (BOOL)ensureProductionParentIfNeeded:(NSError **)error {
    if (!self.requiresRootOwnership) return YES;
    if (geteuid() != 0) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorUnsafePath,
                                           @"Production telemetry storage requires root");
        }
        return NO;
    }

    NSString *parent = self.baseDirectory.stringByDeletingLastPathComponent;
    struct stat status;
    if (lstat(parent.fileSystemRepresentation, &status) != 0) {
        if (errno != ENOENT ||
            (mkdir(parent.fileSystemRepresentation, 0755) != 0 && errno != EEXIST) ||
            lstat(parent.fileSystemRepresentation, &status) != 0) {
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                               @"Could not prepare the telemetry parent directory");
            }
            return NO;
        }
    }
    if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode) || status.st_uid != 0 ||
        chmod(parent.fileSystemRepresentation, 0755) != 0) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorUnsafePath,
                                           @"Telemetry parent storage is unsafe");
        }
        return NO;
    }
    return YES;
}

- (NSString *)directoryForUID:(uid_t)uid {
    return [self.baseDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", uid]];
}

- (BOOL)ensureDirectoryAtPath:(NSString *)path
              createIfMissing:(BOOL)createIfMissing
                       exists:(BOOL *)exists
                        error:(NSError **)error {
    struct stat status;
    if (lstat(path.fileSystemRepresentation, &status) != 0) {
        if (errno == ENOENT && !createIfMissing) {
            if (exists != NULL) *exists = NO;
            return YES;
        }
        if (errno != ENOENT ||
            (mkdir(path.fileSystemRepresentation, 0700) != 0 && errno != EEXIST)) {
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                               @"Could not prepare telemetry storage");
            }
            return NO;
        }
        if (lstat(path.fileSystemRepresentation, &status) != 0) {
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                               @"Could not inspect telemetry storage");
            }
            return NO;
        }
    }

    if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode) ||
        (self.requiresRootOwnership && status.st_uid != 0)) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorUnsafePath,
                                           @"Telemetry storage is not a safe directory");
        }
        return NO;
    }

    if (chmod(path.fileSystemRepresentation, 0700) != 0) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                           @"Could not secure telemetry storage permissions");
        }
        return NO;
    }

    if (exists != NULL) *exists = YES;
    return YES;
}

- (BOOL)prepareDirectoryForUID:(uid_t)uid
               createIfMissing:(BOOL)createIfMissing
                         exists:(BOOL *)exists
                           path:(NSString **)path
                          error:(NSError **)error {
    if (![self ensureProductionParentIfNeeded:error]) return NO;
    BOOL baseExists = NO;
    if (![self ensureDirectoryAtPath:self.baseDirectory
                     createIfMissing:createIfMissing
                              exists:&baseExists
                               error:error]) {
        return NO;
    }
    if (!baseExists) {
        if (exists != NULL) *exists = NO;
        return YES;
    }

    NSString *uidDirectory = [self directoryForUID:uid];
    BOOL uidDirectoryExists = NO;
    if (![self ensureDirectoryAtPath:uidDirectory
                     createIfMissing:createIfMissing
                              exists:&uidDirectoryExists
                               error:error]) {
        return NO;
    }

    if (exists != NULL) *exists = uidDirectoryExists;
    if (path != NULL) *path = uidDirectory;
    return YES;
}

- (int)openAndLockDirectory:(NSString *)directory error:(NSError **)error {
    NSString *lockPath = [directory stringByAppendingPathComponent:SCTelemetryLockFilename];
    int descriptor = open(lockPath.fileSystemRepresentation,
                          O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                          0600);
    if (descriptor < 0) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                           @"Could not open the telemetry lock");
        }
        return -1;
    }

    struct stat status;
    if (fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
        (self.requiresRootOwnership && status.st_uid != 0) ||
        fchmod(descriptor, 0600) != 0 || flock(descriptor, LOCK_EX) != 0) {
        close(descriptor);
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                           @"Could not secure the telemetry lock");
        }
        return -1;
    }
    return descriptor;
}

- (void)unlockAndCloseDescriptor:(int)descriptor {
    if (descriptor < 0) return;
    flock(descriptor, LOCK_UN);
    close(descriptor);
}

- (nullable NSData *)readFileAtPath:(NSString *)path
                       maximumBytes:(NSUInteger)maximumBytes
                              error:(NSError **)error {
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        if (errno == ENOENT) return nil;
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                           @"Could not read telemetry storage");
        }
        return nil;
    }

    struct stat status;
    if (fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
        (self.requiresRootOwnership && status.st_uid != 0) ||
        status.st_size < 0 || (uint64_t)status.st_size > maximumBytes ||
        fchmod(descriptor, 0600) != 0) {
        close(descriptor);
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                           @"Telemetry storage failed validation");
        }
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    uint8_t *cursor = data.mutableBytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t readCount = read(descriptor, cursor, remaining);
        if (readCount < 0 && errno == EINTR) continue;
        if (readCount <= 0) {
            close(descriptor);
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                               @"Could not finish reading telemetry storage");
            }
            return nil;
        }
        cursor += readCount;
        remaining -= (NSUInteger)readCount;
    }
    close(descriptor);
    return data;
}

- (BOOL)isSafelyReplaceableRegularFileAtPath:(NSString *)path {
    struct stat status;
    if (lstat(path.fileSystemRepresentation, &status) != 0) return errno == ENOENT;
    return S_ISREG(status.st_mode) && !S_ISLNK(status.st_mode) &&
        (!self.requiresRootOwnership || status.st_uid == 0);
}

- (BOOL)atomicallyWriteData:(NSData *)data
                    filename:(NSString *)filename
                   directory:(NSString *)directory
                       error:(NSError **)error {
    NSString *temporaryFilename = [NSString stringWithFormat:@".%@.%@.tmp",
                                   filename, NSUUID.UUID.UUIDString.lowercaseString];
    NSString *temporaryPath = [directory stringByAppendingPathComponent:temporaryFilename];
    NSString *destinationPath = [directory stringByAppendingPathComponent:filename];

    int descriptor = open(temporaryPath.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                          0600);
    if (descriptor < 0) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                           @"Could not create an atomic telemetry update");
        }
        return NO;
    }

    const uint8_t *cursor = data.bytes;
    NSUInteger remaining = data.length;
    BOOL succeeded = YES;
    while (remaining > 0) {
        ssize_t writeCount = write(descriptor, cursor, remaining);
        if (writeCount < 0 && errno == EINTR) continue;
        if (writeCount <= 0) {
            succeeded = NO;
            break;
        }
        cursor += writeCount;
        remaining -= (NSUInteger)writeCount;
    }

    if (succeeded && (fchmod(descriptor, 0600) != 0 || fsync(descriptor) != 0)) {
        succeeded = NO;
    }
    if (close(descriptor) != 0) succeeded = NO;
    if (succeeded && rename(temporaryPath.fileSystemRepresentation,
                            destinationPath.fileSystemRepresentation) != 0) {
        succeeded = NO;
    }
    if (!succeeded) {
        unlink(temporaryPath.fileSystemRepresentation);
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                           @"Could not commit an atomic telemetry update");
        }
        return NO;
    }
    return YES;
}

#pragma mark - Consent

- (nullable NSDictionary<NSString *, id> *)consentStateInDirectory:(NSString *)directory
                                                               error:(NSError **)error {
    NSString *path = [directory stringByAppendingPathComponent:SCTelemetryConsentFilename];
    NSError *readError = nil;
    NSData *data = [self readFileAtPath:path maximumBytes:SCTelemetryMaximumConsentBytes error:&readError];
    if (readError != nil) {
        if (error != NULL) *error = readError;
        return nil;
    }
    if (data == nil) return nil;

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorInvalidConsent,
                                           @"Telemetry consent state is invalid");
        }
        return nil;
    }

    NSDictionary *state = object;
    NSSet *expectedKeys = [NSSet setWithArray:@[@"schema_version", @"generation", @"enabled"]];
    NSNumber *schema = state[@"schema_version"];
    NSNumber *generation = state[@"generation"];
    NSNumber *enabled = state[@"enabled"];
    BOOL enabledIsBoolean = [enabled isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)enabled) == CFBooleanGetTypeID();
    if (![[NSSet setWithArray:state.allKeys] isEqualToSet:expectedKeys] ||
        !SCTelemetryNumberIsInteger(schema) || schema.unsignedIntegerValue != SCTelemetrySchemaVersion ||
        !SCTelemetryNumberIsInteger(generation) || generation.unsignedIntegerValue == 0 ||
        !enabledIsBoolean) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorInvalidConsent,
                                           @"Telemetry consent state failed validation");
        }
        return nil;
    }
    return state;
}

- (BOOL)setConsentEnabled:(BOOL)enabled
               generation:(NSUInteger)generation
                   forUID:(uid_t)uid
                    error:(NSError **)error {
    if (generation == 0) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorInvalidArgument,
                                           @"Telemetry consent requires a generation");
        }
        return NO;
    }

    BOOL exists = NO;
    NSString *directory = nil;
    if (![self prepareDirectoryForUID:uid createIfMissing:YES exists:&exists path:&directory error:error]) {
        return NO;
    }

    int lockDescriptor = [self openAndLockDirectory:directory error:error];
    if (lockDescriptor < 0) return NO;

    NSError *stateError = nil;
    NSDictionary *currentState = [self consentStateInDirectory:directory error:&stateError];
    if (stateError != nil) {
        // A corrupt/hostile marker must never prevent opt-out. Purge the event
        // entry first using unlink (which cannot follow a symlink). If the
        // marker is itself a safe-to-unlink non-directory entry, replace it
        // with a fresh disabled marker; otherwise leave the unreadable marker
        // in its fail-closed state after purging the queue.
        if (enabled) {
            [self unlockAndCloseDescriptor:lockDescriptor];
            if (error != NULL) *error = stateError;
            return NO;
        }

        NSString *eventsPath = [directory stringByAppendingPathComponent:SCTelemetryEventsFilename];
        BOOL eventsPurged = unlink(eventsPath.fileSystemRepresentation) == 0 || errno == ENOENT;
        NSString *consentPath = [directory stringByAppendingPathComponent:SCTelemetryConsentFilename];
        struct stat markerStatus;
        int markerStatResult = lstat(consentPath.fileSystemRepresentation, &markerStatus);
        BOOL markerMissing = markerStatResult != 0 && errno == ENOENT;
        BOOL markerSafeToUnlink = markerStatResult == 0 && !S_ISDIR(markerStatus.st_mode) &&
            (!self.requiresRootOwnership || markerStatus.st_uid == 0);
        BOOL markerRemoved = markerMissing ||
            (markerSafeToUnlink && (unlink(consentPath.fileSystemRepresentation) == 0 || errno == ENOENT));
        if (!markerRemoved) {
            [self unlockAndCloseDescriptor:lockDescriptor];
            if (!eventsPurged && error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                               @"Could not purge opted-out telemetry");
            } else if (error != NULL) {
                *error = nil;
            }
            return eventsPurged;
        }
        currentState = nil;
        stateError = nil;
        if (!eventsPurged) {
            [self unlockAndCloseDescriptor:lockDescriptor];
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                               @"Could not purge opted-out telemetry");
            }
            return NO;
        }
    }

    NSUInteger currentGeneration = [currentState[@"generation"] unsignedIntegerValue];
    BOOL currentEnabled = [currentState[@"enabled"] boolValue];
    if (currentState != nil && generation < currentGeneration) {
        [self unlockAndCloseDescriptor:lockDescriptor];
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorStaleConsent,
                                           @"Telemetry consent generation is stale");
        }
        return NO;
    }
    if (currentState != nil && generation == currentGeneration) {
        if (currentEnabled == enabled) {
            BOOL retrySucceeded = YES;
            if (!enabled) {
                NSString *eventsPath = [directory stringByAppendingPathComponent:SCTelemetryEventsFilename];
                if (unlink(eventsPath.fileSystemRepresentation) != 0 && errno != ENOENT) {
                    retrySucceeded = NO;
                    if (error != NULL) {
                        *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                                       @"Could not purge opted-out telemetry");
                    }
                }
            }
            [self unlockAndCloseDescriptor:lockDescriptor];
            return retrySucceeded;
        }
        if (enabled) {
            [self unlockAndCloseDescriptor:lockDescriptor];
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorStaleConsent,
                                               @"Telemetry consent generation conflicts with stored state");
            }
            return NO;
        }
        // Opt-out wins a same-generation conflict. This is fail-closed and
        // prevents a buggy/retried caller from leaving an enabled marker.
    }

    NSDictionary *newState = @{
        @"schema_version": @(SCTelemetrySchemaVersion),
        @"generation": @(generation),
        @"enabled": @(enabled),
    };
    NSData *stateData = [NSJSONSerialization dataWithJSONObject:newState options:0 error:nil];
    BOOL succeeded = [self atomicallyWriteData:stateData
                                      filename:SCTelemetryConsentFilename
                                     directory:directory
                                         error:error];
    if (!enabled) {
        if (!succeeded) {
            // If the atomic marker update failed, remove the previously
            // verified regular marker so consent becomes unknown/off. This
            // prevents a stale enabled marker from accepting new events.
            NSString *consentPath = [directory stringByAppendingPathComponent:SCTelemetryConsentFilename];
            if (unlink(consentPath.fileSystemRepresentation) == 0 || errno == ENOENT) {
                succeeded = YES;
                if (error != NULL) *error = nil;
            }
        }
        NSString *eventsPath = [directory stringByAppendingPathComponent:SCTelemetryEventsFilename];
        if (unlink(eventsPath.fileSystemRepresentation) != 0 && errno != ENOENT) {
            succeeded = NO;
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                               @"Could not purge opted-out telemetry");
            }
        }
    }

    [self unlockAndCloseDescriptor:lockDescriptor];
    return succeeded;
}

#pragma mark - Record validation and serialization

- (nullable NSString *)levelName:(SCTelemetryEventLevel)level {
    switch (level) {
        case SCTelemetryEventLevelInfo: return @"info";
        case SCTelemetryEventLevelWarning: return @"warning";
        case SCTelemetryEventLevelError: return @"error";
    }
    return nil;
}

- (nullable NSString *)originName:(SCTelemetryOrigin)origin {
    switch (origin) {
        case SCTelemetryOriginDaemon: return @"daemon";
        case SCTelemetryOriginApp: return @"app";
        case SCTelemetryOriginCLI: return @"cli";
    }
    return nil;
}

- (nullable NSDictionary<NSString *, id> *)validatedRecord:(id)object {
    if (![object isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *record = object;
    NSSet *expectedKeys = [NSSet setWithArray:@[
        @"id", @"schema_version", @"event_name", @"level", @"origin", @"created_at_ms", @"fields"
    ]];
    if (![[NSSet setWithArray:record.allKeys] isEqualToSet:expectedKeys]) return nil;

    NSString *recordID = SCTelemetryCanonicalNonzeroUUIDString(record[@"id"]);
    NSNumber *schema = record[@"schema_version"];
    NSString *eventName = record[@"event_name"];
    NSString *level = record[@"level"];
    NSString *origin = record[@"origin"];
    NSNumber *createdAt = record[@"created_at_ms"];
    NSDictionary *fields = record[@"fields"];
    if (recordID == nil ||
        !SCTelemetryNumberIsInteger(schema) || schema.unsignedIntegerValue != SCTelemetrySchemaVersion ||
        ![eventName isKindOfClass:[NSString class]] ||
        ![@[@"info", @"warning", @"error"] containsObject:level] ||
        ![@[@"daemon", @"app", @"cli"] containsObject:origin] ||
        !SCTelemetryNumberIsInteger(createdAt) ||
        ![fields isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    unsigned long long nowMilliseconds =
        (unsigned long long)floor(NSDate.date.timeIntervalSince1970 * 1000.0);
    unsigned long long maximumFutureMilliseconds =
        (unsigned long long)floor(SCTelemetryMaximumFutureSkewSeconds * 1000.0);
    if (createdAt.unsignedLongLongValue > nowMilliseconds + maximumFutureMilliseconds) {
        return nil;
    }

    NSDictionary *safeFields = [SCSentry sanitizedTelemetryFields:fields forEventName:eventName];
    if (safeFields == nil || ![safeFields isEqualToDictionary:fields]) return nil;

    NSDictionary *safeRecord = @{
        @"id": recordID,
        @"schema_version": @(SCTelemetrySchemaVersion),
        @"event_name": eventName,
        @"level": level,
        @"origin": origin,
        @"created_at_ms": createdAt,
        @"fields": safeFields,
    };
    if (![SCSentry payloadPassesTelemetryPrivacyTripwire:safeRecord]) return nil;
    return safeRecord;
}

- (NSArray<NSDictionary<NSString *, id> *> *)recordsInDirectory:(NSString *)directory
                                                            error:(NSError **)error {
    NSString *path = [directory stringByAppendingPathComponent:SCTelemetryEventsFilename];
    NSError *readError = nil;
    NSData *data = [self readFileAtPath:path maximumBytes:SCTelemetryMaximumFileBytes error:&readError];
    if (readError != nil) {
        if (error != NULL) *error = readError;
        return @[];
    }
    if (data.length == 0) return @[];

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) return @[];

    NSMutableArray<NSDictionary<NSString *, id> *> *records = [NSMutableArray array];
    unsigned long long nowMilliseconds =
        (unsigned long long)floor(NSDate.date.timeIntervalSince1970 * 1000.0);
    unsigned long long retentionMilliseconds =
        (unsigned long long)floor(SCTelemetryRetentionSeconds * 1000.0);
    unsigned long long oldestAllowed = nowMilliseconds > retentionMilliseconds
        ? nowMilliseconds - retentionMilliseconds : 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (lineData.length > SCTelemetryMaximumEventBytes) continue;
        id object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        NSDictionary *validated = [self validatedRecord:object];
        if (validated != nil && [validated[@"created_at_ms"] unsignedLongLongValue] >= oldestAllowed) {
            [records addObject:validated];
        }
    }

    if (records.count > SCTelemetryMaximumRecords) {
        return [records subarrayWithRange:NSMakeRange(records.count - SCTelemetryMaximumRecords,
                                                       SCTelemetryMaximumRecords)];
    }
    return records;
}

- (nullable NSData *)encodedRecords:(NSArray<NSDictionary<NSString *, id> *> *)records
                              error:(NSError **)error {
    NSMutableData *result = [NSMutableData data];
    for (NSDictionary *record in records) {
        NSDictionary *validated = [self validatedRecord:record];
        if (validated == nil) continue;
        NSData *line = [NSJSONSerialization dataWithJSONObject:validated options:0 error:nil];
        if (line.length == 0 || line.length > SCTelemetryMaximumEventBytes) {
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorRecordTooLarge,
                                               @"A telemetry record exceeded its size limit");
            }
            return nil;
        }
        [result appendData:line];
        [result appendBytes:"\n" length:1];
    }
    return result;
}

#pragma mark - Queue operations

- (BOOL)appendEventName:(NSString *)eventName
                  level:(SCTelemetryEventLevel)level
                 fields:(NSDictionary<NSString *,id> *)fields
                 origin:(SCTelemetryOrigin)origin
                 forUID:(uid_t)uid
       consentGeneration:(NSUInteger)consentGeneration
         consentEnabled:(BOOL)consentEnabled
                  error:(NSError **)error {
    if (!consentEnabled || consentGeneration == 0) return NO;
    return [self appendEventName:eventName
                          level:level
                         fields:fields
                         origin:origin
                         forUID:uid
      requiredConsentGeneration:@(consentGeneration)
                          error:error];
}

- (BOOL)appendEventName:(NSString *)eventName
                  level:(SCTelemetryEventLevel)level
                 fields:(NSDictionary<NSString *,id> *)fields
                 origin:(SCTelemetryOrigin)origin
                 forUID:(uid_t)uid
                  error:(NSError **)error {
    return [self appendEventName:eventName
                          level:level
                         fields:fields
                         origin:origin
                         forUID:uid
      requiredConsentGeneration:nil
                          error:error];
}

- (BOOL)appendEventName:(NSString *)eventName
                  level:(SCTelemetryEventLevel)level
                 fields:(NSDictionary<NSString *,id> *)fields
                 origin:(SCTelemetryOrigin)origin
                 forUID:(uid_t)uid
requiredConsentGeneration:(NSNumber *)requiredConsentGeneration
                  error:(NSError **)error {

    NSString *levelName = [self levelName:level];
    NSString *originName = [self originName:origin];
    NSDictionary *safeFields = [SCSentry sanitizedTelemetryFields:fields forEventName:eventName];
    if (levelName == nil || originName == nil || safeFields == nil) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorPrivacyRejected,
                                           @"Telemetry was rejected by its typed schema");
        }
        return NO;
    }

    NSDictionary *record = @{
        @"id": NSUUID.UUID.UUIDString.lowercaseString,
        @"schema_version": @(SCTelemetrySchemaVersion),
        @"event_name": eventName,
        @"level": levelName,
        @"origin": originName,
        @"created_at_ms": @((unsigned long long)floor(NSDate.date.timeIntervalSince1970 * 1000.0)),
        @"fields": safeFields,
    };
    record = [self validatedRecord:record];
    if (record == nil) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorPrivacyRejected,
                                           @"Telemetry failed its final privacy check");
        }
        return NO;
    }
    NSData *singleRecordData = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (singleRecordData.length > SCTelemetryMaximumEventBytes) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorRecordTooLarge,
                                           @"Telemetry exceeded its event size limit");
        }
        return NO;
    }

    BOOL exists = NO;
    NSString *directory = nil;
    if (![self prepareDirectoryForUID:uid createIfMissing:NO exists:&exists path:&directory error:error]) {
        return NO;
    }
    if (!exists) return NO;

    int lockDescriptor = [self openAndLockDirectory:directory error:error];
    if (lockDescriptor < 0) return NO;

    NSError *stateError = nil;
    NSDictionary *state = [self consentStateInDirectory:directory error:&stateError];
    BOOL enabled = [state[@"enabled"] boolValue];
    BOOL generationMatches = requiredConsentGeneration == nil ||
        [state[@"generation"] unsignedIntegerValue] == requiredConsentGeneration.unsignedIntegerValue;
    if (stateError != nil || !enabled || !generationMatches) {
        [self unlockAndCloseDescriptor:lockDescriptor];
        if (stateError != nil && error != NULL) *error = stateError;
        return NO;
    }

    NSError *recordsError = nil;
    NSMutableArray *records = [[self recordsInDirectory:directory error:&recordsError] mutableCopy];
    if (recordsError != nil) {
        [self unlockAndCloseDescriptor:lockDescriptor];
        if (error != NULL) *error = recordsError;
        return NO;
    }
    [records addObject:record];

    NSData *encoded = nil;
    do {
        if (records.count > SCTelemetryMaximumRecords) [records removeObjectAtIndex:0];
        encoded = [self encodedRecords:records error:&recordsError];
        if (encoded == nil) break;
        if (encoded.length <= SCTelemetryMaximumFileBytes) break;
        if (records.count == 0) break;
        [records removeObjectAtIndex:0];
    } while (YES);

    BOOL succeeded = (encoded != nil && encoded.length <= SCTelemetryMaximumFileBytes &&
                      [self atomicallyWriteData:encoded
                                       filename:SCTelemetryEventsFilename
                                      directory:directory
                                          error:error]);
    if (!succeeded && recordsError != nil && error != NULL) *error = recordsError;
    [self unlockAndCloseDescriptor:lockDescriptor];
    return succeeded;
}

- (NSArray<NSDictionary<NSString *,id> *> *)recordsForUID:(uid_t)uid
                                                      limit:(NSUInteger)limit
                                                      error:(NSError **)error {
    if (limit == 0) return @[];
    NSUInteger safeLimit = MIN(limit, SCTelemetryMaximumFetchRecords);

    BOOL exists = NO;
    NSString *directory = nil;
    if (![self prepareDirectoryForUID:uid createIfMissing:NO exists:&exists path:&directory error:error] || !exists) {
        return @[];
    }

    int lockDescriptor = [self openAndLockDirectory:directory error:error];
    if (lockDescriptor < 0) return @[];

    NSError *stateError = nil;
    NSDictionary *state = [self consentStateInDirectory:directory error:&stateError];
    if (stateError != nil || ![state[@"enabled"] boolValue]) {
        [self unlockAndCloseDescriptor:lockDescriptor];
        if (stateError != nil && error != NULL) *error = stateError;
        return @[];
    }

    NSArray *records = [self recordsInDirectory:directory error:error];
    if (error == NULL || *error == nil) {
        // Fetch is also the GC boundary: rewrite the already revalidated,
        // retention-filtered records while holding the queue lock. This drops
        // expired, malformed, and tampered lines instead of leaving them on
        // disk indefinitely.
        NSString *eventsPath = [directory stringByAppendingPathComponent:SCTelemetryEventsFilename];
        struct stat eventsStatus;
        if (lstat(eventsPath.fileSystemRepresentation, &eventsStatus) == 0) {
            NSError *rewriteError = nil;
            NSData *encoded = [self encodedRecords:records error:&rewriteError];
            if (encoded == nil || ![self atomicallyWriteData:encoded
                                                filename:SCTelemetryEventsFilename
                                               directory:directory
                                                   error:&rewriteError]) {
                if (error != NULL) *error = rewriteError;
                records = @[];
            }
        }
    }
    [self unlockAndCloseDescriptor:lockDescriptor];
    if (records.count <= safeLimit) return records;
    return [records subarrayWithRange:NSMakeRange(0, safeLimit)];
}

- (BOOL)acknowledgeRecordIDs:(NSArray<NSString *> *)recordIDs
                       forUID:(uid_t)uid
                        error:(NSError **)error {
    if (![recordIDs isKindOfClass:[NSArray class]] || recordIDs.count > SCTelemetryMaximumFetchRecords) {
        if (error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorInvalidArgument,
                                           @"Telemetry acknowledgement batch is invalid");
        }
        return NO;
    }
    if (recordIDs.count == 0) return YES;

    NSMutableSet<NSString *> *validIDs = [NSMutableSet setWithCapacity:recordIDs.count];
    for (id candidate in recordIDs) {
        NSString *canonicalID = SCTelemetryCanonicalNonzeroUUIDString(candidate);
        if (canonicalID == nil) {
            if (error != NULL) {
                *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorInvalidArgument,
                                               @"Telemetry acknowledgement contained an invalid ID");
            }
            return NO;
        }
        [validIDs addObject:canonicalID];
    }

    BOOL exists = NO;
    NSString *directory = nil;
    if (![self prepareDirectoryForUID:uid createIfMissing:NO exists:&exists path:&directory error:error]) {
        return NO;
    }
    if (!exists) return YES;

    int lockDescriptor = [self openAndLockDirectory:directory error:error];
    if (lockDescriptor < 0) return NO;

    NSError *stateError = nil;
    NSDictionary *state = [self consentStateInDirectory:directory error:&stateError];
    if (stateError != nil) {
        [self unlockAndCloseDescriptor:lockDescriptor];
        if (error != NULL) *error = stateError;
        return NO;
    }
    if (![state[@"enabled"] boolValue]) {
        // A delayed acknowledgement must not recreate a queue after opt-out.
        NSString *eventsPath = [directory stringByAppendingPathComponent:SCTelemetryEventsFilename];
        BOOL purged = unlink(eventsPath.fileSystemRepresentation) == 0 || errno == ENOENT;
        [self unlockAndCloseDescriptor:lockDescriptor];
        if (!purged && error != NULL) {
            *error = SCTelemetrySpoolError(SCTelemetrySpoolErrorIO,
                                           @"Could not preserve opted-out telemetry purge");
        }
        return purged;
    }

    NSError *recordsError = nil;
    NSArray *records = [self recordsInDirectory:directory error:&recordsError];
    if (recordsError != nil) {
        [self unlockAndCloseDescriptor:lockDescriptor];
        if (error != NULL) *error = recordsError;
        return NO;
    }

    NSMutableArray *remaining = [NSMutableArray arrayWithCapacity:records.count];
    for (NSDictionary *record in records) {
        if (![validIDs containsObject:record[@"id"]]) [remaining addObject:record];
    }
    NSData *encoded = [self encodedRecords:remaining error:&recordsError];
    BOOL succeeded = (encoded != nil &&
                      [self atomicallyWriteData:encoded
                                       filename:SCTelemetryEventsFilename
                                      directory:directory
                                          error:error]);
    if (!succeeded && recordsError != nil && error != NULL) *error = recordsError;
    [self unlockAndCloseDescriptor:lockDescriptor];
    return succeeded;
}

@end
