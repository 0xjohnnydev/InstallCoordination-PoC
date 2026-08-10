/*
 * Minimal InstallCoordination delivery path.
 *
 * payloadRoot must contain PromiseStaging, DataPromises, and Coordinators.
 * This function does nothing until the caller invokes stage_installcoord_payload().
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdbool.h>
#import <stdint.h>
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
    bool (*activate)(void *, bool);
    void (*queryFree)(container_query_t);
} InstallCoordAPI;

static NSMutableArray<NSValue *> *activeQueries;

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
        LOAD(activate, "container_object_sandbox_extension_activate");
        LOAD(queryFree, "container_query_free");
#undef LOAD
    });
    return &api;
}

static void ReleaseActiveQueries(void)
{
    InstallCoordAPI *api = SharedAPI();
    if (api->queryFree == NULL) {
        return;
    }
    @synchronized (activeQueries) {
        for (NSValue *value in activeQueries) {
            api->queryFree(value.pointerValue);
        }
        [activeQueries removeAllObjects];
    }
}

static BOOL ActivateInstallCoordDomain(NSString *domain)
{
    InstallCoordAPI *api = SharedAPI();
    if (api->handle == NULL || api->create == NULL ||
        api->setClass == NULL || api->setGroup == NULL ||
        api->setFlags == NULL || api->setPart == NULL ||
        api->setDomain == NULL || api->result == NULL ||
        api->activate == NULL || api->queryFree == NULL) {
        return NO;
    }

    container_query_t query = api->create();
    if (query == NULL) {
        return NO;
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
    void *object = api->result(query);
    if (object == NULL || !api->activate(object, false)) {
        api->queryFree(query);
        return NO;
    }
    if (activeQueries == nil) {
        activeQueries = [NSMutableArray array];
    }
    [activeQueries addObject:[NSValue valueWithPointer:query]];
    return YES;                                 // keep query alive
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
    for (NSString *part in parts) {
        NSString *domain = [@"../InstallCoordination"
            stringByAppendingPathComponent:part];
        if (!ActivateInstallCoordDomain(domain)) {
            ReleaseActiveQueries();
            return NO;                          // patched on 24A5408d
        }
    }

    NSString *stateRoot =
        @"/private/var/containers/Shared/SystemGroup/"
         "systemgroup.com.apple.installcoordinationd/Library/"
         "InstallCoordination";

    NSMutableArray<NSString *> *created = [NSMutableArray array];
    // Commit order matters. The coordinator is the final commit record.
    for (NSString *part in parts) {
        if (!CopyContents(
                [payloadRoot stringByAppendingPathComponent:part],
                [stateRoot stringByAppendingPathComponent:part], created,
                error)) {
            RemoveCreatedItems(created);
            ReleaseActiveQueries();
            return NO;
        }
    }
    ReleaseActiveQueries();
    return YES;
}
